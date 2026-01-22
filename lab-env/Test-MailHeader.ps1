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

  【対応メーラー】
  - Microsoft Outlook（クラシック版/New Outlook）
  - Mozilla Thunderbird
  - その他RFC準拠のメールヘッダー

.PARAMETER HeaderPath
  メールヘッダーファイルのパス（.eml, .txt, .msg等）

.PARAMETER HeaderText
  メールヘッダーのテキスト（直接指定）

.PARAMETER FromClipboard
  クリップボードからヘッダーを取得（メーラーからコピー＆ペースト用）

.PARAMETER Interactive
  対話モード（ヘッダーを貼り付けて解析）

.PARAMETER OutPath
  出力CSVファイルのパス（省略時は自動生成）

.PARAMETER OutFormat
  出力形式（CSV, JSON, Table）

.PARAMETER NoFile
  ファイル出力を行わない（画面表示のみ）

.EXAMPLE
  # 対話モード（推奨：メーラーからコピー＆ペースト）
  .\Test-MailHeader.ps1 -Interactive

.EXAMPLE
  # クリップボードから解析
  .\Test-MailHeader.ps1 -FromClipboard

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

.NOTES
  【Thunderbirdでのヘッダーコピー方法】
  1. メールを開く
  2. [表示] → [ヘッダー] → [すべて] または Ctrl+U でソース表示
  3. ヘッダー部分を選択してコピー（Ctrl+C）

  【Outlookクラシック版でのヘッダーコピー方法】
  1. メールを開く
  2. [ファイル] → [プロパティ] → [インターネットヘッダー]
  3. ヘッダーを選択してコピー（Ctrl+C）

  【New Outlookでのヘッダーコピー方法】
  1. メールを開く
  2. [...] → [表示] → [メッセージの詳細を表示]
  3. ヘッダーを選択してコピー（Ctrl+C）
#>

[CmdletBinding(DefaultParameterSetName="Interactive")]
param(
    [Parameter(Mandatory=$false, ParameterSetName="File")]
    [string]$HeaderPath,
    
    [Parameter(Mandatory=$false, ParameterSetName="Text")]
    [string]$HeaderText,
    
    [Parameter(Mandatory=$false, ParameterSetName="Clipboard")]
    [switch]$FromClipboard,
    
    [Parameter(Mandatory=$false, ParameterSetName="Interactive")]
    [switch]$Interactive,
    
    [Parameter(Mandatory=$false)]
    [string]$OutPath,
    
    [ValidateSet("CSV","JSON","Table")]
    [string]$OutFormat = "Table",
    
    [Parameter(Mandatory=$false)]
    [switch]$NoFile
)

#----------------------------------------------------------------------
# ヘルパー関数
#----------------------------------------------------------------------

function Show-Banner {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║         メールヘッダー解析ツール (Mail Header Analyzer)        ║" -ForegroundColor Cyan
    Write-Host "║                                                              ║" -ForegroundColor Cyan
    Write-Host "║   対応: Thunderbird / Outlook (クラシック/New)               ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-CopyInstructions {
    Write-Host "┌──────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "│ 【ヘッダーのコピー方法】                                       │" -ForegroundColor Yellow
    Write-Host "├──────────────────────────────────────────────────────────────┤" -ForegroundColor Yellow
    Write-Host "│                                                              │" -ForegroundColor Yellow
    Write-Host "│ ■ Thunderbird:                                              │" -ForegroundColor Yellow
    Write-Host "│   1. メールを選択                                            │" -ForegroundColor Yellow
    Write-Host "│   2. Ctrl+U（またはメニュー[表示]→[メッセージのソース]）      │" -ForegroundColor Yellow
    Write-Host "│   3. ヘッダー部分（空行まで）を選択してコピー(Ctrl+C)         │" -ForegroundColor Yellow
    Write-Host "│                                                              │" -ForegroundColor Yellow
    Write-Host "│ ■ Outlook クラシック版:                                      │" -ForegroundColor Yellow
    Write-Host "│   1. メールをダブルクリックで開く                             │" -ForegroundColor Yellow
    Write-Host "│   2. [ファイル]→[プロパティ]                                 │" -ForegroundColor Yellow
    Write-Host "│   3. [インターネットヘッダー]欄を全選択(Ctrl+A)してコピー     │" -ForegroundColor Yellow
    Write-Host "│                                                              │" -ForegroundColor Yellow
    Write-Host "│ ■ New Outlook:                                              │" -ForegroundColor Yellow
    Write-Host "│   1. メールを開く                                            │" -ForegroundColor Yellow
    Write-Host "│   2. [...]→[表示]→[メッセージの詳細を表示]                  │" -ForegroundColor Yellow
    Write-Host "│   3. ヘッダーを選択してコピー(Ctrl+C)                         │" -ForegroundColor Yellow
    Write-Host "│                                                              │" -ForegroundColor Yellow
    Write-Host "└──────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
    Write-Host ""
}

function Get-HeaderFromClipboard {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $clipText = [System.Windows.Forms.Clipboard]::GetText()
        if ([string]::IsNullOrWhiteSpace($clipText)) {
            Write-Host "⚠️  クリップボードにテキストがありません。" -ForegroundColor Yellow
            Write-Host "    メーラーからヘッダーをコピーしてから再実行してください。" -ForegroundColor Yellow
            return $null
        }
        return $clipText
    }
    catch {
        Write-Host "⚠️  クリップボードの読み取りに失敗しました: $_" -ForegroundColor Red
        return $null
    }
}

function Get-HeaderInteractive {
    Show-CopyInstructions
    
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host " ヘッダーを貼り付けてください（貼り付け後、空行を入力してEnterで確定）" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host ""
    
    $lines = @()
    $emptyLineCount = 0
    
    while ($true) {
        $line = Read-Host
        
        if ([string]::IsNullOrEmpty($line)) {
            $emptyLineCount++
            if ($emptyLineCount -ge 2) {
                # 連続した空行で終了
                break
            }
            $lines += ""
        } else {
            $emptyLineCount = 0
            $lines += $line
        }
    }
    
    $headerText = $lines -join "`r`n"
    
    if ([string]::IsNullOrWhiteSpace($headerText)) {
        Write-Host "⚠️  ヘッダーが入力されませんでした。" -ForegroundColor Yellow
        return $null
    }
    
    return $headerText
}

function Normalize-HeaderText {
    param([string]$RawHeader)
    
    # メーラー固有の形式を正規化
    $header = $RawHeader
    
    # 折り返しヘッダーの結合（RFC 2822準拠）
    # 行頭がスペースまたはタブで始まる場合、前の行の続き
    $header = $header -replace "(\r?\n)[\t ]+"," "
    
    # Outlook特有の形式を正規化
    # "ヘッダー名: " の前に余計な改行がある場合を修正
    $header = $header -replace "\r?\n\r?\n([A-Za-z-]+:)","`r`n`$1"
    
    # Thunderbirdのソース表示からの余計な部分を除去
    # 本文部分を除去（最初の空行以降）
    if ($header -match "(?s)^(.*?)\r?\n\r?\n") {
        $header = $matches[1]
    }
    
    return $header
}

function Detect-MailerType {
    param([string]$HeaderText)
    
    $mailer = "Unknown"
    
    if ($HeaderText -match "X-Mailer:\s*Microsoft Outlook") {
        $mailer = "Outlook Classic"
    }
    elseif ($HeaderText -match "X-Mailer:\s*Mozilla Thunderbird") {
        $mailer = "Thunderbird"
    }
    elseif ($HeaderText -match "x-ms-exchange-") {
        $mailer = "Exchange/Outlook"
    }
    elseif ($HeaderText -match "X-Mozilla-") {
        $mailer = "Thunderbird"
    }
    elseif ($HeaderText -match "User-Agent:\s*Mozilla Thunderbird") {
        $mailer = "Thunderbird"
    }
    
    return $mailer
}

#----------------------------------------------------------------------
# 解析関数
#----------------------------------------------------------------------

function ConvertFrom-ReceivedHeader {
    param([string]$HeaderText)
    
    # 複数行にまたがるReceivedヘッダーを正しく抽出
    $receivedPattern = "(?im)^Received:\s*(.+?)(?=^[A-Za-z-]+:|$)"
    $receivedHeaders = [regex]::Matches($headerText, $receivedPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    
    $hops = @()
    
    foreach ($match in $receivedHeaders) {
        $line = $match.Groups[1].Value -replace "\s+"," "
        $line = $line.Trim()
        
        # ホスト名の抽出（from句）
        $fromHost = "不明"
        if ($line -match "from\s+([^\s\(\)]+)") {
            $fromHost = $matches[1]
        }
        
        # 宛先ホスト名（by句）
        $byHost = ""
        if ($line -match "by\s+([^\s\(\)]+)") {
            $byHost = $matches[1]
        }
        
        # タイムスタンプの抽出
        $timestamp = "不明"
        if ($line -match ";\s*(.+)$") {
            $timestamp = $matches[1].Trim()
        }
        
        # IPアドレスの抽出
        $ipAddress = ""
        if ($line -match "\[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\]") {
            $ipAddress = $matches[1]
        }
        elseif ($line -match "\((\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\)") {
            $ipAddress = $matches[1]
        }
        
        # プロトコルの抽出
        $protocol = ""
        if ($line -match "with\s+(SMTP|ESMTP|ESMTPS|ESMTPSA|LMTP|HTTP|HTTPS)") {
            $protocol = $matches[1]
        }
        
        $hops += [PSCustomObject]@{
            FromHost = $fromHost
            ByHost = $byHost
            IPAddress = $ipAddress
            Protocol = $protocol
            Timestamp = $timestamp
            RawLine = $line.Substring(0, [Math]::Min(200, $line.Length))
        }
    }
    
    return $hops
}

function ConvertFrom-AuthenticationResults {
    param([string]$HeaderText)
    
    $authResults = @{
        SPF = "未検出"
        SPFDetail = ""
        DKIM = "未検出"
        DKIMDetail = ""
        DMARC = "未検出"
        DMARCDetail = ""
        ARC = "未検出"
        CompAuth = "未検出"
    }
    
    # Authentication-Results ヘッダーの検索（複数行対応）
    $authPattern = "(?im)^Authentication-Results:\s*(.+?)(?=^[A-Za-z-]+:|$)"
    $authMatches = [regex]::Matches($headerText, $authPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    
    foreach ($authMatch in $authMatches) {
        $authLine = $authMatch.Groups[1].Value -replace "\s+"," "
        
        # SPF
        if ($authLine -match "spf=(\w+)(\s+\([^\)]+\))?") {
            $authResults.SPF = $matches[1]
            if ($matches[2]) { $authResults.SPFDetail = $matches[2].Trim() }
        }
        
        # DKIM
        if ($authLine -match "dkim=(\w+)(\s+\([^\)]+\))?") {
            $authResults.DKIM = $matches[1]
            if ($matches[2]) { $authResults.DKIMDetail = $matches[2].Trim() }
        }
        
        # DMARC
        if ($authLine -match "dmarc=(\w+)(\s+\([^\)]+\))?") {
            $authResults.DMARC = $matches[1]
            if ($matches[2]) { $authResults.DMARCDetail = $matches[2].Trim() }
        }
        
        # ARC
        if ($authLine -match "arc=(\w+)") {
            $authResults.ARC = $matches[1]
        }
        
        # compauth (Microsoft 複合認証)
        if ($authLine -match "compauth=(\w+)") {
            $authResults.CompAuth = $matches[1]
        }
    }
    
    # 個別ヘッダーも確認
    if ($headerText -match "(?im)^Received-SPF:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $spfLine = $matches[1]
        if ($spfLine -match "(pass|fail|neutral|softfail|none|temperror|permerror)") {
            if ($authResults.SPF -eq "未検出") {
                $authResults.SPF = $matches[1]
            }
        }
    }
    
    # DKIM-Signature の存在確認
    if ($headerText -match "(?im)^DKIM-Signature:") {
        if ($authResults.DKIM -eq "未検出") {
            $authResults.DKIM = "署名あり(結果不明)"
        }
    }
    
    return $authResults
}

function ConvertFrom-BasicInfo {
    param([string]$HeaderText)
    
    $info = @{
        From = ""
        To = ""
        Subject = ""
        MessageID = ""
        Date = ""
        ReturnPath = ""
        ReplyTo = ""
        XMailer = ""
        ContentType = ""
    }
    
    # From
    if ($headerText -match "(?im)^From:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $info.From = $matches[1].Trim() -replace "\s+"," "
    }
    
    # To
    if ($headerText -match "(?im)^To:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $info.To = $matches[1].Trim() -replace "\s+"," "
    }
    
    # Subject (MIMEエンコードのデコードも試みる)
    if ($headerText -match "(?im)^Subject:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $subject = $matches[1].Trim() -replace "\s+"," "
        # 簡易的なMIMEデコード（Base64 UTF-8）
        if ($subject -match "=\?UTF-8\?B\?([A-Za-z0-9+/=]+)\?=") {
            try {
                $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($matches[1]))
                $subject = $subject -replace "=\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=",$decoded
            } catch {}
        }
        $info.Subject = $subject
    }
    
    # Message-ID
    if ($headerText -match "(?im)^Message-ID:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $info.MessageID = $matches[1].Trim()
    }
    
    # Date
    if ($headerText -match "(?im)^Date:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $info.Date = $matches[1].Trim()
    }
    
    # Return-Path
    if ($headerText -match "(?im)^Return-Path:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $info.ReturnPath = $matches[1].Trim()
    }
    
    # Reply-To
    if ($headerText -match "(?im)^Reply-To:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $info.ReplyTo = $matches[1].Trim()
    }
    
    # X-Mailer / User-Agent
    if ($headerText -match "(?im)^X-Mailer:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $info.XMailer = $matches[1].Trim()
    }
    elseif ($headerText -match "(?im)^User-Agent:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $info.XMailer = $matches[1].Trim()
    }
    
    # Content-Type
    if ($headerText -match "(?im)^Content-Type:\s*(.+?)(?=^[A-Za-z-]+:|$)") {
        $info.ContentType = $matches[1].Trim() -replace "\s+"," "
    }
    
    return $info
}

function Find-MailLoop {
    param([array]$Hops)
    
    $hostCounts = @{}
    foreach ($hop in $Hops) {
        $host = $hop.FromHost
        if ($host -and $host -ne "不明") {
            if ($hostCounts.ContainsKey($host)) {
                $hostCounts[$host]++
            } else {
                $hostCounts[$host] = 1
            }
        }
    }
    
    $loops = $hostCounts.GetEnumerator() | Where-Object { $_.Value -gt 2 }
    
    return @{
        HasLoop = ($loops.Count -gt 0)
        LoopHosts = ($loops | ForEach-Object { "$($_.Key) (${$_.Value}回)" }) -join ", "
    }
}

function Calculate-Delays {
    param([array]$Hops)
    
    $delays = @()
    
    for ($i = $Hops.Count - 1; $i -gt 0; $i--) {
        $currentHop = $Hops[$i]
        $nextHop = $Hops[$i-1]
        
        $delay = "計算不可"
        
        # タイムスタンプからの遅延計算を試みる
        try {
            if ($currentHop.Timestamp -ne "不明" -and $nextHop.Timestamp -ne "不明") {
                $currentTime = [DateTime]::Parse($currentHop.Timestamp)
                $nextTime = [DateTime]::Parse($nextHop.Timestamp)
                $diff = $nextTime - $currentTime
                
                if ($diff.TotalSeconds -ge 0 -and $diff.TotalSeconds -lt 86400) {
                    if ($diff.TotalSeconds -lt 1) {
                        $delay = "< 1秒"
                    }
                    elseif ($diff.TotalMinutes -lt 1) {
                        $delay = "$([Math]::Round($diff.TotalSeconds))秒"
                    }
                    elseif ($diff.TotalHours -lt 1) {
                        $delay = "$([Math]::Round($diff.TotalMinutes))分"
                    }
                    else {
                        $delay = "$([Math]::Round($diff.TotalHours, 1))時間"
                    }
                }
            }
        } catch {}
        
        $delays += [PSCustomObject]@{
            Step = $Hops.Count - $i
            From = $currentHop.FromHost
            To = $nextHop.FromHost
            Delay = $delay
        }
    }
    
    return $delays
}

function Find-SecurityIssues {
    param(
        [hashtable]$AuthResults,
        [array]$Hops,
        [hashtable]$BasicInfo
    )
    
    $issues = @()
    
    # SPFチェック
    if ($AuthResults.SPF -in @("fail", "softfail", "permerror")) {
        $issues += [PSCustomObject]@{
            Severity = "警告"
            Category = "SPF"
            Message = "SPF認証が失敗しています: $($AuthResults.SPF)"
        }
    }
    
    # DKIMチェック
    if ($AuthResults.DKIM -in @("fail", "permerror")) {
        $issues += [PSCustomObject]@{
            Severity = "警告"
            Category = "DKIM"
            Message = "DKIM認証が失敗しています: $($AuthResults.DKIM)"
        }
    }
    
    # DMARCチェック
    if ($AuthResults.DMARC -in @("fail", "none")) {
        $issues += [PSCustomObject]@{
            Severity = "注意"
            Category = "DMARC"
            Message = "DMARC認証が失敗または未設定: $($AuthResults.DMARC)"
        }
    }
    
    # Return-PathとFromの不一致
    if ($BasicInfo.ReturnPath -and $BasicInfo.From) {
        $returnDomain = ""
        $fromDomain = ""
        
        if ($BasicInfo.ReturnPath -match "@([^>]+)") { $returnDomain = $matches[1].ToLower() }
        if ($BasicInfo.From -match "@([^>]+)") { $fromDomain = $matches[1].ToLower() }
        
        if ($returnDomain -and $fromDomain -and $returnDomain -ne $fromDomain) {
            $issues += [PSCustomObject]@{
                Severity = "注意"
                Category = "ヘッダー"
                Message = "Return-PathとFromのドメインが異なります（$returnDomain vs $fromDomain）"
            }
        }
    }
    
    # 多すぎるホップ
    if ($Hops.Count -gt 10) {
        $issues += [PSCustomObject]@{
            Severity = "注意"
            Category = "経路"
            Message = "ホップ数が多いです（$($Hops.Count)ホップ）- 遅延の原因になる可能性"
        }
    }
    
    return $issues
}

function Show-ResultSummary {
    param(
        [hashtable]$BasicInfo,
        [array]$Hops,
        [hashtable]$AuthResults,
        [hashtable]$LoopInfo,
        [array]$Delays,
        [array]$SecurityIssues,
        [string]$MailerType
    )
    
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                       解析結果                                ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    # 基本情報
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│ 【基本情報】                                                  │" -ForegroundColor White
    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor White
    Write-Host "  送信元:     $($BasicInfo.From)" -ForegroundColor Gray
    Write-Host "  宛先:       $($BasicInfo.To)" -ForegroundColor Gray
    Write-Host "  件名:       $($BasicInfo.Subject)" -ForegroundColor Gray
    Write-Host "  日時:       $($BasicInfo.Date)" -ForegroundColor Gray
    Write-Host "  Message-ID: $($BasicInfo.MessageID)" -ForegroundColor Gray
    if ($BasicInfo.ReturnPath) {
        Write-Host "  Return-Path: $($BasicInfo.ReturnPath)" -ForegroundColor Gray
    }
    if ($MailerType -ne "Unknown") {
        Write-Host "  メーラー:   $MailerType" -ForegroundColor Gray
    }
    Write-Host ""
    
    # 認証結果
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│ 【認証結果】                                                  │" -ForegroundColor White
    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor White
    
    # SPF
    $spfColor = switch ($AuthResults.SPF) {
        "pass" { "Green" }
        { $_ -in @("fail", "softfail", "permerror") } { "Red" }
        "neutral" { "Yellow" }
        default { "Gray" }
    }
    $spfIcon = switch ($AuthResults.SPF) {
        "pass" { "✅" }
        { $_ -in @("fail", "softfail", "permerror") } { "❌" }
        "neutral" { "⚠️" }
        default { "❓" }
    }
    Write-Host "  SPF:   $spfIcon $($AuthResults.SPF) $($AuthResults.SPFDetail)" -ForegroundColor $spfColor
    
    # DKIM
    $dkimColor = switch ($AuthResults.DKIM) {
        "pass" { "Green" }
        { $_ -in @("fail", "permerror") } { "Red" }
        default { "Gray" }
    }
    $dkimIcon = switch ($AuthResults.DKIM) {
        "pass" { "✅" }
        { $_ -in @("fail", "permerror") } { "❌" }
        default { "❓" }
    }
    Write-Host "  DKIM:  $dkimIcon $($AuthResults.DKIM) $($AuthResults.DKIMDetail)" -ForegroundColor $dkimColor
    
    # DMARC
    $dmarcColor = switch ($AuthResults.DMARC) {
        "pass" { "Green" }
        { $_ -in @("fail", "reject", "quarantine") } { "Red" }
        "none" { "Yellow" }
        default { "Gray" }
    }
    $dmarcIcon = switch ($AuthResults.DMARC) {
        "pass" { "✅" }
        { $_ -in @("fail", "reject", "quarantine") } { "❌" }
        "none" { "⚠️" }
        default { "❓" }
    }
    Write-Host "  DMARC: $dmarcIcon $($AuthResults.DMARC) $($AuthResults.DMARCDetail)" -ForegroundColor $dmarcColor
    
    if ($AuthResults.ARC -ne "未検出") {
        Write-Host "  ARC:   $($AuthResults.ARC)" -ForegroundColor Gray
    }
    if ($AuthResults.CompAuth -ne "未検出") {
        Write-Host "  CompAuth: $($AuthResults.CompAuth) (Microsoft複合認証)" -ForegroundColor Gray
    }
    Write-Host ""
    
    # 送信経路
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│ 【送信経路】 ($($Hops.Count) ホップ)                           │" -ForegroundColor White
    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor White
    
    for ($i = $Hops.Count - 1; $i -ge 0; $i--) {
        $hop = $Hops[$i]
        $hopNum = $Hops.Count - $i
        $arrow = if ($i -gt 0) { "  ↓" } else { "" }
        
        $hostInfo = $hop.FromHost
        if ($hop.IPAddress) { $hostInfo += " [$($hop.IPAddress)]" }
        if ($hop.Protocol) { $hostInfo += " ($($hop.Protocol))" }
        
        Write-Host "  [$hopNum] $hostInfo" -ForegroundColor Cyan
        
        # 遅延情報があれば表示
        $delayInfo = $Delays | Where-Object { $_.Step -eq $hopNum }
        if ($delayInfo -and $delayInfo.Delay -ne "計算不可") {
            Write-Host "      └─ 遅延: $($delayInfo.Delay)" -ForegroundColor Gray
        }
        
        if ($arrow) { Write-Host $arrow -ForegroundColor DarkGray }
    }
    Write-Host ""
    
    # ループ検出
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│ 【ループ検出】                                                │" -ForegroundColor White
    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor White
    if ($LoopInfo.HasLoop) {
        Write-Host "  ⚠️  ループの可能性: $($LoopInfo.LoopHosts)" -ForegroundColor Yellow
    } else {
        Write-Host "  ✅ ループなし" -ForegroundColor Green
    }
    Write-Host ""
    
    # セキュリティ問題
    if ($SecurityIssues.Count -gt 0) {
        Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Red
        Write-Host "│ 【検出された問題】                                           │" -ForegroundColor Red
        Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor Red
        foreach ($issue in $SecurityIssues) {
            $icon = if ($issue.Severity -eq "警告") { "⚠️" } else { "ℹ️" }
            $color = if ($issue.Severity -eq "警告") { "Yellow" } else { "Gray" }
            Write-Host "  $icon [$($issue.Category)] $($issue.Message)" -ForegroundColor $color
        }
        Write-Host ""
    }
}

#----------------------------------------------------------------------
# メイン処理
#----------------------------------------------------------------------

Show-Banner

# ヘッダーテキストの取得
$headerText = $null

if ($HeaderPath) {
    if (-not (Test-Path $HeaderPath)) {
        Write-Error "ファイルが見つかりません: $HeaderPath"
        exit 1
    }
    $headerText = Get-Content $HeaderPath -Raw -Encoding UTF8
    Write-Host "📄 ファイルから読み込み: $HeaderPath" -ForegroundColor Gray
}
elseif ($HeaderText) {
    $headerText = $HeaderText
    Write-Host "📝 テキストから解析" -ForegroundColor Gray
}
elseif ($FromClipboard) {
    Write-Host "📋 クリップボードから取得中..." -ForegroundColor Gray
    $headerText = Get-HeaderFromClipboard
}
else {
    # デフォルト: 対話モード
    $headerText = Get-HeaderInteractive
}

if (-not $headerText) {
    Write-Host ""
    Write-Host "❌ ヘッダーを取得できませんでした。" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "🔍 解析中..." -ForegroundColor Cyan

# ヘッダーの正規化
$headerText = Normalize-HeaderText -RawHeader $headerText

# メーラー種別の検出
$mailerType = Detect-MailerType -HeaderText $headerText

# 基本情報の抽出
$basicInfo = ConvertFrom-BasicInfo -HeaderText $headerText

# Receivedヘッダーの解析
$hops = ConvertFrom-ReceivedHeader -HeaderText $headerText

# 認証結果の抽出
$authResults = ConvertFrom-AuthenticationResults -HeaderText $headerText

# ループ検出
$loopInfo = Find-MailLoop -Hops $hops

# 遅延計算
$delays = Calculate-Delays -Hops $hops

# セキュリティ問題の検出
$securityIssues = Find-SecurityIssues -AuthResults $authResults -Hops $hops -BasicInfo $basicInfo

# 結果表示
Show-ResultSummary -BasicInfo $basicInfo -Hops $hops -AuthResults $authResults `
                   -LoopInfo $loopInfo -Delays $delays -SecurityIssues $securityIssues `
                   -MailerType $mailerType

# 結果オブジェクトの作成
$result = [PSCustomObject]@{
    MessageID = $basicInfo.MessageID
    From = $basicInfo.From
    To = $basicInfo.To
    Subject = $basicInfo.Subject
    Date = $basicInfo.Date
    ReturnPath = $basicInfo.ReturnPath
    ReplyTo = $basicInfo.ReplyTo
    XMailer = $basicInfo.XMailer
    HopCount = $hops.Count
    SPFResult = $authResults.SPF
    DKIMResult = $authResults.DKIM
    DMARCResult = $authResults.DMARC
    ARCResult = $authResults.ARC
    HasLoop = $loopInfo.HasLoop
    LoopHosts = $loopInfo.LoopHosts
    SecurityIssueCount = $securityIssues.Count
    DetectedMailer = $mailerType
    AnalysisDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

# ホップ情報の詳細
$hopDetails = @()
for ($i = 0; $i -lt $hops.Count; $i++) {
    $hop = $hops[$i]
    $hopDetails += [PSCustomObject]@{
        MessageID = $basicInfo.MessageID
        HopNumber = $hops.Count - $i
        FromHost = $hop.FromHost
        ByHost = $hop.ByHost
        IPAddress = $hop.IPAddress
        Protocol = $hop.Protocol
        Timestamp = $hop.Timestamp
    }
}

# ファイル出力
if (-not $NoFile) {
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
            
            if ($securityIssues.Count -gt 0) {
                $issueCsvPath = "${OutPath}_issues.csv"
                $securityIssues | Export-Csv -Path $issueCsvPath -Encoding UTF8 -NoTypeInformation
            }
            
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
            Write-Host " 📁 CSVファイルに出力しました" -ForegroundColor Green
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
            Write-Host "  サマリー:     $csvPath"
            Write-Host "  ホップ詳細:   $hopCsvPath"
            if ($securityIssues.Count -gt 0) {
                Write-Host "  セキュリティ: $issueCsvPath"
            }
        }
        "JSON" {
            $jsonPath = "$OutPath.json"
            $output = @{
                Summary = $result
                Hops = $hopDetails
                SecurityIssues = $securityIssues
                RawHeader = $headerText.Substring(0, [Math]::Min(5000, $headerText.Length))
            }
            $output | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
            Write-Host " 📁 JSONファイルに出力しました: $jsonPath" -ForegroundColor Green
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
        }
        "Table" {
            # 画面表示のみ（既に表示済み）
            Write-Host "💡 ファイル出力する場合は -OutFormat CSV または -OutFormat JSON を指定してください" -ForegroundColor Gray
        }
    }
}

Write-Host ""
Write-Host "✅ 解析完了" -ForegroundColor Green
Write-Host ""

# 結果オブジェクトを返す
return $result
