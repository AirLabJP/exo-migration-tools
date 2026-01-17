<#
.SYNOPSIS
  Exchange Online 棚卸しスクリプト

.DESCRIPTION
  Exchange Onlineの受信者・コネクタ・ドメイン情報を収集し、
  EXO移行計画に必要な情報を取得します。

  【収集する情報】
  - Accepted Domains（承認済みドメイン）
  - Inbound/Outbound Connectors
  - 受信者一覧（Mailbox/MailUser/Contact/Group）
  - Transport Rules（メールフロールール）
  - Remote Domains

  【出力ファイルと確認ポイント】
  accepted_domains.csv    ← ★重要: ドメイン一覧とタイプ（Authoritative/InternalRelay）
  inbound_connectors.csv  ← ★重要: 外部からの受信コネクタ
  outbound_connectors.csv ← ★重要: 外部への送信コネクタ
  recipients.csv          ← ★重要: 全受信者一覧（紛れ検出用）
  mailboxes.csv           ← メールボックス詳細（IsDirSynced含む）
  transport_rules.csv     ← メールフロールール
  summary.txt             ← 統計サマリー

.PARAMETER OutRoot
  出力先ルートフォルダ

.PARAMETER Tag
  出力フォルダのサフィックス（省略時は日時）

.EXAMPLE
  .\Collect-EXOInventory.ps1 -OutRoot C:\temp\inventory

.NOTES
  必要モジュール: ExchangeOnlineManagement
#>
param(
  [string]$OutRoot = ".\inventory",
  [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss")
)

# 出力先フォルダ作成
$OutDir = Join-Path $OutRoot ("exo_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " Exchange Online 棚卸し"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -ShowBanner:$false

#----------------------------------------------------------------------
# 1. Organization Config（テナント設定）
#----------------------------------------------------------------------
Write-Host "[1/8] テナント設定を取得中..."
Get-OrganizationConfig | ConvertTo-Json -Depth 5 | 
  Out-File (Join-Path $OutDir "org_config.json") -Encoding UTF8

#----------------------------------------------------------------------
# 2. ★重要：Accepted Domains（承認済みドメイン）
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/8] ★ Accepted Domains を取得中..."
Write-Host "      → ドメインタイプ（Authoritative/InternalRelay）を確認"

$domains = Get-AcceptedDomain
$domains | Select-Object Name,DomainName,DomainType,Default,AddressBookEnabled |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "accepted_domains.csv")

Write-Host "      → ドメイン数: $($domains.Count)"

# タイプ別に表示
$authoritative = ($domains | Where-Object { $_.DomainType -eq 'Authoritative' }).Count
$internalRelay = ($domains | Where-Object { $_.DomainType -eq 'InternalRelay' }).Count
Write-Host "        - Authoritative: $authoritative"
Write-Host "        - InternalRelay: $internalRelay"

#----------------------------------------------------------------------
# 3. ★重要：Inbound Connectors（受信コネクタ）
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/8] ★ Inbound Connectors を取得中..."
Write-Host "      → 外部からEXOへの受信経路を確認"

$inbound = Get-InboundConnector
$inbound | Select-Object Name,Enabled,ConnectorType,
  @{n="送信元ドメイン";e={$_.SenderDomains -join ";"}},
  @{n="送信元IP";e={$_.SenderIPAddresses -join ";"}},
  TlsSenderCertificateName,RestrictDomainsToIPAddresses,
  RequireTls,CloudServicesMailEnabled |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "inbound_connectors.csv")

Write-Host "      → Inbound Connectors: $($inbound.Count)"

#----------------------------------------------------------------------
# 4. ★重要：Outbound Connectors（送信コネクタ）
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/8] ★ Outbound Connectors を取得中..."
Write-Host "      → EXOから外部への送信経路を確認"

$outbound = Get-OutboundConnector
$outbound | Select-Object Name,Enabled,ConnectorType,
  @{n="宛先ドメイン";e={$_.RecipientDomains -join ";"}},
  @{n="スマートホスト";e={$_.SmartHosts -join ";"}},
  UseMXRecord,TlsSettings,TlsDomain,CloudServicesMailEnabled |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "outbound_connectors.csv")

Write-Host "      → Outbound Connectors: $($outbound.Count)"

#----------------------------------------------------------------------
# 5. ★重要：Recipients（全受信者）
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[5/8] ★ 全受信者を取得中..."
Write-Host "      → 紛れ検出（Detect-StrayRecipients）の入力になります"
Write-Host "      → 大規模テナントでは時間がかかります"

$recipients = Get-Recipient -ResultSize Unlimited
$recipients | ForEach-Object {
  [PSCustomObject]@{
    表示名 = $_.DisplayName
    受信者タイプ = $_.RecipientType
    受信者タイプ詳細 = $_.RecipientTypeDetails
    プライマリSMTP = $_.PrimarySmtpAddress
    外部メールアドレス = $_.ExternalEmailAddress
    Identity = $_.Identity
    EmailAddresses = ($_.EmailAddresses -join ";")
  }
} | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "recipients.csv")

Write-Host "      → 受信者数: $($recipients.Count)"

#----------------------------------------------------------------------
# 6. Mailboxes（メールボックス詳細）
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[6/8] メールボックス詳細を取得中..."

$mailboxes = Get-Mailbox -ResultSize Unlimited
$mailboxes | Select-Object DisplayName,PrimarySmtpAddress,
  WhenCreated,IsDirSynced,RecipientTypeDetails,ExchangeGuid,
  @{n="EmailAddresses";e={$_.EmailAddresses -join ";"}} |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "mailboxes.csv")

Write-Host "      → メールボックス数: $($mailboxes.Count)"

# 同期状態を表示
$dirSynced = ($mailboxes | Where-Object { $_.IsDirSynced -eq $true }).Count
$cloudCreated = ($mailboxes | Where-Object { $_.IsDirSynced -ne $true }).Count
Write-Host "        - DirSync同期: $dirSynced"
Write-Host "        - クラウド作成: $cloudCreated"

#----------------------------------------------------------------------
# 7. Transport Rules（メールフロールール）
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[7/8] Transport Rules を取得中..."

$rules = Get-TransportRule
$rules | Select-Object Name,State,Priority,Mode,
  @{n="条件";e={$_.Conditions -join ";"}},
  @{n="アクション";e={$_.Actions -join ";"}} |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "transport_rules.csv")

Write-Host "      → Transport Rules: $($rules.Count)"

#----------------------------------------------------------------------
# 8. Remote Domains（リモートドメイン設定）
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[8/8] Remote Domains を取得中..."

$remoteDomains = Get-RemoteDomain
$remoteDomains | Select-Object Name,DomainName,
  AllowedOOFType,AutoReplyEnabled,AutoForwardEnabled,
  DeliveryReportEnabled,NDREnabled,TNEFEnabled |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "remote_domains.csv")

Write-Host "      → Remote Domains: $($remoteDomains.Count)"

#----------------------------------------------------------------------
# サマリー作成
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# Exchange Online 棚卸しサマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

【Accepted Domains】
  総数:          $($domains.Count)
  Authoritative: $authoritative （EXOで最終配送）
  InternalRelay: $internalRelay （オンプレへ転送）

【Connectors】
  Inbound:  $($inbound.Count)
  Outbound: $($outbound.Count)

【受信者】
  総数:           $($recipients.Count)
  メールボックス: $($mailboxes.Count)
    - DirSync同期:  $dirSynced
    - クラウド作成: $cloudCreated

【Transport Rules】 $($rules.Count)
【Remote Domains】  $($remoteDomains.Count)

#-------------------------------------------------------------------------------
# 確認すべきファイル
#-------------------------------------------------------------------------------

  ★ accepted_domains.csv
     → 40ドメインが登録されているか確認
     → DomainTypeが InternalRelay になっているか
       （移行前はAuthoritativeだと紛れメールボックスに配送される）

  ★ inbound_connectors.csv / outbound_connectors.csv
     → 既存のコネクタ設定を確認
     → 移行後に新しいコネクタを作成する際の参考

  ★ recipients.csv
     → 紛れ検出（Detect-StrayRecipients.ps1）の入力
     → ADにないのにEXOにいる受信者がいないか確認

  ★ mailboxes.csv
     → IsDirSynced列でAD同期状態を確認
     → クラウド作成のメールボックスは要注意（紛れの可能性）

#-------------------------------------------------------------------------------
# 注意事項
#-------------------------------------------------------------------------------

  【Internal Relayについて】
  移行期間中は対象ドメインを InternalRelay に設定する必要があります。
  これにより、EXOで宛先が見つからないメールはオンプレへ転送されます。

  Authoritative のままだと、ADから同期されていないアドレス宛のメールは
  NDR（配信不能）になります。

"@

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

Disconnect-ExchangeOnline -Confirm:$false
Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"
