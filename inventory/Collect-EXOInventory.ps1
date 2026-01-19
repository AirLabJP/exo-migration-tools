<#
.SYNOPSIS
  Exchange Online 棚卸しスクリプト

.DESCRIPTION
  Exchange Onlineの受信者・コネクタ・ドメイン・セキュリティポリシー・権限情報を収集し、
  EXO移行計画に必要な情報を取得します。

  【収集する情報】
  - Accepted Domains（承認済みドメイン）
  - Inbound/Outbound Connectors
  - 受信者一覧（Mailbox/MailUser/Contact/Group）
  - Transport Rules（メールフロールール）
  - Remote Domains
  - EOP/Defender セキュリティポリシー（AntiPhish/Malware/Spam/SafeLinks/SafeAttachments）
  - CASMailbox（POP/IMAP/MAPI/ActiveSync設定）
  - Mailbox権限・SendAs権限
  - 転送設定・保持ポリシー
  - Transport設定（サイズ制限/TLS設定）

  【出力ファイルと確認ポイント】
  accepted_domains.csv        ← ★重要: ドメイン一覧とタイプ（Authoritative/InternalRelay）
  inbound_connectors.csv      ← ★重要: 外部からの受信コネクタ
  outbound_connectors.csv     ← ★重要: 外部への送信コネクタ
  recipients.csv              ← ★重要: 全受信者一覧（紛れ検出用）
  mailboxes.csv               ← メールボックス詳細（IsDirSynced含む）
  cas_mailbox_protocols.csv   ← ★重要: POP/IMAP/MAPI/ActiveSync有効状態
  mailbox_permissions.csv     ← メールボックス権限
  sendas_permissions.csv      ← SendAs権限
  mailbox_forwarding.csv      ← ★重要: 転送設定（外部転送検出）
  transport_config.json       ← ★重要: サイズ制限/TLS設定
  eop_antiphish.csv           ← EOP AntiPhishポリシー
  eop_malware.csv             ← EOP Malwareポリシー
  eop_spam.csv                ← EOP スパムフィルター
  defender_safelinks.csv      ← Defender SafeLinksポリシー
  defender_safeattach.csv     ← Defender SafeAttachmentsポリシー
  summary.txt                 ← 統計サマリー

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

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$OutDir = Join-Path $OutRoot ("exo_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# グローバル変数（finally句で参照）
$transcriptStarted = $false
$exoConnected = $false

try {
  # トランスクリプト開始
  Start-Transcript -Path (Join-Path $OutDir "run.log") -Force
  $transcriptStarted = $true

  Write-Host "============================================================"
  Write-Host " Exchange Online 棚卸し"
  Write-Host "============================================================"
  Write-Host "出力先: $OutDir"
  Write-Host ""

  Import-Module ExchangeOnlineManagement
  Connect-ExchangeOnline -ShowBanner:$false
  $exoConnected = $true

  #----------------------------------------------------------------------
  # 1. Organization Config（テナント設定）
  #----------------------------------------------------------------------
  Write-Host "[1/19] テナント設定を取得中..."
  $orgConfig = Get-OrganizationConfig
  $orgConfig | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "org_config.json") -Encoding UTF8

  #----------------------------------------------------------------------
  # 2. ★重要：Accepted Domains（承認済みドメイン）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[2/19] ★ Accepted Domains を取得中..."
  Write-Host "      → ドメインタイプ（Authoritative/InternalRelay）を確認"

  $domains = Get-AcceptedDomain
  $domains | Select-Object Name,DomainName,DomainType,Default,AddressBookEnabled |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "accepted_domains.csv")
  $domains | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "accepted_domains.json") -Encoding UTF8

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
  Write-Host "[3/19] ★ Inbound Connectors を取得中..."
  Write-Host "      → 外部からEXOへの受信経路を確認"

  $inbound = Get-InboundConnector
  $inbound | Select-Object Name,Enabled,ConnectorType,
    @{n="送信元ドメイン";e={$_.SenderDomains -join ";"}},
    @{n="送信元IP";e={$_.SenderIPAddresses -join ";"}},
    TlsSenderCertificateName,RestrictDomainsToIPAddresses,
    RequireTls,CloudServicesMailEnabled |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "inbound_connectors.csv")
  $inbound | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "inbound_connectors.json") -Encoding UTF8

  Write-Host "      → Inbound Connectors: $($inbound.Count)"

  #----------------------------------------------------------------------
  # 4. ★重要：Outbound Connectors（送信コネクタ）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[4/19] ★ Outbound Connectors を取得中..."
  Write-Host "      → EXOから外部への送信経路を確認"

  $outbound = Get-OutboundConnector
  $outbound | Select-Object Name,Enabled,ConnectorType,
    @{n="宛先ドメイン";e={$_.RecipientDomains -join ";"}},
    @{n="スマートホスト";e={$_.SmartHosts -join ";"}},
    UseMXRecord,TlsSettings,TlsDomain,CloudServicesMailEnabled |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "outbound_connectors.csv")
  $outbound | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "outbound_connectors.json") -Encoding UTF8

  Write-Host "      → Outbound Connectors: $($outbound.Count)"

  #----------------------------------------------------------------------
  # 5. ★重要：Recipients（全受信者）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[5/19] ★ 全受信者を取得中..."
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
  $recipients | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "recipients.json") -Encoding UTF8

  Write-Host "      → 受信者数: $($recipients.Count)"

  #----------------------------------------------------------------------
  # 6. Mailboxes（メールボックス詳細）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[6/19] メールボックス詳細を取得中..."

  $mailboxes = Get-Mailbox -ResultSize Unlimited
  $mailboxes | Select-Object DisplayName,PrimarySmtpAddress,
    WhenCreated,IsDirSynced,RecipientTypeDetails,ExchangeGuid,
    ForwardingSMTPAddress,ForwardingAddress,DeliverToMailboxAndForward,
    RetentionPolicy,
    @{n="EmailAddresses";e={$_.EmailAddresses -join ";"}} |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "mailboxes.csv")
  $mailboxes | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "mailboxes.json") -Encoding UTF8

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
  Write-Host "[7/19] Transport Rules を取得中..."

  $rules = Get-TransportRule
  $rules | Select-Object Name,State,Priority,Mode,
    @{n="条件";e={$_.Conditions -join ";"}},
    @{n="アクション";e={$_.Actions -join ";"}} |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "transport_rules.csv")
  $rules | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "transport_rules.json") -Encoding UTF8

  Write-Host "      → Transport Rules: $($rules.Count)"

  #----------------------------------------------------------------------
  # 8. Remote Domains（リモートドメイン設定）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[8/19] Remote Domains を取得中..."

  $remoteDomains = Get-RemoteDomain
  $remoteDomains | Select-Object Name,DomainName,
    AllowedOOFType,AutoReplyEnabled,AutoForwardEnabled,
    DeliveryReportEnabled,NDREnabled,TNEFEnabled |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "remote_domains.csv")
  $remoteDomains | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "remote_domains.json") -Encoding UTF8

  Write-Host "      → Remote Domains: $($remoteDomains.Count)"

  #----------------------------------------------------------------------
  # 9. ★新規：EOP AntiPhishポリシー
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[9/19] ★ EOP AntiPhishポリシーを取得中..."

  try {
    $antiPhish = Get-AntiPhishPolicy
    $antiPhish | Select-Object Name,IsDefault,Enabled,
      PhishThresholdLevel,EnableMailboxIntelligence,EnableMailboxIntelligenceProtection,
      EnableSpoofIntelligence,EnableUnauthenticatedSender,EnableViaTag |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_antiphish.csv")
    $antiPhish | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "eop_antiphish.json") -Encoding UTF8
    Write-Host "      → AntiPhishポリシー: $($antiPhish.Count)"
  } catch {
    Write-Warning "AntiPhishポリシーの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 10. ★新規：EOP Malwareフィルターポリシー
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[10/19] ★ EOP Malwareフィルターポリシーを取得中..."

  try {
    $malware = Get-MalwareFilterPolicy
    $malware | Select-Object Name,IsDefault,
      Action,EnableFileFilter,EnableInternalSenderAdminNotifications,
      EnableExternalSenderAdminNotifications,
      @{n="FileTypes";e={$_.FileTypes -join ";"}} |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_malware.csv")
    $malware | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "eop_malware.json") -Encoding UTF8
    Write-Host "      → Malwareポリシー: $($malware.Count)"
  } catch {
    Write-Warning "Malwareポリシーの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 11. ★新規：EOP ホステッドコンテンツフィルター（スパム）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[11/19] ★ EOP スパムフィルターポリシーを取得中..."

  try {
    $spam = Get-HostedContentFilterPolicy
    $spam | Select-Object Name,IsDefault,
      SpamAction,HighConfidenceSpamAction,PhishSpamAction,
      BulkThreshold,QuarantineRetentionPeriod,
      EnableEndUserSpamNotifications,EndUserSpamNotificationFrequency |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_spam.csv")
    $spam | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "eop_spam.json") -Encoding UTF8
    Write-Host "      → スパムポリシー: $($spam.Count)"
  } catch {
    Write-Warning "スパムポリシーの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 12. ★新規：Defender SafeLinksポリシー
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[12/19] ★ Defender SafeLinksポリシーを取得中..."

  try {
    $safeLinks = Get-SafeLinksPolicy -ErrorAction SilentlyContinue
    if ($safeLinks) {
      $safeLinks | Select-Object Name,IsEnabled,
        EnableSafeLinksForEmail,EnableSafeLinksForTeams,EnableSafeLinksForOffice,
        ScanUrls,DeliverMessageAfterScan,EnableForInternalSenders,
        TrackClicks,AllowClickThrough |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "defender_safelinks.csv")
      $safeLinks | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "defender_safelinks.json") -Encoding UTF8
      Write-Host "      → SafeLinksポリシー: $($safeLinks.Count)"
    } else {
      Write-Host "      → SafeLinksポリシー: なし（Defender未有効の可能性）"
    }
  } catch {
    Write-Warning "SafeLinksポリシーの取得に失敗（Defender未有効の可能性）: $_"
  }

  #----------------------------------------------------------------------
  # 13. ★新規：Defender SafeAttachmentsポリシー
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[13/19] ★ Defender SafeAttachmentsポリシーを取得中..."

  try {
    $safeAttach = Get-SafeAttachmentPolicy -ErrorAction SilentlyContinue
    if ($safeAttach) {
      $safeAttach | Select-Object Name,IsEnabled,
        Action,Redirect,RedirectAddress,
        Enable,ActionOnError |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "defender_safeattach.csv")
      $safeAttach | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "defender_safeattach.json") -Encoding UTF8
      Write-Host "      → SafeAttachmentsポリシー: $($safeAttach.Count)"
    } else {
      Write-Host "      → SafeAttachmentsポリシー: なし（Defender未有効の可能性）"
    }
  } catch {
    Write-Warning "SafeAttachmentsポリシーの取得に失敗（Defender未有効の可能性）: $_"
  }

  #----------------------------------------------------------------------
  # 14. ★新規：CASMailbox（POP/IMAP/MAPI/ActiveSync設定）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[14/19] ★ CASMailbox（プロトコル設定）を取得中..."
  Write-Host "      → POP/IMAP/MAPI/ActiveSyncの有効/無効状態を確認"

  $casMailboxes = Get-CASMailbox -ResultSize Unlimited
  $casMailboxes | Select-Object DisplayName,PrimarySmtpAddress,
    PopEnabled,ImapEnabled,MAPIEnabled,ActiveSyncEnabled,
    OWAEnabled,ECPEnabled,EwsEnabled |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "cas_mailbox_protocols.csv")
  $casMailboxes | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "cas_mailbox_protocols.json") -Encoding UTF8

  Write-Host "      → CASMailbox: $($casMailboxes.Count)"
  $popEnabled = ($casMailboxes | Where-Object { $_.PopEnabled }).Count
  $imapEnabled = ($casMailboxes | Where-Object { $_.ImapEnabled }).Count
  Write-Host "        - POP有効: $popEnabled"
  Write-Host "        - IMAP有効: $imapEnabled"

  #----------------------------------------------------------------------
  # 15. ★新規：Mailbox権限
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[15/19] ★ Mailbox権限を取得中..."
  Write-Host "      → 代理アクセス権限を確認（時間がかかる場合があります）"

  $mbxPermissions = @()
  foreach ($mbx in $mailboxes | Select-Object -First 1000) {  # 大規模環境では最初の1000件のみ
    try {
      $perms = Get-MailboxPermission -Identity $mbx.Identity | Where-Object { $_.User -notlike "NT AUTHORITY\*" -and $_.User -notlike "S-1-5-*" }
      foreach ($perm in $perms) {
        $mbxPermissions += [PSCustomObject]@{
          Mailbox = $mbx.PrimarySmtpAddress
          User = $perm.User
          AccessRights = ($perm.AccessRights -join ";")
          IsInherited = $perm.IsInherited
          Deny = $perm.Deny
        }
      }
    } catch {
      # 個別のメールボックスでエラーが出ても継続
    }
  }

  if ($mbxPermissions.Count -gt 0) {
    $mbxPermissions | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "mailbox_permissions.csv")
    $mbxPermissions | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "mailbox_permissions.json") -Encoding UTF8
  }
  Write-Host "      → Mailbox権限: $($mbxPermissions.Count) 件"

  #----------------------------------------------------------------------
  # 16. ★新規：SendAs権限
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[16/19] ★ SendAs権限を取得中..."

  $sendAsPermissions = @()
  foreach ($mbx in $mailboxes | Select-Object -First 1000) {  # 大規模環境では最初の1000件のみ
    try {
      $perms = Get-RecipientPermission -Identity $mbx.Identity | Where-Object { $_.Trustee -notlike "NT AUTHORITY\*" -and $_.Trustee -notlike "S-1-5-*" }
      foreach ($perm in $perms) {
        $sendAsPermissions += [PSCustomObject]@{
          Mailbox = $mbx.PrimarySmtpAddress
          Trustee = $perm.Trustee
          AccessRights = ($perm.AccessRights -join ";")
          IsInherited = $perm.IsInherited
        }
      }
    } catch {
      # 個別のメールボックスでエラーが出ても継続
    }
  }

  if ($sendAsPermissions.Count -gt 0) {
    $sendAsPermissions | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "sendas_permissions.csv")
    $sendAsPermissions | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "sendas_permissions.json") -Encoding UTF8
  }
  Write-Host "      → SendAs権限: $($sendAsPermissions.Count) 件"

  #----------------------------------------------------------------------
  # 17. ★新規：メールボックス転送設定
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[17/19] ★ メールボックス転送設定を取得中..."
  Write-Host "      → 外部転送を検出"

  $forwarding = $mailboxes | Where-Object { $_.ForwardingSMTPAddress -or $_.ForwardingAddress } |
    Select-Object DisplayName,PrimarySmtpAddress,
      ForwardingSMTPAddress,ForwardingAddress,DeliverToMailboxAndForward

  if ($forwarding.Count -gt 0) {
    $forwarding | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "mailbox_forwarding.csv")
    $forwarding | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "mailbox_forwarding.json") -Encoding UTF8
    Write-Host "      → 転送設定あり: $($forwarding.Count) 件（要確認）"
  } else {
    Write-Host "      → 転送設定あり: 0 件"
  }

  #----------------------------------------------------------------------
  # 18. ★新規：保持ポリシー
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[18/19] ★ 保持ポリシーを取得中..."

  try {
    $retentionPolicies = Get-RetentionPolicy
    $retentionPolicies | Select-Object Name,IsDefault,
      @{n="RetentionPolicyTagLinks";e={$_.RetentionPolicyTagLinks -join ";"}} |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "retention_policies.csv")
    $retentionPolicies | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "retention_policies.json") -Encoding UTF8
    Write-Host "      → 保持ポリシー: $($retentionPolicies.Count)"
  } catch {
    Write-Warning "保持ポリシーの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 19. ★新規：Transport設定（サイズ制限/TLS設定）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[19/19] ★ Transport設定（サイズ制限/TLS）を取得中..."

  $transportConfig = Get-TransportConfig
  $transportConfig | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "transport_config.json") -Encoding UTF8

  # 主要パラメータを抽出
  $transportSummary = [PSCustomObject]@{
    MaxSendSize = $transportConfig.MaxSendSize
    MaxReceiveSize = $transportConfig.MaxReceiveSize
    MaxRecipientEnvelopeLimit = $transportConfig.MaxRecipientEnvelopeLimit
    TLSSendDomainSecureList = ($transportConfig.TLSSendDomainSecureList -join ";")
    TLSReceiveDomainSecureList = ($transportConfig.TLSReceiveDomainSecureList -join ";")
    ExternalPostmasterAddress = $transportConfig.ExternalPostmasterAddress
  }
  $transportSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "transport_config.csv")

  Write-Host "      → MaxSendSize: $($transportConfig.MaxSendSize)"
  Write-Host "      → MaxReceiveSize: $($transportConfig.MaxReceiveSize)"

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

【セキュリティポリシー】
  AntiPhish:        $(if ($antiPhish) { $antiPhish.Count } else { "未取得" })
  Malware:          $(if ($malware) { $malware.Count } else { "未取得" })
  Spam:             $(if ($spam) { $spam.Count } else { "未取得" })
  SafeLinks:        $(if ($safeLinks) { $safeLinks.Count } else { "未有効" })
  SafeAttachments:  $(if ($safeAttach) { $safeAttach.Count } else { "未有効" })

【プロトコル設定】
  POP有効:  $popEnabled / $($casMailboxes.Count)
  IMAP有効: $imapEnabled / $($casMailboxes.Count)

【権限・転送】
  Mailbox権限:  $($mbxPermissions.Count) 件
  SendAs権限:   $($sendAsPermissions.Count) 件
  転送設定:     $(if ($forwarding) { $forwarding.Count } else { 0 }) 件

【サイズ制限】
  MaxSendSize:    $($transportConfig.MaxSendSize)
  MaxReceiveSize: $($transportConfig.MaxReceiveSize)

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

  ★ cas_mailbox_protocols.csv
     → POP/IMAP有効状態を確認
     → セキュリティポリシーで無効化を検討

  ★ mailbox_forwarding.csv
     → 外部転送設定を確認
     → データ漏洩リスクの可能性

  ★ transport_config.json / transport_config.csv
     → サイズ制限・TLS設定を確認
     → EXO: 送信35MB/受信36MB（オンプレと整合確認）

  ★ eop_*.csv / defender_*.csv
     → セキュリティポリシーの設定状況を確認

#-------------------------------------------------------------------------------
# 注意事項
#-------------------------------------------------------------------------------

  【Internal Relayについて】
  移行期間中は対象ドメインを InternalRelay に設定する必要があります。
  これにより、EXOで宛先が見つからないメールはオンプレへ転送されます。

  Authoritative のままだと、ADから同期されていないアドレス宛のメールは
  NDR（配信不能）になります。

  【セキュリティポリシー】
  SafeLinks/SafeAttachmentsが「未有効」の場合、Defender for Office 365
  ライセンスが割り当てられていない可能性があります。

"@

  $summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

  Write-Host ""
  Write-Host "============================================================"
  Write-Host " 完了"
  Write-Host "============================================================"
  Write-Host $summary

} catch {
  # エラー時の処理
  Write-Host ""
  Write-Host "============================================================" -ForegroundColor Red
  Write-Host " エラーが発生しました" -ForegroundColor Red
  Write-Host "============================================================" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host $_.ScriptStackTrace -ForegroundColor Red

  # エラー情報をファイルに保存
  $errorInfo = @"
エラー発生時刻: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
エラーメッセージ: $($_.Exception.Message)
スタックトレース:
$($_.ScriptStackTrace)
"@
  $errorInfo | Out-File (Join-Path $OutDir "error.log") -Encoding UTF8

  # エラーを再スロー
  throw
} finally {
  # 必ず実行される後片付け
  if ($exoConnected) {
    try {
      Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
      Write-Host "Exchange Online から切断しました"
    } catch {
      # 切断でエラーが出ても無視
    }
  }

  if ($transcriptStarted) {
    try {
      Stop-Transcript
    } catch {
      # トランスクリプト停止でエラーが出ても無視
    }
  }

  Write-Host ""
  Write-Host "出力先: $OutDir"
}
