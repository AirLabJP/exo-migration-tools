<#
.SYNOPSIS
  メールヘッダーアナライザー（Microsoft Message Header Analyzer風）

.DESCRIPTION
  メールヘッダーを解析し、送信経路、SPF/DKIM/DMARC、遅延、ループ検出などの情報を抽出します。
  結果をCSV形式で出力します。

  【解析項目】
  - 送信経路（Receivedヘッダー）
  - SPF/DKIM/DMARC認証結果
  - 送信遅延（各ホップ間）
  - ループ検出
  - 送信元・宛先情報
  - メッセージID

.PARAMETER HeaderPath
  メールヘッダーファイルのパス（.eml, .txt, .msg等）

.PARAMETER HeaderText
  メールヘッダーのテキスト（直接指定）

.PARAMETER OutPath
  出力CSVファイルのパス（省略時は自動生成）

.PARAMETER OutFormat
  出力形式（CSV, JSON, Table）

.EXAMPLE
  # .emlファイルから解析
  .\Test-MailHeader.ps1 -HeaderPath "C:\mail.eml"

.EXAMPLE
  # テキストから直接解析
  $header = Get-Content "header.txt" -Raw
  .\Test-MailHeader.ps1 -HeaderText $header

.EXAMPLE
  # JSON形式で出力
  .\Test-MailHeader.ps1 -HeaderPath "mail.eml" -OutFormat JSON
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false, ParameterSetName="File")]
    [string]$HeaderPath,
    
    [Parameter(Mandatory=$false, ParameterSetName="Text")]
    [string]$HeaderText,
    
    [Parameter(Mandatory=$false)]
    [string]$OutPath,
    
    [ValidateSet("CSV","JSON","Table")]
    [string]$OutFormat = "CSV"
)

# ヘッダーテキストの取得
if ($HeaderPath) {
    if (-not (Test-Path $HeaderPath)) {
        Write-Error "ファイルが見つかりません: $HeaderPath"
        exit 1
    }
    $headerText = Get-Content $HeaderPath -Raw -Encoding UTF8
} elseif ($HeaderText) {
    $headerText = $HeaderText
} else {
    Write-Error "HeaderPath または HeaderText のいずれかを指定してください"
    exit 1
}

# ヘッダーと本文の分離（.emlファイルの場合）
if ($headerText -match "(?s)^(.*?)\r?\n\r?\n(.*)$") {
    $headerText = $matches[1]
}

Write-Host "============================================================"
Write-Host " メールヘッダー解析"
Write-Host "============================================================"
Write-Host ""

#----------------------------------------------------------------------
# 解析関数
#----------------------------------------------------------------------

function Parse-ReceivedHeader {
    param([string]$HeaderText)
    
    $receivedHeaders = [regex]::Matches($headerText, "(?m)^Received:\s*(.+)$")
    $hops = @()
    
    foreach ($match in $receivedHeaders) {
        $line = $match.Groups[1].Value
        
        # ホスト名の抽出
        $hostMatch = [regex]::Match($line, "from\s+([^\s\(]+)")
        $fromHost = if ($hostMatch.Success) { $hostMatch.Groups[1].Value } else { "不明" }
        
        # タイムスタンプの抽出
        $timeMatch = [regex]::Match($line, ";\s*(.+)$")
        $timestamp = if ($timeMatch.Success) { $timeMatch.Groups[1].Value.Trim() } else { "不明" }
        
        # IPアドレスの抽出
        $ipMatch = [regex]::Match($line, "\[([0-9\.]+)\]")
        $ipAddress = if ($ipMatch.Success) { $ipMatch.Groups[1].Value } else { "" }
        
        $hops += [PSCustomObject]@{
            FromHost = $fromHost
            IPAddress = $ipAddress
            Timestamp = $timestamp
            RawLine = $line
        }
    }
    
    return $hops
}

function Parse-AuthenticationResults {
    param([string]$HeaderText)
    
    $authResults = @{
        SPF = "未検出"
        DKIM = "未検出"
        DMARC = "未検出"
    }
    
    # Authentication-Results ヘッダーの検索
    $authMatch = [regex]::Match($HeaderText, "(?m)^Authentication-Results:\s*(.+)$")
    if ($authMatch.Success) {
        $authLine = $authMatch.Groups[1].Value
        
        # SPF
        if ($authLine -match "spf=(\w+)") {
            $authResults.SPF = $matches[1]
        }
        
        # DKIM
        if ($authLine -match "dkim=(\w+)") {
            $authResults.DKIM = $matches[1]
        }
        
        # DMARC
        if ($authLine -match "dmarc=(\w+)") {
            $authResults.DMARC = $matches[1]
        }
    }
    
    # 個別ヘッダーも確認
    if ($HeaderText -match "(?m)^Received-SPF:\s*(.+)$") {
        $spfLine = $matches[1]
        if ($spfLine -match "(pass|fail|neutral|softfail|none)") {
            $authResults.SPF = $matches[1]
        }
    }
    
    return $authResults
}

function Parse-BasicInfo {
    param([string]$HeaderText)
    
    $info = @{
        From = ""
        To = ""
        Subject = ""
        MessageID = ""
        Date = ""
        ReturnPath = ""
    }
    
    # From
    if ($HeaderText -match "(?m)^From:\s*(.+)$") {
        $info.From = $matches[1].Trim()
    }
    
    # To
    if ($HeaderText -match "(?m)^To:\s*(.+)$") {
        $info.To = $matches[1].Trim()
    }
    
    # Subject
    if ($HeaderText -match "(?m)^Subject:\s*(.+)$") {
        $info.Subject = $matches[1].Trim()
    }
    
    # Message-ID
    if ($HeaderText -match "(?m)^Message-ID:\s*(.+)$") {
        $info.MessageID = $matches[1].Trim()
    }
    
    # Date
    if ($HeaderText -match "(?m)^Date:\s*(.+)$") {
        $info.Date = $matches[1].Trim()
    }
    
    # Return-Path
    if ($HeaderText -match "(?m)^Return-Path:\s*(.+)$") {
        $info.ReturnPath = $matches[1].Trim()
    }
    
    return $info
}

function Detect-Loop {
    param([array]$Hops)
    
    $hostCounts = @{}
    foreach ($hop in $Hops) {
        if ($hostCounts.ContainsKey($hop.FromHost)) {
            $hostCounts[$hop.FromHost]++
        } else {
            $hostCounts[$hop.FromHost] = 1
        }
    }
    
    $loops = $hostCounts.GetEnumerator() | Where-Object { $_.Value -gt 1 }
    
    return @{
        HasLoop = ($loops.Count -gt 0)
        LoopHosts = ($loops | ForEach-Object { $_.Key }) -join ", "
    }
}

#----------------------------------------------------------------------
# メイン処理
#----------------------------------------------------------------------

# 基本情報の抽出
$basicInfo = Parse-BasicInfo -HeaderText $headerText

# Receivedヘッダーの解析
$hops = Parse-ReceivedHeader -HeaderText $headerText

# 認証結果の抽出
$authResults = Parse-AuthenticationResults -HeaderText $headerText

# ループ検出
$loopInfo = Detect-Loop -Hops $hops

# 遅延計算（簡易版）
$delays = @()
for ($i = 0; $i -lt $hops.Count - 1; $i++) {
    $delays += [PSCustomObject]@{
        From = $hops[$i].FromHost
        To = $hops[$i+1].FromHost
        Delay = "計算不可（タイムスタンプ解析が必要）"
    }
}

# 結果オブジェクトの作成
$result = [PSCustomObject]@{
    MessageID = $basicInfo.MessageID
    From = $basicInfo.From
    To = $basicInfo.To
    Subject = $basicInfo.Subject
    Date = $basicInfo.Date
    ReturnPath = $basicInfo.ReturnPath
    HopCount = $hops.Count
    SPFResult = $authResults.SPF
    DKIMResult = $authResults.DKIM
    DMARCResult = $authResults.DMARC
    HasLoop = $loopInfo.HasLoop
    LoopHosts = $loopInfo.LoopHosts
    AnalysisDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

# ホップ情報の詳細
$hopDetails = $hops | ForEach-Object {
    [PSCustomObject]@{
        MessageID = $basicInfo.MessageID
        HopNumber = ($hops.IndexOf($_) + 1)
        FromHost = $_.FromHost
        IPAddress = $_.IPAddress
        Timestamp = $_.Timestamp
        RawLine = $_.RawLine
    }
}

# 出力
Write-Host "【基本情報】"
Write-Host "  メッセージID: $($result.MessageID)"
Write-Host "  送信元:       $($result.From)"
Write-Host "  宛先:         $($result.To)"
Write-Host "  件名:         $($result.Subject)"
Write-Host "  日時:         $($result.Date)"
Write-Host ""

Write-Host "【送信経路】"
Write-Host "  ホップ数:     $($result.HopCount)"
for ($i = 0; $i -lt $hops.Count; $i++) {
    Write-Host "  [$($i+1)] $($hops[$i].FromHost) ($($hops[$i].IPAddress))"
}
Write-Host ""

Write-Host "【認証結果】"
Write-Host "  SPF:   $($result.SPFResult)"
Write-Host "  DKIM:  $($result.DKIMResult)"
Write-Host "  DMARC: $($result.DMARCResult)"
Write-Host ""

Write-Host "【ループ検出】"
if ($result.HasLoop) {
    Write-Host "  ⚠️  ループ検出: $($result.LoopHosts)" -ForegroundColor Yellow
} else {
    Write-Host "  ✅ ループなし" -ForegroundColor Green
}
Write-Host ""

# ファイル出力
if (-not $OutPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutPath = Join-Path $PSScriptRoot "mail_header_analysis_$timestamp"
}

switch ($OutFormat) {
    "CSV" {
        $csvPath = "$OutPath.csv"
        $result | Export-Csv -Path $csvPath -Encoding UTF8 -NoTypeInformation
        
        $hopCsvPath = "${OutPath}_hops.csv"
        $hopDetails | Export-Csv -Path $hopCsvPath -Encoding UTF8 -NoTypeInformation
        
        Write-Host "============================================================"
        Write-Host " 結果をCSVに出力しました"
        Write-Host "============================================================"
        Write-Host "  サマリー: $csvPath"
        Write-Host "  ホップ詳細: $hopCsvPath"
    }
    "JSON" {
        $jsonPath = "$OutPath.json"
        $output = @{
            Summary = $result
            Hops = $hopDetails
        }
        $output | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Host "============================================================"
        Write-Host " 結果をJSONに出力しました: $jsonPath"
        Write-Host "============================================================"
    }
    "Table" {
        Write-Host "============================================================"
        Write-Host " サマリー"
        Write-Host "============================================================"
        $result | Format-Table -AutoSize
        Write-Host ""
        Write-Host "============================================================"
        Write-Host " ホップ詳細"
        Write-Host "============================================================"
        $hopDetails | Format-Table -AutoSize
    }
}

Write-Host ""
