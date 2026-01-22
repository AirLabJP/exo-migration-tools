<#
.SYNOPSIS
  EXO Accepted Domain タイプ一括変更スクリプト

.DESCRIPTION
  Exchange Onlineの承認済みドメイン（Accepted Domain）のタイプを一括変更します。
  
  【タイプの意味】
  - Authoritative: EXOでメールボックスがない宛先はNDR返却
  - InternalRelay: EXOでメールボックスがない宛先はOutbound Connectorで転送
  
  【使用シーン】
  - 移行開始時: Authoritative → InternalRelay（未移行ユーザーへのフォールバック有効化）
  - 移行完了時: InternalRelay → Authoritative（フォールバック無効化）

.PARAMETER DomainsFile
  対象ドメイン一覧ファイル（1行1ドメイン、#でコメント）

.PARAMETER Domains
  対象ドメイン配列（直接指定）

.PARAMETER DomainType
  変更後のドメインタイプ（Authoritative または InternalRelay）

.PARAMETER WhatIfMode
  実際には変更せず、確認のみ

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # InternalRelayに変更（WhatIfで確認）
  .\Set-AcceptedDomainType.ps1 -DomainsFile domains.txt -DomainType InternalRelay -WhatIfMode

  # InternalRelayに変更（本番実行）
  .\Set-AcceptedDomainType.ps1 -DomainsFile domains.txt -DomainType InternalRelay

  # 移行完了後、Authoritativeに戻す
  .\Set-AcceptedDomainType.ps1 -DomainsFile domains.txt -DomainType Authoritative

.NOTES
  - ExchangeOnlineManagement モジュールが必要
  - Connect-ExchangeOnline で接続済みであること
  - Organization Management または Exchange Administrator 権限が必要
#>
param(
  [string]$DomainsFile,
  [string[]]$Domains,
  
  [Parameter(Mandatory=$true)]
  [ValidateSet("Authoritative","InternalRelay")]
  [string]$DomainType,
  
  [switch]$WhatIfMode,
  
  [string]$OutDir = ".\accepted_domain_change"
)

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " EXO Accepted Domain タイプ一括変更"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

#----------------------------------------------------------------------
# ドメインリストの読み込み
#----------------------------------------------------------------------
$domainList = @()
if ($DomainsFile -and (Test-Path $DomainsFile)) {
  $domainList = Get-Content $DomainsFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim().ToLowerInvariant() }
  Write-Host "ドメインファイル: $DomainsFile"
} elseif ($Domains -and $Domains.Count -gt 0) {
  $domainList = $Domains | ForEach-Object { $_.Trim().ToLowerInvariant() }
  Write-Host "ドメイン: 直接指定"
} else {
  throw "エラー: -DomainsFile または -Domains を指定してください"
}

Write-Host "対象ドメイン数: $($domainList.Count)"
Write-Host "変更後タイプ: $DomainType"
if ($WhatIfMode) {
  Write-Host ""
  Write-Host "【WhatIfモード】実際の変更は行いません" -ForegroundColor Yellow
}
Write-Host ""

#----------------------------------------------------------------------
# EXO接続確認
#----------------------------------------------------------------------
Write-Host "[1/4] Exchange Online 接続確認..."

try {
  $org = Get-OrganizationConfig -ErrorAction Stop
  Write-Host "      → 接続済み: $($org.Name)"
} catch {
  throw "Exchange Onlineに接続されていません。Connect-ExchangeOnlineを実行してください。"
}

#----------------------------------------------------------------------
# 現在のAccepted Domain状態を取得
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/4] 現在のAccepted Domain状態を取得..."

$acceptedDomains = Get-AcceptedDomain -ErrorAction Stop
$acceptedDomains | Select-Object Name,DomainName,DomainType,Default | 
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "accepted_domains_before.csv")

Write-Host "      → 全Accepted Domain: $($acceptedDomains.Count) 件"

# 対象ドメインの現在状態を確認
$targetDomains = @()
$notFound = @()

foreach ($d in $domainList) {
  $ad = $acceptedDomains | Where-Object { $_.DomainName -eq $d }
  if ($ad) {
    $targetDomains += [PSCustomObject]@{
      DomainName = $ad.DomainName
      Name = $ad.Name
      CurrentType = $ad.DomainType
      NewType = $DomainType
      NeedsChange = ($ad.DomainType -ne $DomainType)
      IsDefault = $ad.Default
    }
  } else {
    $notFound += $d
  }
}

Write-Host ""
Write-Host "【対象ドメインの現在状態】"
foreach ($td in $targetDomains) {
  $status = if ($td.NeedsChange) { "→ 変更対象" } else { "→ 変更不要（既に$DomainType）" }
  $defaultMark = if ($td.IsDefault) { " [Default]" } else { "" }
  Write-Host "  $($td.DomainName)$defaultMark : $($td.CurrentType) $status"
}

if ($notFound.Count -gt 0) {
  Write-Host ""
  Write-Host "【警告】以下のドメインはAccepted Domainに存在しません:" -ForegroundColor Yellow
  foreach ($nf in $notFound) {
    Write-Host "  ✗ $nf" -ForegroundColor Yellow
  }
}

# 変更前状態をJSONで保存
$targetDomains | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "target_domains_before.json") -Encoding UTF8

#----------------------------------------------------------------------
# Defaultドメインのチェック
#----------------------------------------------------------------------
$defaultDomainChange = $targetDomains | Where-Object { $_.IsDefault -and $_.NeedsChange }
if ($defaultDomainChange) {
  Write-Host ""
  Write-Host "【注意】デフォルトドメインが変更対象に含まれています:" -ForegroundColor Yellow
  Write-Host "  $($defaultDomainChange.DomainName)"
  Write-Host "  デフォルトドメインのタイプ変更は通常のメールフローに影響する可能性があります。"
}

#----------------------------------------------------------------------
# 変更実行
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/4] Accepted Domain タイプを変更..."

$results = @()
$successCount = 0
$skipCount = 0
$errorCount = 0

foreach ($td in $targetDomains) {
  if (-not $td.NeedsChange) {
    $results += [PSCustomObject]@{
      DomainName = $td.DomainName
      Status = "SKIP"
      OldType = $td.CurrentType
      NewType = $td.NewType
      Message = "既に $DomainType"
    }
    $skipCount++
    continue
  }
  
  try {
    if ($WhatIfMode) {
      Write-Host "  [WhatIf] $($td.DomainName): $($td.CurrentType) → $DomainType"
      $results += [PSCustomObject]@{
        DomainName = $td.DomainName
        Status = "WHATIF"
        OldType = $td.CurrentType
        NewType = $td.NewType
        Message = "WhatIfモード - 実際の変更なし"
      }
      $skipCount++
    } else {
      Set-AcceptedDomain -Identity $td.DomainName -DomainType $DomainType -ErrorAction Stop
      Write-Host "  [成功] $($td.DomainName): $($td.CurrentType) → $DomainType" -ForegroundColor Green
      $results += [PSCustomObject]@{
        DomainName = $td.DomainName
        Status = "SUCCESS"
        OldType = $td.CurrentType
        NewType = $td.NewType
        Message = "変更完了"
      }
      $successCount++
    }
  } catch {
    Write-Host "  [エラー] $($td.DomainName): $($_.Exception.Message)" -ForegroundColor Red
    $results += [PSCustomObject]@{
      DomainName = $td.DomainName
      Status = "ERROR"
      OldType = $td.CurrentType
      NewType = $td.NewType
      Message = $_.Exception.Message
    }
    $errorCount++
  }
}

# 結果をCSV出力
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "change_results.csv")

#----------------------------------------------------------------------
# 変更後の状態を取得
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/4] 変更後の状態を確認..."

if (-not $WhatIfMode) {
  $acceptedDomainsAfter = Get-AcceptedDomain -ErrorAction Stop
  $acceptedDomainsAfter | Select-Object Name,DomainName,DomainType,Default | 
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "accepted_domains_after.csv")
  
  Write-Host ""
  Write-Host "【変更後の状態】"
  foreach ($d in $domainList) {
    $ad = $acceptedDomainsAfter | Where-Object { $_.DomainName -eq $d }
    if ($ad) {
      $defaultMark = if ($ad.Default) { " [Default]" } else { "" }
      Write-Host "  $($ad.DomainName)$defaultMark : $($ad.DomainType)"
    }
  }
}

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# Accepted Domain タイプ変更サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })
【変更後タイプ】$DomainType

【処理結果】
  対象ドメイン:  $($domainList.Count)
  成功:          $successCount
  スキップ:      $skipCount
  エラー:        $errorCount
  未登録:        $($notFound.Count)

【確認すべきファイル】
  change_results.csv          ← 各ドメインの処理結果
  accepted_domains_before.csv ← 変更前の全Accepted Domain
  accepted_domains_after.csv  ← 変更後の全Accepted Domain

#-------------------------------------------------------------------------------
# タイプの意味
#-------------------------------------------------------------------------------

  Authoritative:
    → EXOでメールボックスがない宛先には NDR を返却
    → 移行完了後の通常状態

  InternalRelay:
    → EXOでメールボックスがない宛先は Outbound Connector で転送
    → 移行中のフォールバック用（未移行ユーザーへの救済経路）
    → 必ず対応するOutbound Connectorが必要

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

"@

if ($DomainType -eq "InternalRelay") {
  $summary += @"
  InternalRelay に変更した場合:
  1. 対象ドメイン宛のOutbound Connectorが設定されていることを確認
  2. テストメールを送信して、未移行ユーザー宛が転送されることを確認
  3. EXO Message Trace でメールの経路を確認

"@
} else {
  $summary += @"
  Authoritative に変更した場合:
  1. 全ユーザーがEXOに移行済みであることを確認
  2. テストメールを送信して、正常に配送されることを確認
  3. フォールバック用Outbound Connectorの無効化を検討

"@
}

if ($WhatIfMode) {
  $summary += @"
【WhatIfモード】
  実際の変更は行われていません。
  問題がなければ -WhatIfMode なしで再実行してください。

"@
}

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

if ($errorCount -gt 0) {
  Write-Host "【警告】$errorCount 件のエラーが発生しました" -ForegroundColor Red
  Write-Host "        change_results.csv を確認してください"
}

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"

# 終了コード
if ($errorCount -gt 0) { exit 1 } else { exit 0 }
