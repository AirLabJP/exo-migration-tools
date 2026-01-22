<#
.SYNOPSIS
  EXO設定スナップショットエクスポート

.DESCRIPTION
  Exchange Onlineの主要設定をスナップショットとして保存します。
  変更前後の比較や監査証跡として使用します。

  【取得する設定】
  - Accepted Domains
  - Inbound/Outbound Connectors
  - Transport Rules
  - Remote Domains
  - Organization Config
  - DKIM Signing Config

.PARAMETER SnapshotName
  スナップショット名（省略時はタイムスタンプ）

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # スナップショット取得
  .\Export-EXOConfigSnapshot.ps1

  # 名前付きスナップショット
  .\Export-EXOConfigSnapshot.ps1 -SnapshotName "before_migration"

.NOTES
  - ExchangeOnlineManagement モジュールが必要
  - Connect-ExchangeOnline で接続済みであること
#>
param(
  [string]$SnapshotName,
  
  [string]$OutDir = ".\exo_snapshots"
)

# エラーアクションの設定
$ErrorActionPreference = "Continue"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not $SnapshotName) {
  $SnapshotName = $ts
}
$OutDir = Join-Path $OutDir $SnapshotName
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " EXO設定スナップショット"
Write-Host "============================================================"
Write-Host "スナップショット名: $SnapshotName"
Write-Host "出力先: $OutDir"
Write-Host ""

#----------------------------------------------------------------------
# EXO接続確認
#----------------------------------------------------------------------
Write-Host "[1/8] Exchange Online 接続確認..."

try {
  $org = Get-OrganizationConfig -ErrorAction Stop
  Write-Host "      → 接続済み: $($org.Name)"
} catch {
  throw "Exchange Onlineに接続されていません。Connect-ExchangeOnlineを実行してください。"
}

#----------------------------------------------------------------------
# スナップショット取得
#----------------------------------------------------------------------

# メタデータ
$metadata = @{
  SnapshotName = $SnapshotName
  Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Organization = $org.Name
  TenantId = $org.OrganizationId
}
$metadata | ConvertTo-Json | Out-File (Join-Path $OutDir "metadata.json") -Encoding UTF8

# Organization Config
Write-Host ""
Write-Host "[2/8] Organization Config..."
try {
  $orgConfig = Get-OrganizationConfig
  $orgConfig | Select-Object Name,DisplayName,DefaultPublicFolderMailbox,
    IsDehydrated,MailTipsAllTipsEnabled,MailTipsExternalRecipientsTipsEnabled,
    MailTipsGroupMetricsEnabled,MailTipsLargeAudienceThreshold,
    DefaultAuthenticationPolicy,OAuth2ClientProfileEnabled |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "organization_config.csv")
  $orgConfig | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "organization_config.json") -Encoding UTF8
  Write-Host "      → 保存完了"
} catch {
  Write-Host "      → エラー: $_" -ForegroundColor Yellow
}

# Accepted Domains
Write-Host ""
Write-Host "[3/8] Accepted Domains..."
try {
  $acceptedDomains = Get-AcceptedDomain
  $acceptedDomains | Select-Object Name,DomainName,DomainType,Default,
    AuthenticationType,MatchSubDomains |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "accepted_domains.csv")
  $acceptedDomains | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "accepted_domains.json") -Encoding UTF8
  Write-Host "      → $($acceptedDomains.Count) 件"
} catch {
  Write-Host "      → エラー: $_" -ForegroundColor Yellow
}

# Inbound Connectors
Write-Host ""
Write-Host "[4/8] Inbound Connectors..."
try {
  $inboundConnectors = Get-InboundConnector
  $inboundConnectors | Select-Object Name,Enabled,ConnectorType,
    SenderIPAddresses,SenderDomains,RequireTls,
    RestrictDomainsToIPAddresses,RestrictDomainsToCertificate,
    TlsSenderCertificateName,CloudServicesMailEnabled |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "inbound_connectors.csv")
  $inboundConnectors | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "inbound_connectors.json") -Encoding UTF8
  Write-Host "      → $($inboundConnectors.Count) 件"
} catch {
  Write-Host "      → エラー: $_" -ForegroundColor Yellow
}

# Outbound Connectors
Write-Host ""
Write-Host "[5/8] Outbound Connectors..."
try {
  $outboundConnectors = Get-OutboundConnector
  $outboundConnectors | Select-Object Name,Enabled,ConnectorType,
    SmartHosts,RecipientDomains,TlsSettings,UseMXRecord,
    IsTransportRuleScoped,RouteAllMessagesViaOnPremises,
    CloudServicesMailEnabled |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "outbound_connectors.csv")
  $outboundConnectors | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "outbound_connectors.json") -Encoding UTF8
  Write-Host "      → $($outboundConnectors.Count) 件"
} catch {
  Write-Host "      → エラー: $_" -ForegroundColor Yellow
}

# Transport Rules
Write-Host ""
Write-Host "[6/8] Transport Rules..."
try {
  $transportRules = Get-TransportRule
  $transportRules | Select-Object Name,State,Priority,
    FromScope,SentToScope,
    RouteMessageOutboundConnector,
    SetHeaderName,SetHeaderValue,
    ExceptIfHeaderContainsMessageHeader,ExceptIfHeaderContainsWords,
    RejectMessageReasonText,RejectMessageEnhancedStatusCode |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "transport_rules.csv")
  $transportRules | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "transport_rules.json") -Encoding UTF8
  Write-Host "      → $($transportRules.Count) 件"
} catch {
  Write-Host "      → エラー: $_" -ForegroundColor Yellow
}

# Remote Domains
Write-Host ""
Write-Host "[7/8] Remote Domains..."
try {
  $remoteDomains = Get-RemoteDomain
  $remoteDomains | Select-Object Name,DomainName,
    AllowedOOFType,AutoForwardEnabled,AutoReplyEnabled,
    DeliveryReportEnabled,NDREnabled,
    TNEFEnabled,CharacterSet |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "remote_domains.csv")
  $remoteDomains | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "remote_domains.json") -Encoding UTF8
  Write-Host "      → $($remoteDomains.Count) 件"
} catch {
  Write-Host "      → エラー: $_" -ForegroundColor Yellow
}

# DKIM Signing Config
Write-Host ""
Write-Host "[8/8] DKIM Signing Config..."
try {
  $dkimConfig = Get-DkimSigningConfig
  $dkimConfig | Select-Object Domain,Enabled,Status,
    Selector1CNAME,Selector2CNAME,
    Selector1PublicKey,Selector2PublicKey |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "dkim_config.csv")
  $dkimConfig | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "dkim_config.json") -Encoding UTF8
  Write-Host "      → $($dkimConfig.Count) 件"
} catch {
  Write-Host "      → エラー: $_" -ForegroundColor Yellow
}

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# EXO設定スナップショット サマリー
#===============================================================================

【スナップショット情報】
  名前:     $SnapshotName
  取得日時: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  組織:     $($org.Name)

【取得した設定】
  - organization_config.csv/json
  - accepted_domains.csv/json
  - inbound_connectors.csv/json
  - outbound_connectors.csv/json
  - transport_rules.csv/json
  - remote_domains.csv/json
  - dkim_config.csv/json

#-------------------------------------------------------------------------------
# スナップショットの活用方法
#-------------------------------------------------------------------------------

1. 変更前後の比較
   - 作業前に取得: .\Export-EXOConfigSnapshot.ps1 -SnapshotName "before"
   - 作業後に取得: .\Export-EXOConfigSnapshot.ps1 -SnapshotName "after"
   - 差分確認: Compare-Object (Get-Content before\*.json) (Get-Content after\*.json)

2. 監査証跡
   - 設定変更時に毎回スナップショットを取得
   - 変更理由と合わせて保管

3. 障害時の復元参考
   - 正常時のスナップショットを参照して復元

#-------------------------------------------------------------------------------
# 比較スクリプト例
#-------------------------------------------------------------------------------

# 特定ファイルの差分
\$before = Get-Content ".\exo_snapshots\before\accepted_domains.json" | ConvertFrom-Json
\$after = Get-Content ".\exo_snapshots\after\accepted_domains.json" | ConvertFrom-Json

# ドメインタイプの変更を確認
\$before | ForEach-Object {
  \$b = \$_
  \$a = \$after | Where-Object { \$_.DomainName -eq \$b.DomainName }
  if (\$a -and \$a.DomainType -ne \$b.DomainType) {
    Write-Host "\$(\$b.DomainName): \$(\$b.DomainType) -> \$(\$a.DomainType)"
  }
}

"@

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"
