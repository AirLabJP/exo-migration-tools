<#
.SYNOPSIS
  EXO コネクタ切り戻し（削除）スクリプト

.DESCRIPTION
  New-EXOConnectors.ps1 で作成したコネクタを削除し、移行前の状態に戻します。

  【削除対象コネクタ】
  - To-GuardianWall-Cloud (Outbound)
  - To-OnPrem-DMZ-Fallback (Outbound)
  - From-AWS-DMZ-SMTP (Inbound)

  【注意】
  - 削除前に必ず現在の設定をバックアップ（Collect-EXOInventory.ps1）
  - 運用中のコネクタを削除するとメールフローに影響

.PARAMETER ConnectorNames
  削除するコネクタ名の配列（省略時はデフォルトの3つ）

.PARAMETER WhatIfMode
  実際には削除せず、確認のみ

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # WhatIfで確認
  .\Undo-EXOConnectors.ps1 -WhatIfMode

  # 本番実行
  .\Undo-EXOConnectors.ps1

  # 特定のコネクタのみ削除
  .\Undo-EXOConnectors.ps1 -ConnectorNames @("To-GuardianWall-Cloud")

.NOTES
  - ExchangeOnlineManagement モジュールが必要
  - Connect-ExchangeOnline で接続済みであること
  - Organization Management または Exchange Administrator 権限が必要
#>
param(
  [string[]]$ConnectorNames,
  
  [switch]$WhatIfMode,
  
  [string]$OutDir = ".\connector_rollback"
)

# デフォルトのコネクタ名
$DefaultConnectorNames = @(
  "To-GuardianWall-Cloud",
  "To-OnPrem-DMZ-Fallback",
  "From-AWS-DMZ-SMTP"
)

if (-not $ConnectorNames -or $ConnectorNames.Count -eq 0) {
  $ConnectorNames = $DefaultConnectorNames
}

# エラーアクションの設定
$ErrorActionPreference = "Continue"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " EXO コネクタ切り戻し（削除）"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

if ($WhatIfMode) {
  Write-Host "【WhatIfモード】実際の削除は行いません" -ForegroundColor Yellow
  Write-Host ""
}

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
# 現在のコネクタ状態をバックアップ
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/4] 現在のコネクタ設定をバックアップ..."

$outboundConnectors = Get-OutboundConnector -ErrorAction SilentlyContinue
$inboundConnectors = Get-InboundConnector -ErrorAction SilentlyContinue

# バックアップ出力
$outboundConnectors | Select-Object Name,Enabled,SmartHosts,RecipientDomains,ConnectorType,TlsSettings,UseMXRecord,IsTransportRuleScoped |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "outbound_connectors_before.csv")
$inboundConnectors | Select-Object Name,Enabled,SenderIPAddresses,SenderDomains,ConnectorType,RequireTls,RestrictDomainsToIPAddresses |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "inbound_connectors_before.csv")

# 詳細JSONも保存
$outboundConnectors | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "outbound_connectors_before.json") -Encoding UTF8
$inboundConnectors | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "inbound_connectors_before.json") -Encoding UTF8

Write-Host "      → Outbound Connector: $($outboundConnectors.Count) 件"
Write-Host "      → Inbound Connector:  $($inboundConnectors.Count) 件"

#----------------------------------------------------------------------
# 削除対象の確認
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/4] 削除対象コネクタを確認..."

$results = @()

foreach ($name in $ConnectorNames) {
  # Outbound Connector を検索
  $outbound = $outboundConnectors | Where-Object { $_.Name -eq $name }
  if ($outbound) {
    Write-Host "  [Outbound] $name"
    Write-Host "    SmartHosts: $($outbound.SmartHosts -join ', ')"
    Write-Host "    RecipientDomains: $($outbound.RecipientDomains -join ', ')"
    Write-Host "    Enabled: $($outbound.Enabled)"
    
    $results += [PSCustomObject]@{
      Name = $name
      Type = "Outbound"
      Found = $true
      Details = "SmartHosts: $($outbound.SmartHosts -join ', ')"
      Status = $null
      Message = $null
    }
    continue
  }
  
  # Inbound Connector を検索
  $inbound = $inboundConnectors | Where-Object { $_.Name -eq $name }
  if ($inbound) {
    Write-Host "  [Inbound] $name"
    Write-Host "    SenderIPAddresses: $($inbound.SenderIPAddresses -join ', ')"
    Write-Host "    Enabled: $($inbound.Enabled)"
    
    $results += [PSCustomObject]@{
      Name = $name
      Type = "Inbound"
      Found = $true
      Details = "SenderIPAddresses: $($inbound.SenderIPAddresses -join ', ')"
      Status = $null
      Message = $null
    }
    continue
  }
  
  # 見つからない
  Write-Host "  [NotFound] $name" -ForegroundColor Yellow
  $results += [PSCustomObject]@{
    Name = $name
    Type = "Unknown"
    Found = $false
    Details = "コネクタが存在しません"
    Status = "SKIP"
    Message = "コネクタが存在しません"
  }
}

#----------------------------------------------------------------------
# 削除実行
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/4] ★ コネクタを削除..."

$successCount = 0
$skipCount = 0
$errorCount = 0

foreach ($r in $results) {
  if (-not $r.Found) {
    $skipCount++
    continue
  }
  
  try {
    if ($WhatIfMode) {
      Write-Host "  [WhatIf] $($r.Name) ($($r.Type)) を削除予定"
      $r.Status = "WHATIF"
      $r.Message = "WhatIfモード - 実際の削除なし"
      $skipCount++
    } else {
      if ($r.Type -eq "Outbound") {
        Remove-OutboundConnector -Identity $r.Name -Confirm:$false -ErrorAction Stop
      } else {
        Remove-InboundConnector -Identity $r.Name -Confirm:$false -ErrorAction Stop
      }
      Write-Host "  [削除完了] $($r.Name) ($($r.Type))" -ForegroundColor Green
      $r.Status = "DELETED"
      $r.Message = "削除完了"
      $successCount++
    }
  } catch {
    Write-Host "  [エラー] $($r.Name): $($_.Exception.Message)" -ForegroundColor Red
    $r.Status = "ERROR"
    $r.Message = $_.Exception.Message
    $errorCount++
  }
}

# 結果をCSV出力
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "deletion_results.csv")

#----------------------------------------------------------------------
# 削除後の状態を確認
#----------------------------------------------------------------------
if (-not $WhatIfMode -and $successCount -gt 0) {
  Write-Host ""
  Write-Host "【削除後のコネクタ状態】"
  
  $outboundAfter = Get-OutboundConnector -ErrorAction SilentlyContinue
  $inboundAfter = Get-InboundConnector -ErrorAction SilentlyContinue
  
  Write-Host "  Outbound Connector: $($outboundAfter.Count) 件"
  Write-Host "  Inbound Connector:  $($inboundAfter.Count) 件"
  
  # バックアップ出力
  $outboundAfter | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "outbound_connectors_after.csv")
  $inboundAfter | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "inbound_connectors_after.csv")
}

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# EXO コネクタ切り戻しサマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })

【処理結果】
  対象コネクタ: $($ConnectorNames.Count)
  削除成功:     $successCount
  スキップ:     $skipCount
  エラー:       $errorCount

【削除対象コネクタ】
$($ConnectorNames | ForEach-Object { "  - $_" } | Out-String)

【バックアップファイル】
  outbound_connectors_before.csv/json ← 削除前の Outbound Connector
  inbound_connectors_before.csv/json  ← 削除前の Inbound Connector
  deletion_results.csv                ← 削除処理結果

#-------------------------------------------------------------------------------
# 復元方法
#-------------------------------------------------------------------------------

  削除前のバックアップJSONを確認し、必要に応じて手動で再作成してください。
  または、New-EXOConnectors.ps1 を再実行してください。

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

"@

if ($WhatIfMode) {
  $summary += @"
  WhatIfモードでした。実際に削除するには -WhatIfMode なしで再実行してください。

"@
} else {
  $summary += @"
  1. メールフローが正常に動作しているか確認
  2. 必要に応じて Accepted Domain のタイプを Authoritative に変更
  3. Postfix/DMZ SMTP のルーティング設定も元に戻す

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
