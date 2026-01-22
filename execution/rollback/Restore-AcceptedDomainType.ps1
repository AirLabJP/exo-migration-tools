<#
.SYNOPSIS
  EXO Accepted Domain タイプ復元スクリプト

.DESCRIPTION
  Accepted Domain のタイプを Authoritative に戻します（InternalRelay → Authoritative）。
  移行をロールバックする場合、または移行完了後の正常化に使用します。

  【用途】
  - 移行ロールバック: InternalRelay に変更したドメインを Authoritative に戻す
  - 移行完了後: 全ユーザー移行後に Authoritative に変更してフォールバックを無効化

  【注意】
  - Authoritative に変更すると、EXOにメールボックスがない宛先はNDRになります
  - 未移行ユーザーがいる状態で変更するとメールが届かなくなります

.PARAMETER DomainsFile
  対象ドメイン一覧ファイル（1行1ドメイン、#でコメント）

.PARAMETER Domains
  対象ドメイン配列（直接指定）

.PARAMETER BackupFile
  Set-AcceptedDomainType.ps1 が出力した target_domains_before.json からの復元

.PARAMETER WhatIfMode
  実際には変更せず、確認のみ

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # Authoritativeに復元（WhatIfで確認）
  .\Restore-AcceptedDomainType.ps1 -DomainsFile domains.txt -WhatIfMode

  # バックアップファイルから復元
  .\Restore-AcceptedDomainType.ps1 -BackupFile .\accepted_domain_change\20260117_120000\target_domains_before.json

  # 本番実行
  .\Restore-AcceptedDomainType.ps1 -DomainsFile domains.txt

.NOTES
  - ExchangeOnlineManagement モジュールが必要
  - Connect-ExchangeOnline で接続済みであること
  - 未移行ユーザーがいないことを確認してから実行
#>
param(
  [string]$DomainsFile,
  [string[]]$Domains,
  [string]$BackupFile,
  
  [switch]$WhatIfMode,
  
  [string]$OutDir = ".\accepted_domain_restore"
)

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " EXO Accepted Domain タイプ復元（→ Authoritative）"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

if ($WhatIfMode) {
  Write-Host "【WhatIfモード】実際の変更は行いません" -ForegroundColor Yellow
  Write-Host ""
}

#----------------------------------------------------------------------
# 復元対象の決定
#----------------------------------------------------------------------
$restoreTargets = @()

if ($BackupFile -and (Test-Path $BackupFile)) {
  Write-Host "【バックアップファイルからの復元モード】"
  Write-Host "  ファイル: $BackupFile"
  Write-Host ""
  
  $backupData = Get-Content $BackupFile -Raw | ConvertFrom-Json
  foreach ($item in $backupData) {
    $restoreTargets += [PSCustomObject]@{
      DomainName = $item.DomainName
      OriginalType = $item.CurrentType
    }
  }
} elseif ($DomainsFile -and (Test-Path $DomainsFile)) {
  Write-Host "【ドメインファイルからの復元モード】"
  Write-Host "  ファイル: $DomainsFile"
  Write-Host "  → 全て Authoritative に変更"
  Write-Host ""
  
  $domainList = Get-Content $DomainsFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim().ToLowerInvariant() }
  foreach ($d in $domainList) {
    $restoreTargets += [PSCustomObject]@{
      DomainName = $d
      OriginalType = "Authoritative"  # 復元先は常にAuthoritative
    }
  }
} elseif ($Domains -and $Domains.Count -gt 0) {
  Write-Host "【直接指定からの復元モード】"
  Write-Host "  → 全て Authoritative に変更"
  Write-Host ""
  
  foreach ($d in $Domains) {
    $restoreTargets += [PSCustomObject]@{
      DomainName = $d.Trim().ToLowerInvariant()
      OriginalType = "Authoritative"
    }
  }
} else {
  throw "エラー: -DomainsFile、-Domains、または -BackupFile を指定してください"
}

Write-Host "復元対象ドメイン数: $($restoreTargets.Count)"
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
# 現在の状態を取得
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/4] 現在のAccepted Domain状態を取得..."

$acceptedDomains = Get-AcceptedDomain -ErrorAction Stop
$acceptedDomains | Select-Object Name,DomainName,DomainType,Default | 
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "accepted_domains_before.csv")

Write-Host "      → 全Accepted Domain: $($acceptedDomains.Count) 件"

# 復元対象の現在状態を確認
Write-Host ""
Write-Host "【復元対象の現在状態】"
$notFound = @()
$processTargets = @()

foreach ($rt in $restoreTargets) {
  $ad = $acceptedDomains | Where-Object { $_.DomainName -eq $rt.DomainName }
  if ($ad) {
    $needsChange = ($ad.DomainType -ne $rt.OriginalType)
    $status = if ($needsChange) { "→ 変更対象" } else { "→ 変更不要（既に$($rt.OriginalType)）" }
    $defaultMark = if ($ad.Default) { " [Default]" } else { "" }
    Write-Host "  $($rt.DomainName)$defaultMark : $($ad.DomainType) $status"
    
    $processTargets += [PSCustomObject]@{
      DomainName = $rt.DomainName
      CurrentType = $ad.DomainType
      TargetType = $rt.OriginalType
      NeedsChange = $needsChange
      IsDefault = $ad.Default
    }
  } else {
    Write-Host "  $($rt.DomainName) : NOT_FOUND" -ForegroundColor Yellow
    $notFound += $rt.DomainName
  }
}

if ($notFound.Count -gt 0) {
  Write-Host ""
  Write-Host "【警告】以下のドメインはAccepted Domainに存在しません:" -ForegroundColor Yellow
  foreach ($nf in $notFound) {
    Write-Host "  ✗ $nf" -ForegroundColor Yellow
  }
}

#----------------------------------------------------------------------
# 復元実行
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/4] ★ Accepted Domain タイプを復元..."

$results = @()
$successCount = 0
$skipCount = 0
$errorCount = 0

foreach ($pt in $processTargets) {
  if (-not $pt.NeedsChange) {
    $results += [PSCustomObject]@{
      DomainName = $pt.DomainName
      Status = "SKIP"
      OldType = $pt.CurrentType
      NewType = $pt.TargetType
      Message = "既に $($pt.TargetType)"
    }
    $skipCount++
    continue
  }
  
  try {
    if ($WhatIfMode) {
      Write-Host "  [WhatIf] $($pt.DomainName): $($pt.CurrentType) → $($pt.TargetType)"
      $results += [PSCustomObject]@{
        DomainName = $pt.DomainName
        Status = "WHATIF"
        OldType = $pt.CurrentType
        NewType = $pt.TargetType
        Message = "WhatIfモード - 実際の変更なし"
      }
      $skipCount++
    } else {
      Set-AcceptedDomain -Identity $pt.DomainName -DomainType $pt.TargetType -ErrorAction Stop
      Write-Host "  [成功] $($pt.DomainName): $($pt.CurrentType) → $($pt.TargetType)" -ForegroundColor Green
      $results += [PSCustomObject]@{
        DomainName = $pt.DomainName
        Status = "SUCCESS"
        OldType = $pt.CurrentType
        NewType = $pt.TargetType
        Message = "変更完了"
      }
      $successCount++
    }
  } catch {
    Write-Host "  [エラー] $($pt.DomainName): $($_.Exception.Message)" -ForegroundColor Red
    $results += [PSCustomObject]@{
      DomainName = $pt.DomainName
      Status = "ERROR"
      OldType = $pt.CurrentType
      NewType = $pt.TargetType
      Message = $_.Exception.Message
    }
    $errorCount++
  }
}

# 結果をCSV出力
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "restore_results.csv")

#----------------------------------------------------------------------
# 復元後の状態を取得
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/4] 復元後の状態を確認..."

if (-not $WhatIfMode -and $successCount -gt 0) {
  $acceptedDomainsAfter = Get-AcceptedDomain -ErrorAction Stop
  $acceptedDomainsAfter | Select-Object Name,DomainName,DomainType,Default | 
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "accepted_domains_after.csv")
  
  Write-Host ""
  Write-Host "【復元後の状態】"
  foreach ($rt in $restoreTargets) {
    $ad = $acceptedDomainsAfter | Where-Object { $_.DomainName -eq $rt.DomainName }
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
# Accepted Domain タイプ復元サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })

【処理結果】
  対象ドメイン:  $($restoreTargets.Count)
  成功:          $successCount
  スキップ:      $skipCount
  エラー:        $errorCount
  未登録:        $($notFound.Count)

【確認すべきファイル】
  restore_results.csv           ← 各ドメインの処理結果
  accepted_domains_before.csv   ← 復元前の全Accepted Domain
  accepted_domains_after.csv    ← 復元後の全Accepted Domain

#-------------------------------------------------------------------------------
# 注意事項
#-------------------------------------------------------------------------------

  Authoritative に変更すると:
  - EXOにメールボックスがない宛先には NDR が返却されます
  - 未移行ユーザー宛のメールは届かなくなります

  復元前に確認すべきこと:
  - 全ユーザーがEXOに移行済みであること
  - または、移行をロールバックしてPostfix/DMZ SMTPも元に戻すこと

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

"@

if ($WhatIfMode) {
  $summary += @"
  WhatIfモードでした。実際に復元するには -WhatIfMode なしで再実行してください。

"@
} else {
  $summary += @"
  1. テストメールを送信して、正常に配送されることを確認
  2. フォールバック用 Outbound Connector の無効化または削除を検討
  3. Postfix/DMZ SMTP のルーティング設定も元に戻す（必要な場合）

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
}

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"

# 終了コード
if ($errorCount -gt 0) { exit 1 } else { exit 0 }
