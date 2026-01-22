<#
.SYNOPSIS
  メールフロー検証マトリクススクリプト

.DESCRIPTION
  移行後のメールフローが想定どおりに動作しているかを検証します。
  CSVで定義したテストケースに基づき、EXO Message Traceの結果と突合します。

  【検証パターン】
  - 内部→内部（EXOユーザー同士）
  - 内部→外部（EXO→GuardianWall Cloud→インターネット）
  - 外部→内部（FireEye→DMZ SMTP→EXO）
  - EXO→未移行ユーザー（Internal Relay→DMZ SMTP→Courier IMAP）

  【前提条件】
  - テストメールが事前に送信済み
  - EXO Message Trace で検索可能な状態（数分～数時間のラグあり）

.PARAMETER TestCasesFile
  テストケースCSVファイル
  カラム: TestID, From, To, Subject, ExpectedPath, ExpectedResult

.PARAMETER LookbackHours
  Message Traceで検索する過去の時間範囲（デフォルト: 24時間）

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # テストケースファイルで検証
  .\Test-MailFlowMatrix.ps1 -TestCasesFile test_cases.csv

.EXAMPLE
  # 過去48時間を検索
  .\Test-MailFlowMatrix.ps1 -TestCasesFile test_cases.csv -LookbackHours 48

.NOTES
  - ExchangeOnlineManagement モジュールが必要
  - Connect-ExchangeOnline で接続済みであること
  - Message Trace の権限が必要
#>
param(
  [Parameter(Mandatory=$true)]
  [string]$TestCasesFile,
  
  [int]$LookbackHours = 24,
  
  [string]$OutDir = ".\mailflow_validation"
)

# エラーアクションの設定
$ErrorActionPreference = "Continue"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " メールフロー検証マトリクス"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

#----------------------------------------------------------------------
# EXO接続確認
#----------------------------------------------------------------------
Write-Host "[1/5] Exchange Online 接続確認..."

try {
  $org = Get-OrganizationConfig -ErrorAction Stop
  Write-Host "      → 接続済み: $($org.Name)"
} catch {
  throw "Exchange Onlineに接続されていません。Connect-ExchangeOnlineを実行してください。"
}

#----------------------------------------------------------------------
# テストケース読み込み
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/5] テストケースを読み込み..."

if (-not (Test-Path $TestCasesFile)) {
  # サンプルテストケースを生成
  Write-Host "      → テストケースファイルが見つかりません"
  Write-Host "      → サンプルファイルを生成します: $OutDir\sample_test_cases.csv"
  
  $sampleCases = @"
TestID,From,To,Subject,ExpectedPath,ExpectedResult
TC001,user1@contoso.co.jp,user2@contoso.co.jp,内部宛テスト,EXO_INTERNAL,Delivered
TC002,user1@contoso.co.jp,external@gmail.com,外部宛テスト,EXO_GWC_INTERNET,Delivered
TC003,external@gmail.com,user1@contoso.co.jp,外部からの受信テスト,INTERNET_FIREEYE_DMZ_EXO,Delivered
TC004,user1@contoso.co.jp,unmigrated@contoso.co.jp,未移行ユーザー宛テスト,EXO_INTERNALRELAY_DMZ_COURIER,Delivered
TC005,user1@contoso.co.jp,test@test.contoso.co.jp,テストドメイン宛,EXO_INTERNAL,Delivered
"@
  $sampleCases | Out-File (Join-Path $OutDir "sample_test_cases.csv") -Encoding UTF8
  
  throw "テストケースファイルを指定してください: -TestCasesFile <path>"
}

$testCases = Import-Csv $TestCasesFile
Write-Host "      → テストケース数: $($testCases.Count)"

#----------------------------------------------------------------------
# 検索時間範囲の設定
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/5] Message Trace 検索範囲を設定..."

$endDate = Get-Date
$startDate = $endDate.AddHours(-$LookbackHours)

Write-Host "      → 開始: $($startDate.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "      → 終了: $($endDate.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "      → 範囲: 過去 $LookbackHours 時間"

#----------------------------------------------------------------------
# 各テストケースの検証
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/5] ★ メールフロー検証実行..."

$results = @()

foreach ($tc in $testCases) {
  Write-Host ""
  Write-Host "  【$($tc.TestID)】$($tc.From) → $($tc.To)"
  Write-Host "    Subject: $($tc.Subject)"
  Write-Host "    期待経路: $($tc.ExpectedPath)"
  
  # Message Trace 検索
  try {
    $trace = Get-MessageTrace `
      -SenderAddress $tc.From `
      -RecipientAddress $tc.To `
      -StartDate $startDate `
      -EndDate $endDate `
      -ErrorAction Stop
    
    # 件名でフィルタ（部分一致）
    if ($tc.Subject) {
      $trace = $trace | Where-Object { $_.Subject -like "*$($tc.Subject)*" }
    }
    
    if ($trace -and $trace.Count -gt 0) {
      # 最新のトレースを取得
      $latestTrace = $trace | Sort-Object Received -Descending | Select-Object -First 1
      
      # 詳細を取得
      $traceDetail = Get-MessageTraceDetail `
        -MessageTraceId $latestTrace.MessageTraceId `
        -RecipientAddress $tc.To `
        -ErrorAction SilentlyContinue
      
      # 経路を分析
      $actualPath = Get-MailPathAnalysis -Trace $latestTrace -Detail $traceDetail
      $pathMatch = ($actualPath -eq $tc.ExpectedPath) -or ($tc.ExpectedPath -eq "ANY")
      $statusMatch = ($latestTrace.Status -eq $tc.ExpectedResult)
      
      $overall = if ($pathMatch -and $statusMatch) { "PASS" } elseif ($statusMatch) { "WARN" } else { "FAIL" }
      
      Write-Host "    Status: $($latestTrace.Status)" -ForegroundColor $(if ($statusMatch) { "Green" } else { "Red" })
      Write-Host "    実際経路: $actualPath" -ForegroundColor $(if ($pathMatch) { "Green" } else { "Yellow" })
      Write-Host "    判定: $overall" -ForegroundColor $(if ($overall -eq "PASS") { "Green" } elseif ($overall -eq "WARN") { "Yellow" } else { "Red" })
      
      $results += [PSCustomObject]@{
        TestID = $tc.TestID
        From = $tc.From
        To = $tc.To
        Subject = $tc.Subject
        ExpectedPath = $tc.ExpectedPath
        ExpectedResult = $tc.ExpectedResult
        ActualPath = $actualPath
        ActualResult = $latestTrace.Status
        MessageTraceId = $latestTrace.MessageTraceId
        Received = $latestTrace.Received
        PathMatch = $pathMatch
        StatusMatch = $statusMatch
        Overall = $overall
        Details = ($traceDetail | ForEach-Object { "$($_.Event): $($_.Detail)" }) -join " | "
      }
    } else {
      Write-Host "    Status: NOT_FOUND" -ForegroundColor Red
      Write-Host "    判定: FAIL（メールが見つかりません）" -ForegroundColor Red
      
      $results += [PSCustomObject]@{
        TestID = $tc.TestID
        From = $tc.From
        To = $tc.To
        Subject = $tc.Subject
        ExpectedPath = $tc.ExpectedPath
        ExpectedResult = $tc.ExpectedResult
        ActualPath = "N/A"
        ActualResult = "NOT_FOUND"
        MessageTraceId = "N/A"
        Received = "N/A"
        PathMatch = $false
        StatusMatch = $false
        Overall = "FAIL"
        Details = "Message Trace でメールが見つかりません。時間範囲を広げるか、メールが送信されているか確認してください。"
      }
    }
  } catch {
    Write-Host "    エラー: $($_.Exception.Message)" -ForegroundColor Red
    
    $results += [PSCustomObject]@{
      TestID = $tc.TestID
      From = $tc.From
      To = $tc.To
      Subject = $tc.Subject
      ExpectedPath = $tc.ExpectedPath
      ExpectedResult = $tc.ExpectedResult
      ActualPath = "ERROR"
      ActualResult = "ERROR"
      MessageTraceId = "N/A"
      Received = "N/A"
      PathMatch = $false
      StatusMatch = $false
      Overall = "ERROR"
      Details = $_.Exception.Message
    }
  }
}

#----------------------------------------------------------------------
# 経路分析関数
#----------------------------------------------------------------------
function Get-MailPathAnalysis {
  param($Trace, $Detail)
  
  # 簡易的な経路判定
  $events = if ($Detail) { $Detail | ForEach-Object { $_.Event } } else { @() }
  
  # 経路パターンの判定
  if ($events -contains "Receive" -and $events -contains "Send") {
    if ($Trace.RecipientAddress -match '@.+\.onmicrosoft\.com$') {
      return "EXO_INTERNAL"
    }
    
    # コネクタ経由の判定
    $sendDetail = $Detail | Where-Object { $_.Event -eq "Send" }
    if ($sendDetail -and $sendDetail.Detail -match "GuardianWall|gwc") {
      return "EXO_GWC_INTERNET"
    }
    if ($sendDetail -and $sendDetail.Detail -match "OnPrem|DMZ|Fallback") {
      return "EXO_INTERNALRELAY_DMZ_COURIER"
    }
    
    return "EXO_OUTBOUND"
  }
  
  if ($Trace.Status -eq "Delivered") {
    return "EXO_INTERNAL"
  }
  
  if ($Trace.Status -eq "Pending") {
    return "PENDING"
  }
  
  return "UNKNOWN"
}

#----------------------------------------------------------------------
# 結果出力
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] 結果を出力..."

# CSV出力
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "validation_results.csv")

# 統計
$passCount = ($results | Where-Object { $_.Overall -eq "PASS" }).Count
$warnCount = ($results | Where-Object { $_.Overall -eq "WARN" }).Count
$failCount = ($results | Where-Object { $_.Overall -eq "FAIL" }).Count
$errorCount = ($results | Where-Object { $_.Overall -eq "ERROR" }).Count

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# メールフロー検証サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【検索範囲】$($startDate.ToString('yyyy-MM-dd HH:mm:ss')) ～ $($endDate.ToString('yyyy-MM-dd HH:mm:ss'))

【検証結果】
  テストケース総数: $($results.Count)
  ✓ PASS:  $passCount
  ⚠ WARN:  $warnCount
  ✗ FAIL:  $failCount
  ? ERROR: $errorCount

【判定基準】
  PASS: 期待経路と期待結果が一致
  WARN: 期待結果は一致するが、経路が想定と異なる
  FAIL: 期待結果が一致しない、またはメールが見つからない
  ERROR: Message Trace の取得でエラー

#-------------------------------------------------------------------------------
# 詳細結果
#-------------------------------------------------------------------------------

"@

foreach ($r in $results) {
  $icon = switch ($r.Overall) {
    "PASS" { "✓" }
    "WARN" { "⚠" }
    "FAIL" { "✗" }
    default { "?" }
  }
  $summary += "[$icon] $($r.TestID): $($r.From) → $($r.To)`n"
  $summary += "    期待: $($r.ExpectedPath) / $($r.ExpectedResult)`n"
  $summary += "    実際: $($r.ActualPath) / $($r.ActualResult)`n"
  if ($r.Overall -ne "PASS") {
    $summary += "    詳細: $($r.Details)`n"
  }
  $summary += "`n"
}

$summary += @"
#-------------------------------------------------------------------------------
# トラブルシューティング
#-------------------------------------------------------------------------------

【メールが見つからない場合】
  1. テストメールが送信されているか確認
  2. 検索時間範囲を広げる（-LookbackHours 48 など）
  3. 送信元/宛先アドレスが正しいか確認
  4. EXO側でメールがブロックされていないか確認

【経路が想定と異なる場合】
  1. Accepted Domain のタイプを確認（Authoritative/InternalRelay）
  2. Outbound Connector の設定を確認
  3. Transport Rule の設定を確認
  4. Postfix/DMZ SMTP のルーティング設定を確認

【Internal Relay が機能しない場合】
  1. EXOに「紛れ」メールボックスがないか確認（Detect-StrayRecipients.ps1）
  2. Outbound Connector が有効で、RecipientDomains が正しいか確認
  3. オンプレ側の受信設定を確認

"@

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

if ($failCount -gt 0 -or $errorCount -gt 0) {
  Write-Host ""
  Write-Host "【警告】$failCount 件のFAIL、$errorCount 件のERRORがあります" -ForegroundColor Red
  Write-Host "        validation_results.csv を確認してください"
}

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"

# 終了コード
if ($failCount -gt 0 -or $errorCount -gt 0) { exit 1 } else { exit 0 }
