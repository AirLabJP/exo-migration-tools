<#
.SYNOPSIS
  Exchange Online 棚卸しスクリプト（強化版）

.DESCRIPTION
  Exchange Onlineの受信者・コネクタ・ドメイン・セキュリティポリシー・権限情報を収集し、
  EXO移行計画に必要な情報を取得します。

  【収集する情報】
  - Accepted Domains（承認済みドメイン）
  - Inbound/Outbound Connectors
  - 受信者一覧（Mailbox/MailUser/Contact/Group）
  - 配布グループ・M365グループ（SendOnBehalf含む）
  - Transport Rules（メールフロールール）+ ルーティング/ヘッダ操作ルール検出
  - Transport Rule XML バックアップ
  - Remote Domains
  - EOP/Defender セキュリティポリシー + Rule（AntiPhish/Malware/Spam/SafeLinks/SafeAttachments）
  - HostedOutboundSpamFilterPolicy（AutoForwardingMode）
  - CASMailbox（POP/IMAP/MAPI/ActiveSync設定）
  - Get-PopSettings/Get-ImapSettings（サーバー側設定）
  - Mailbox権限・SendAs権限・SendOnBehalf
  - 転送設定・保持ポリシー
  - Transport設定（サイズ制限/TLS設定）
  - Mailbox個別サイズ制限
  - InboxRule外部転送サンプル

  【出力ファイルと確認ポイント】
  accepted_domains.csv             ← ★重要: ドメイン一覧とタイプ（Authoritative/InternalRelay）
  inbound_connectors.csv           ← ★重要: 外部からの受信コネクタ
  outbound_connectors.csv          ← ★重要: 外部への送信コネクタ
  recipients.csv                   ← ★重要: 全受信者一覧（紛れ検出用）
  mailboxes.csv                    ← メールボックス詳細（IsDirSynced含む）
  mailbox_limits.csv               ← ★重要: メールボックス個別サイズ制限
  distribution_groups.csv          ← ★重要: 配布グループ
  unified_groups.csv               ← ★重要: M365グループ
  cas_mailbox_protocols.csv        ← ★重要: POP/IMAP/MAPI/ActiveSync有効状態
  pop_settings.json                ← POP3サーバー設定
  imap_settings.json               ← IMAPサーバー設定
  mailbox_permissions.csv          ← メールボックス権限
  sendas_permissions.csv           ← SendAs権限
  sendonbehalf_permissions.csv     ← SendOnBehalf権限
  mailbox_forwarding.csv           ← ★重要: 転送設定（外部転送検出）
  inbox_rules_external_forward.csv ← ★重要: InboxRule外部転送サンプル
  transport_config.json            ← ★重要: サイズ制限/TLS設定
  transport_rules.csv              ← Transport Rules一覧
  transport_rules_routing.csv      ← ★重要: ルーティング/ヘッダ操作ルール
  transport_rules_backup.xml       ← Transport Rules XMLバックアップ
  eop_antiphish_policy.csv         ← EOP AntiPhishポリシー
  eop_antiphish_rule.csv           ← EOP AntiPhishルール
  eop_malware_policy.csv           ← EOP Malwareポリシー
  eop_malware_rule.csv             ← EOP Malwareルール
  eop_spam_policy.csv              ← EOP スパムフィルターポリシー
  eop_spam_rule.csv                ← EOP スパムフィルタールール
  eop_outbound_spam_policy.csv     ← ★重要: 送信スパム（AutoForwardingMode）
  defender_safelinks_policy.csv    ← Defender SafeLinksポリシー
  defender_safelinks_rule.csv      ← Defender SafeLinksルール
  defender_safeattach_policy.csv   ← Defender SafeAttachmentsポリシー
  defender_safeattach_rule.csv     ← Defender SafeAttachmentsルール
  summary.txt                      ← 統計サマリー

.PARAMETER OutRoot
  出力先ルートフォルダ

.PARAMETER Tag
  出力フォルダのサフィックス（省略時は日時）

.PARAMETER UseEXOv3
  EXOv3 REST APIコマンドレット（Get-EXO*）を優先使用

.PARAMETER InboxRuleSampleLimit
  InboxRule外部転送サンプル取得数（デフォルト: 100）

.EXAMPLE
  .\Collect-EXOInventory.ps1 -OutRoot C:\temp\inventory

.EXAMPLE
  .\Collect-EXOInventory.ps1 -UseEXOv3 -InboxRuleSampleLimit 200

.NOTES
  必要モジュール: ExchangeOnlineManagement
#>
param(
  [string]$OutRoot = ".\inventory",
  [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss"),
  [switch]$UseEXOv3,
  [int]$InboxRuleSampleLimit = 100
)

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$OutDir = Join-Path $OutRoot ("exo_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# グローバル変数（finally句で参照）
$transcriptStarted = $false
$exoConnected = $false
$mailboxes = $null
$distributionGroups = $null
$unifiedGroups = $null

try {
  # トランスクリプト開始
  Start-Transcript -Path (Join-Path $OutDir "run.log") -Force
  $transcriptStarted = $true

  Write-Host "============================================================"
  Write-Host " Exchange Online 棚卸し（強化版）"
  Write-Host "============================================================"
  Write-Host "出力先: $OutDir"
  if ($UseEXOv3) { Write-Host "モード: EXOv3 REST API優先" }
  Write-Host ""

  Import-Module ExchangeOnlineManagement -ErrorAction Stop
  Connect-ExchangeOnline -ShowBanner:$false
  $exoConnected = $true

  #----------------------------------------------------------------------
  # 1. Organization Config（テナント設定）
  #----------------------------------------------------------------------
  Write-Host "[1/28] テナント設定を取得中..."
  $orgConfig = Get-OrganizationConfig
  $orgConfig | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "org_config.json") -Encoding UTF8

  #----------------------------------------------------------------------
  # 2. ★重要：Accepted Domains（承認済みドメイン）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[2/28] ★ Accepted Domains を取得中..."
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
  Write-Host "[3/28] ★ Inbound Connectors を取得中..."
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
  Write-Host "[4/28] ★ Outbound Connectors を取得中..."
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
  Write-Host "[5/28] ★ 全受信者を取得中..."
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
  Write-Host "[6/28] メールボックス詳細を取得中..."

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
  # 7. Transport Rules（メールフロールール）+ ルーティング/ヘッダ操作ルール検出
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[7/28] Transport Rules を取得中..."

  $rules = Get-TransportRule
  $rules | Select-Object Name,State,Priority,Mode,
    @{n="条件";e={$_.Conditions -join ";"}},
    @{n="アクション";e={$_.Actions -join ";"}} |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "transport_rules.csv")
  $rules | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "transport_rules.json") -Encoding UTF8

  Write-Host "      → Transport Rules: $($rules.Count)"

  # ルーティング/ヘッダ操作ルールの検出
  Write-Host "      → ルーティング/ヘッダ操作ルールを検出中..."
  $routingHeaderRules = $rules | Where-Object {
    # ルーティング変更系
    $_.RedirectMessageTo -or
    $_.RouteMessageOutboundConnector -or
    $_.RouteMessageOutboundRequireTls -or
    # ヘッダ操作系
    $_.SetHeaderName -or
    $_.RemoveHeader -or
    $_.PrependSubject -or
    $_.ModifySubject -or
    # BCC追加系
    $_.BlindCopyTo
  }

  if ($routingHeaderRules -and $routingHeaderRules.Count -gt 0) {
    $routingHeaderRules | Select-Object Name,State,Priority,
      @{n="RedirectTo";e={$_.RedirectMessageTo -join ";"}},
      @{n="OutboundConnector";e={$_.RouteMessageOutboundConnector}},
      @{n="SetHeader";e={if ($_.SetHeaderName) { "$($_.SetHeaderName):$($_.SetHeaderValue)" } else { "" }}},
      @{n="RemoveHeader";e={$_.RemoveHeader}},
      @{n="PrependSubject";e={$_.PrependSubject}},
      @{n="BlindCopyTo";e={$_.BlindCopyTo -join ";"}} |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "transport_rules_routing.csv")
    Write-Host "      → ルーティング/ヘッダ操作ルール: $($routingHeaderRules.Count) 件 → transport_rules_routing.csv"
  } else {
    "# ルーティング/ヘッダ操作ルールはありません" | Out-File (Join-Path $OutDir "transport_rules_routing.csv") -Encoding UTF8
    Write-Host "      → ルーティング/ヘッダ操作ルール: なし"
  }

  # Transport Rules XMLバックアップ
  Write-Host "      → Transport Rules XMLバックアップを取得中..."
  try {
    $ruleCollection = Export-TransportRuleCollection
    if ($ruleCollection -and $ruleCollection.FileData) {
      [System.IO.File]::WriteAllBytes((Join-Path $OutDir "transport_rules_backup.xml"), $ruleCollection.FileData)
      Write-Host "      → Transport Rules XMLバックアップ: transport_rules_backup.xml"
    }
  } catch {
    Write-Warning "Transport Rules XMLバックアップの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 8. Remote Domains（リモートドメイン設定）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[8/28] Remote Domains を取得中..."

  $remoteDomains = Get-RemoteDomain
  $remoteDomains | Select-Object Name,DomainName,
    AllowedOOFType,AutoReplyEnabled,AutoForwardEnabled,
    DeliveryReportEnabled,NDREnabled,TNEFEnabled |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "remote_domains.csv")
  $remoteDomains | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "remote_domains.json") -Encoding UTF8

  Write-Host "      → Remote Domains: $($remoteDomains.Count)"

  #----------------------------------------------------------------------
  # 9. ★EOP AntiPhishポリシー + ルール
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[9/28] ★ EOP AntiPhishポリシーを取得中..."

  try {
    $antiPhish = Get-AntiPhishPolicy
    $antiPhish | Select-Object Name,IsDefault,Enabled,
      PhishThresholdLevel,EnableMailboxIntelligence,EnableMailboxIntelligenceProtection,
      EnableSpoofIntelligence,EnableUnauthenticatedSender,EnableViaTag |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_antiphish_policy.csv")
    $antiPhish | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "eop_antiphish_policy.json") -Encoding UTF8
    Write-Host "      → AntiPhishポリシー: $($antiPhish.Count)"

    # AntiPhishルール
    $antiPhishRules = Get-AntiPhishRule -ErrorAction SilentlyContinue
    if ($antiPhishRules) {
      $antiPhishRules | Select-Object Name,State,Priority,AntiPhishPolicy,
        @{n="SentTo";e={$_.SentTo -join ";"}},
        @{n="SentToMemberOf";e={$_.SentToMemberOf -join ";"}},
        @{n="RecipientDomainIs";e={$_.RecipientDomainIs -join ";"}} |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_antiphish_rule.csv")
      Write-Host "      → AntiPhishルール: $($antiPhishRules.Count)"
    }
  } catch {
    Write-Warning "AntiPhishポリシーの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 10. ★EOP Malwareフィルターポリシー + ルール
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[10/28] ★ EOP Malwareフィルターポリシーを取得中..."

  try {
    $malware = Get-MalwareFilterPolicy
    $malware | Select-Object Name,IsDefault,
      Action,EnableFileFilter,EnableInternalSenderAdminNotifications,
      EnableExternalSenderAdminNotifications,
      @{n="FileTypes";e={$_.FileTypes -join ";"}} |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_malware_policy.csv")
    $malware | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "eop_malware_policy.json") -Encoding UTF8
    Write-Host "      → Malwareポリシー: $($malware.Count)"

    # Malwareルール
    $malwareRules = Get-MalwareFilterRule -ErrorAction SilentlyContinue
    if ($malwareRules) {
      $malwareRules | Select-Object Name,State,Priority,MalwareFilterPolicy,
        @{n="SentTo";e={$_.SentTo -join ";"}},
        @{n="RecipientDomainIs";e={$_.RecipientDomainIs -join ";"}} |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_malware_rule.csv")
      Write-Host "      → Malwareルール: $($malwareRules.Count)"
    }
  } catch {
    Write-Warning "Malwareポリシーの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 11. ★EOP ホステッドコンテンツフィルター（スパム）ポリシー + ルール
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[11/28] ★ EOP スパムフィルターポリシーを取得中..."

  try {
    $spam = Get-HostedContentFilterPolicy
    $spam | Select-Object Name,IsDefault,
      SpamAction,HighConfidenceSpamAction,PhishSpamAction,
      BulkThreshold,QuarantineRetentionPeriod,
      EnableEndUserSpamNotifications,EndUserSpamNotificationFrequency |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_spam_policy.csv")
    $spam | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "eop_spam_policy.json") -Encoding UTF8
    Write-Host "      → スパムポリシー: $($spam.Count)"

    # スパムルール
    $spamRules = Get-HostedContentFilterRule -ErrorAction SilentlyContinue
    if ($spamRules) {
      $spamRules | Select-Object Name,State,Priority,HostedContentFilterPolicy,
        @{n="SentTo";e={$_.SentTo -join ";"}},
        @{n="RecipientDomainIs";e={$_.RecipientDomainIs -join ";"}} |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_spam_rule.csv")
      Write-Host "      → スパムルール: $($spamRules.Count)"
    }
  } catch {
    Write-Warning "スパムポリシーの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 12. ★HostedOutboundSpamFilterPolicy（AutoForwardingMode）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[12/28] ★ 送信スパムフィルターポリシー（AutoForwardingMode）を取得中..."

  try {
    $outboundSpam = Get-HostedOutboundSpamFilterPolicy
    $outboundSpam | Select-Object Name,IsDefault,
      AutoForwardingMode,
      RecipientLimitExternalPerHour,RecipientLimitInternalPerHour,RecipientLimitPerDay,
      ActionWhenThresholdReached |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "eop_outbound_spam_policy.csv")
    $outboundSpam | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "eop_outbound_spam_policy.json") -Encoding UTF8

    Write-Host "      → 送信スパムポリシー: $($outboundSpam.Count)"

    # AutoForwardingModeを表示
    foreach ($policy in $outboundSpam) {
      $afMode = if ($policy.AutoForwardingMode) { $policy.AutoForwardingMode } else { "N/A" }
      Write-Host "        - $($policy.Name): AutoForwardingMode = $afMode"
      if ($afMode -eq "Off") {
        Write-Host "          ★警告: 外部への自動転送がブロックされています" -ForegroundColor Yellow
      }
    }
  } catch {
    Write-Warning "送信スパムポリシーの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 13. ★Defender SafeLinksポリシー + ルール
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[13/28] ★ Defender SafeLinksポリシーを取得中..."

  try {
    $safeLinks = Get-SafeLinksPolicy -ErrorAction SilentlyContinue
    if ($safeLinks) {
      $safeLinks | Select-Object Name,IsEnabled,
        EnableSafeLinksForEmail,EnableSafeLinksForTeams,EnableSafeLinksForOffice,
        ScanUrls,DeliverMessageAfterScan,EnableForInternalSenders,
        TrackClicks,AllowClickThrough |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "defender_safelinks_policy.csv")
      $safeLinks | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "defender_safelinks_policy.json") -Encoding UTF8
      Write-Host "      → SafeLinksポリシー: $($safeLinks.Count)"

      # SafeLinksルール
      $safeLinksRules = Get-SafeLinksRule -ErrorAction SilentlyContinue
      if ($safeLinksRules) {
        $safeLinksRules | Select-Object Name,State,Priority,SafeLinksPolicy,
          @{n="SentTo";e={$_.SentTo -join ";"}},
          @{n="RecipientDomainIs";e={$_.RecipientDomainIs -join ";"}} |
          Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "defender_safelinks_rule.csv")
        Write-Host "      → SafeLinksルール: $($safeLinksRules.Count)"
      }
    } else {
      Write-Host "      → SafeLinksポリシー: なし（Defender未有効の可能性）"
    }
  } catch {
    Write-Warning "SafeLinksポリシーの取得に失敗（Defender未有効の可能性）: $_"
  }

  #----------------------------------------------------------------------
  # 14. ★Defender SafeAttachmentsポリシー + ルール
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[14/28] ★ Defender SafeAttachmentsポリシーを取得中..."

  try {
    $safeAttach = Get-SafeAttachmentPolicy -ErrorAction SilentlyContinue
    if ($safeAttach) {
      $safeAttach | Select-Object Name,IsEnabled,
        Action,Redirect,RedirectAddress,
        Enable,ActionOnError |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "defender_safeattach_policy.csv")
      $safeAttach | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "defender_safeattach_policy.json") -Encoding UTF8
      Write-Host "      → SafeAttachmentsポリシー: $($safeAttach.Count)"

      # SafeAttachmentsルール
      $safeAttachRules = Get-SafeAttachmentRule -ErrorAction SilentlyContinue
      if ($safeAttachRules) {
        $safeAttachRules | Select-Object Name,State,Priority,SafeAttachmentPolicy,
          @{n="SentTo";e={$_.SentTo -join ";"}},
          @{n="RecipientDomainIs";e={$_.RecipientDomainIs -join ";"}} |
          Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "defender_safeattach_rule.csv")
        Write-Host "      → SafeAttachmentsルール: $($safeAttachRules.Count)"
      }
    } else {
      Write-Host "      → SafeAttachmentsポリシー: なし（Defender未有効の可能性）"
    }
  } catch {
    Write-Warning "SafeAttachmentsポリシーの取得に失敗（Defender未有効の可能性）: $_"
  }

  #----------------------------------------------------------------------
  # 15. ★CASMailbox（POP/IMAP/MAPI/ActiveSync設定）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[15/28] ★ CASMailbox（プロトコル設定）を取得中..."
  Write-Host "      → POP/IMAP/MAPI/ActiveSyncの有効/無効状態を確認"

  if ($UseEXOv3) {
    # EXOv3: Get-EXOCASMailbox（より高速）
    $casMailboxes = Get-EXOCASMailbox -ResultSize Unlimited -PropertySets All -ErrorAction SilentlyContinue
    if (-not $casMailboxes) {
      $casMailboxes = Get-CASMailbox -ResultSize Unlimited
    }
  } else {
    $casMailboxes = Get-CASMailbox -ResultSize Unlimited
  }

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
  # 16. Get-PopSettings / Get-ImapSettings（サーバー側設定）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[16/28] POP/IMAPサーバー設定を取得中..."

  try {
    $popSettings = Get-PopSettings -ErrorAction SilentlyContinue
    if ($popSettings) {
      $popSettings | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "pop_settings.json") -Encoding UTF8
      Write-Host "      → POP設定: pop_settings.json"
    }
  } catch {
    Write-Warning "POP設定の取得に失敗: $_"
  }

  try {
    $imapSettings = Get-ImapSettings -ErrorAction SilentlyContinue
    if ($imapSettings) {
      $imapSettings | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "imap_settings.json") -Encoding UTF8
      Write-Host "      → IMAP設定: imap_settings.json"
    }
  } catch {
    Write-Warning "IMAP設定の取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 17. ★配布グループの取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[17/28] ★ 配布グループを取得中..."

  try {
    $distributionGroups = Get-DistributionGroup -ResultSize Unlimited
    $distributionGroups | Select-Object DisplayName,PrimarySmtpAddress,
      GroupType,ManagedBy,
      @{n="Members";e={$_.Members -join ";"}},
      @{n="AcceptMessagesOnlyFrom";e={$_.AcceptMessagesOnlyFrom -join ";"}},
      @{n="GrantSendOnBehalfTo";e={$_.GrantSendOnBehalfTo -join ";"}},
      HiddenFromAddressListsEnabled,IsDirSynced |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "distribution_groups.csv")
    $distributionGroups | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "distribution_groups.json") -Encoding UTF8

    Write-Host "      → 配布グループ: $($distributionGroups.Count)"
  } catch {
    Write-Warning "配布グループの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 18. ★M365グループ（Unified Groups）の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[18/28] ★ M365グループ（Unified Groups）を取得中..."

  try {
    $unifiedGroups = Get-UnifiedGroup -ResultSize Unlimited -ErrorAction SilentlyContinue
    if ($unifiedGroups) {
      $unifiedGroups | Select-Object DisplayName,PrimarySmtpAddress,
        AccessType,
        @{n="Owners";e={$_.ManagedBy -join ";"}},
        @{n="GrantSendOnBehalfTo";e={$_.GrantSendOnBehalfTo -join ";"}},
        HiddenFromAddressListsEnabled,
        WelcomeMessageEnabled,AutoSubscribeNewMembers |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "unified_groups.csv")
      $unifiedGroups | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "unified_groups.json") -Encoding UTF8

      Write-Host "      → M365グループ: $($unifiedGroups.Count)"
    } else {
      Write-Host "      → M365グループ: なし"
    }
  } catch {
    Write-Warning "M365グループの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 19. ★Mailbox権限
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[19/28] ★ Mailbox権限を取得中..."
  Write-Host "      → 代理アクセス権限を確認（時間がかかる場合があります）"

  $mbxPermissions = @()
  foreach ($mbx in $mailboxes | Select-Object -First 1000) {  # 大規模環境では最初の1000件のみ
    try {
      if ($UseEXOv3) {
        $perms = Get-EXOMailboxPermission -Identity $mbx.Identity -ErrorAction SilentlyContinue |
          Where-Object { $_.User -notlike "NT AUTHORITY\*" -and $_.User -notlike "S-1-5-*" }
      } else {
        $perms = Get-MailboxPermission -Identity $mbx.Identity |
          Where-Object { $_.User -notlike "NT AUTHORITY\*" -and $_.User -notlike "S-1-5-*" }
      }
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
  # 20. ★SendAs権限
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[20/28] ★ SendAs権限を取得中..."

  $sendAsPermissions = @()
  foreach ($mbx in $mailboxes | Select-Object -First 1000) {  # 大規模環境では最初の1000件のみ
    try {
      if ($UseEXOv3) {
        $perms = Get-EXORecipientPermission -Identity $mbx.Identity -ErrorAction SilentlyContinue |
          Where-Object { $_.Trustee -notlike "NT AUTHORITY\*" -and $_.Trustee -notlike "S-1-5-*" }
      } else {
        $perms = Get-RecipientPermission -Identity $mbx.Identity |
          Where-Object { $_.Trustee -notlike "NT AUTHORITY\*" -and $_.Trustee -notlike "S-1-5-*" }
      }
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
  # 21. ★SendOnBehalf権限
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[21/28] ★ SendOnBehalf権限を取得中..."

  $sendOnBehalfPermissions = @()
  foreach ($mbx in $mailboxes | Where-Object { $_.GrantSendOnBehalfTo }) {
    foreach ($delegate in $mbx.GrantSendOnBehalfTo) {
      $sendOnBehalfPermissions += [PSCustomObject]@{
        Mailbox = $mbx.PrimarySmtpAddress
        Delegate = $delegate
      }
    }
  }

  if ($sendOnBehalfPermissions.Count -gt 0) {
    $sendOnBehalfPermissions | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "sendonbehalf_permissions.csv")
    Write-Host "      → SendOnBehalf権限: $($sendOnBehalfPermissions.Count) 件"
  } else {
    "# SendOnBehalf権限はありません" | Out-File (Join-Path $OutDir "sendonbehalf_permissions.csv") -Encoding UTF8
    Write-Host "      → SendOnBehalf権限: なし"
  }

  #----------------------------------------------------------------------
  # 22. ★メールボックス転送設定
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[22/28] ★ メールボックス転送設定を取得中..."
  Write-Host "      → 外部転送を検出"

  $forwarding = $mailboxes | Where-Object { $_.ForwardingSMTPAddress -or $_.ForwardingAddress } |
    Select-Object DisplayName,PrimarySmtpAddress,
      ForwardingSMTPAddress,ForwardingAddress,DeliverToMailboxAndForward

  if ($forwarding.Count -gt 0) {
    $forwarding | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "mailbox_forwarding.csv")
    $forwarding | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "mailbox_forwarding.json") -Encoding UTF8
    Write-Host "      → 転送設定あり: $($forwarding.Count) 件（要確認）"
  } else {
    "# 転送設定はありません" | Out-File (Join-Path $OutDir "mailbox_forwarding.csv") -Encoding UTF8
    Write-Host "      → 転送設定あり: 0 件"
  }

  #----------------------------------------------------------------------
  # 23. ★InboxRule外部転送サンプル
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[23/28] ★ InboxRule外部転送サンプルを取得中（最大 $InboxRuleSampleLimit 件）..."

  $inboxRulesExternal = @()
  $sampleCount = 0

  foreach ($mbx in $mailboxes | Select-Object -First $InboxRuleSampleLimit) {
    try {
      $rules = Get-InboxRule -Mailbox $mbx.Identity -ErrorAction SilentlyContinue
      if ($rules) {
        foreach ($rule in $rules) {
          # 外部転送を検出（ForwardTo/ForwardAsAttachmentTo/RedirectTo）
          $hasExternalForward = $false
          $forwardTargets = @()

          if ($rule.ForwardTo) {
            $forwardTargets += $rule.ForwardTo
            # 外部ドメインへの転送かチェック（簡易判定）
            foreach ($target in $rule.ForwardTo) {
              if ($target -match '@' -and $target -notmatch '\.onmicrosoft\.com') {
                $hasExternalForward = $true
              }
            }
          }
          if ($rule.ForwardAsAttachmentTo) {
            $forwardTargets += $rule.ForwardAsAttachmentTo
            foreach ($target in $rule.ForwardAsAttachmentTo) {
              if ($target -match '@' -and $target -notmatch '\.onmicrosoft\.com') {
                $hasExternalForward = $true
              }
            }
          }
          if ($rule.RedirectTo) {
            $forwardTargets += $rule.RedirectTo
            foreach ($target in $rule.RedirectTo) {
              if ($target -match '@' -and $target -notmatch '\.onmicrosoft\.com') {
                $hasExternalForward = $true
              }
            }
          }

          if ($forwardTargets.Count -gt 0) {
            $inboxRulesExternal += [PSCustomObject]@{
              Mailbox = $mbx.PrimarySmtpAddress
              RuleName = $rule.Name
              Enabled = $rule.Enabled
              ForwardTo = ($rule.ForwardTo -join ";")
              ForwardAsAttachmentTo = ($rule.ForwardAsAttachmentTo -join ";")
              RedirectTo = ($rule.RedirectTo -join ";")
              IsExternalForward = $hasExternalForward
            }
          }
        }
      }
      $sampleCount++
    } catch {
      # 個別のメールボックスでエラーが出ても継続
    }
  }

  if ($inboxRulesExternal.Count -gt 0) {
    $inboxRulesExternal | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "inbox_rules_external_forward.csv")
    Write-Host "      → InboxRule転送ルール: $($inboxRulesExternal.Count) 件（サンプル $sampleCount 件から）"

    $externalCount = ($inboxRulesExternal | Where-Object { $_.IsExternalForward }).Count
    if ($externalCount -gt 0) {
      Write-Host "      → ★警告: 外部転送ルール: $externalCount 件" -ForegroundColor Yellow
    }
  } else {
    "# InboxRule転送ルールはありません" | Out-File (Join-Path $OutDir "inbox_rules_external_forward.csv") -Encoding UTF8
    Write-Host "      → InboxRule転送ルール: なし"
  }

  #----------------------------------------------------------------------
  # 24. ★保持ポリシー
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[24/28] ★ 保持ポリシーを取得中..."

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
  # 25. ★Transport設定（サイズ制限/TLS設定）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[25/28] ★ Transport設定（サイズ制限/TLS）を取得中..."

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
  # 26. ★Mailbox個別サイズ制限
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[26/28] ★ Mailbox個別サイズ制限を取得中..."

  $mailboxLimits = $mailboxes | Select-Object DisplayName,PrimarySmtpAddress,
    MaxSendSize,MaxReceiveSize,
    @{n="RecipientLimits";e={$_.RecipientLimits}},
    ProhibitSendQuota,ProhibitSendReceiveQuota,IssueWarningQuota

  $mailboxLimits | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "mailbox_limits.csv")

  # カスタム制限を持つメールボックスを検出
  $customLimits = $mailboxes | Where-Object {
    $_.MaxSendSize -ne "Unlimited" -or
    $_.MaxReceiveSize -ne "Unlimited" -or
    $_.RecipientLimits -ne "Unlimited"
  }

  if ($customLimits.Count -gt 0) {
    Write-Host "      → カスタム制限あり: $($customLimits.Count) 件"
  } else {
    Write-Host "      → カスタム制限あり: なし（全て既定値）"
  }

  #----------------------------------------------------------------------
  # 27-28. サマリー作成
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[27/28] サマリーを作成中..."

  # InboxRule外部転送数を集計
  $inboxRulesExternalCount = if ($inboxRulesExternal) { ($inboxRulesExternal | Where-Object { $_.IsExternalForward }).Count } else { 0 }

  $summary = @"
#===============================================================================
# Exchange Online 棚卸しサマリー（強化版）
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
  総数:             $($recipients.Count)
  メールボックス:   $($mailboxes.Count)
    - DirSync同期:    $dirSynced
    - クラウド作成:   $cloudCreated
  配布グループ:     $(if ($distributionGroups) { $distributionGroups.Count } else { "未取得" })
  M365グループ:     $(if ($unifiedGroups) { $unifiedGroups.Count } else { "未取得" })

【Transport Rules】 $($rules.Count)
  - ルーティング/ヘッダ操作: $(if ($routingHeaderRules) { $routingHeaderRules.Count } else { 0 }) 件
【Remote Domains】  $($remoteDomains.Count)

【セキュリティポリシー】
  AntiPhishポリシー:      $(if ($antiPhish) { $antiPhish.Count } else { "未取得" })
  Malwareポリシー:        $(if ($malware) { $malware.Count } else { "未取得" })
  Spamポリシー:           $(if ($spam) { $spam.Count } else { "未取得" })
  送信Spamポリシー:       $(if ($outboundSpam) { $outboundSpam.Count } else { "未取得" })
  SafeLinksポリシー:      $(if ($safeLinks) { $safeLinks.Count } else { "未有効" })
  SafeAttachmentsポリシー:$(if ($safeAttach) { $safeAttach.Count } else { "未有効" })

【AutoForwardingMode】
$(if ($outboundSpam) {
  ($outboundSpam | ForEach-Object { "  $($_.Name): $($_.AutoForwardingMode)" }) -join "`n"
} else {
  "  未取得"
})

【プロトコル設定】
  POP有効:  $popEnabled / $($casMailboxes.Count)
  IMAP有効: $imapEnabled / $($casMailboxes.Count)

【権限・転送】
  Mailbox権限:      $($mbxPermissions.Count) 件
  SendAs権限:       $($sendAsPermissions.Count) 件
  SendOnBehalf権限: $($sendOnBehalfPermissions.Count) 件
  転送設定:         $(if ($forwarding) { $forwarding.Count } else { 0 }) 件
  InboxRule外部転送: $inboxRulesExternalCount 件

【サイズ制限】
  MaxSendSize:    $($transportConfig.MaxSendSize)
  MaxReceiveSize: $($transportConfig.MaxReceiveSize)
  カスタム制限:   $(if ($customLimits) { $customLimits.Count } else { 0 }) 件

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

  ★ mailbox_limits.csv
     → メールボックス個別のサイズ制限
     → MaxSendSize/MaxReceiveSize/RecipientLimits

  ★ distribution_groups.csv / unified_groups.csv
     → 配布グループとM365グループ
     → GrantSendOnBehalfToを確認

  ★ cas_mailbox_protocols.csv
     → POP/IMAP有効状態を確認
     → セキュリティポリシーで無効化を検討

  ★ mailbox_forwarding.csv
     → 外部転送設定を確認
     → データ漏洩リスクの可能性

  ★ inbox_rules_external_forward.csv
     → InboxRuleによる外部転送
     → IsExternalForward=Trueのものは要確認

  ★ transport_rules_routing.csv
     → ルーティング/ヘッダ操作を行うトランスポートルール
     → リダイレクト、ヘッダ変更などを確認

  ★ transport_rules_backup.xml
     → トランスポートルールのXMLバックアップ
     → Import-TransportRuleCollectionで復元可能

  ★ transport_config.json / transport_config.csv
     → サイズ制限・TLS設定を確認
     → EXO: 送信35MB/受信36MB（オンプレと整合確認）

  ★ eop_outbound_spam_policy.csv
     → 送信スパムポリシー
     → AutoForwardingMode を確認（Off=外部転送ブロック）

  ★ eop_*_policy.csv / eop_*_rule.csv
     → EOPポリシーとルールの対応を確認

  ★ defender_*_policy.csv / defender_*_rule.csv
     → Defenderポリシーとルールの対応を確認

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

  【AutoForwardingMode】
  - Automatic: 外部転送を自動判定（一部ブロック）
  - Off: 外部への自動転送を完全ブロック
  - On: 外部への自動転送を許可

  【EXOv3オプション】
  -UseEXOv3 を指定すると、Get-EXO* コマンドレット（REST API）を優先使用します。
  大規模環境ではパフォーマンスが向上する場合があります。

"@

  $summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

  Write-Host ""
  Write-Host "[28/28] 完了"
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
