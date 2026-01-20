# Exchange Online Migration Tools

Linux（Postfix/Courier IMAP）ベースのメールシステムからExchange Onlineへの移行に必要なスクリプト群。

## ドキュメント

| ドキュメント | 内容 |
|-------------|------|
| [permissions.md](docs/permissions.md) | 各スクリプトに必要な権限一覧 |
| [rollback_limits.md](docs/rollback_limits.md) | 切り戻しの限界（戻せるもの・戻せないもの） |
| [要件定義書（案）](docs/ExchangeOnline移行プロジェクト要件定義書（案）.md) | プロジェクト要件 |
| [基本設計書（案）](docs/ExchangeOnline移行プロジェクト基本設計書（案）.md) | システム設計 |
| [実践ガイド](docs/ExchangeOnline移行プロジェクト実践ガイド.md) | 移行戦略・メールフロー設計 |
| [Outlook設定手順書](docs/ユーザー向けOutlook設定手順書.md) | ユーザー向けOutlook設定ガイド |
| [過去メール移行手順書](docs/ユーザー向け過去メール移行手順書.md) | Thunderbird→Outlook移行ガイド |

## 想定環境

```
[外部]
   │
   ▼ MX
┌──────────────────────────────────────────────────────────────────────┐
│  AWS (DMZ)                                                           │
│  ┌─────────────────┐    ┌─────────────────┐                          │
│  │ FireEye         │───▶│ EC2: Postfix    │ ← 外部メール受口         │
│  │ (メールセキュリティ) │    │ (DMZ SMTP)      │                          │
│  └─────────────────┘    └────────┬────────┘                          │
└──────────────────────────────────┼───────────────────────────────────┘
                                   │
         ┌─────────────────────────┴─────────────────────────┐
         │                                                   │
         ▼ (移行対象ドメイン)                                ▼ (それ以外)
┌────────────────────┐                              ┌─────────────────┐
│ Exchange Online    │                              │ 内部ネットワーク │
│ ┌────────────────┐ │                              │ ┌─────────────┐ │
│ │ Mailbox        │ │                              │ │ Courier IMAP│ │
│ │ (移行済みユーザー)│ │                              │ │ (未移行ユーザー)│ │
│ └────────────────┘ │                              │ └─────────────┘ │
│        │           │                              └─────────────────┘
│        │ (未移行宛先)                                      ▲
│        ▼           │                                       │
│ Internal Relay ────┼───────────────────────────────────────┘
│ (Outbound Connector)│  フォールバック経路
└────────────────────┘

[内部ネットワーク]
┌──────────────────────────────────────────────────────────────────────┐
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐   │
│  │ Active Directory│    │ 管理端末        │    │ 内部DMZ SMTP    │   │
│  │ (オンプレ)      │    │ (PowerShell)    │    │ (フォールバック) │   │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

## フォルダ構成

```
exo-migration-tools/
├── inventory/                    # 棚卸しスクリプト
│   ├── collect_postfix.sh
│   ├── collect_courier_imap.sh
│   ├── collect_smtp_dmz.sh
│   ├── Collect-ADInventory.ps1
│   ├── Collect-EntraInventory.ps1
│   ├── Collect-EXOInventory.ps1
│   ├── Collect-DNSRecords.ps1
│   └── Export-EXOConfigSnapshot.ps1  # EXO設定スナップショット
│
├── analysis/                     # 分析・検証スクリプト
│   ├── Detect-StrayRecipients.ps1
│   ├── Test-SmtpDuplicates.ps1
│   ├── Plan-RecipientRemediation.ps1  # 紛れ対処計画
│   └── Invoke-RecipientRemediation.ps1 # 紛れ対処実行 ★NEW
│
├── execution/                    # 実行スクリプト（フェーズ別）
│   ├── phase1-preparation/       # Phase1: 事前準備
│   │   ├── Test-Prerequisites.ps1       # 前提条件チェック
│   │   └── Invoke-ExchangeSchemaPrep.ps1 # ADスキーマ拡張
│   │
│   ├── phase2-setup/             # Phase2: EXO箱作り
│   │   ├── New-ADUsersFromCsv.ps1         # ADユーザー作成（CSVベース）
│   │   ├── New-EntraUsersFromCsv.ps1      # Entra IDユーザー作成（CSVベース）
│   │   ├── Set-ADMailAddressesFromCsv.ps1 # ADメール属性投入
│   │   ├── New-EXOConnectors.ps1          # EXOコネクタ作成
│   │   ├── New-EXOTransportRules.ps1      # Transport Rule作成 ★NEW
│   │   └── Add-UsersToLicenseGroup.ps1    # ライセンスグループへのユーザー追加
│
├── templates/                    # CSVテンプレート
│   ├── README.md
│   ├── sample_users_ad.csv       # ADユーザー作成用CSV
│   └── sample_users_entra.csv    # Entra IDユーザー作成用CSV
│   │
│   ├── phase3-routing/           # Phase3: ルーティング変更
│   │   ├── Set-PostfixRouting.sh        # Postfix transport変更
│   │   ├── Set-DmzSmtpRouting.sh        # DMZ SMTP transport変更
│   │   ├── Set-AcceptedDomainType.ps1   # EXO Accepted Domain変更
│   │   └── New-TestMailboxes.ps1        # テスト用メールボックス作成
│   │
│   ├── phase4-validation/        # Phase4: 検証 ★新規
│   │   └── Test-MailFlowMatrix.ps1      # メールフロー検証
│   │
│   └── rollback/                 # 切り戻し ★新規
│       ├── Undo-EXOConnectors.ps1       # コネクタ削除
│       ├── Restore-AcceptedDomainType.ps1 # Accepted Domain復元
│       ├── Restore-PostfixRouting.sh    # Postfix復元
│       └── Restore-DmzSmtpRouting.sh    # DMZ SMTP復元
│
├── lab-env/                      # 検証環境構築
│   ├── Setup-LabEnvironment.ps1
│   ├── Setup-ADDSReplication.ps1
│   ├── Setup-DC02DomainJoin.ps1
│   ├── Setup-EntraIDConnect.ps1
│   ├── Send-TestEmail.ps1
│   ├── Test-MailHeader.ps1
│   └── docker-compose.yml
│
├── test-env/                     # スクリプトテスト環境
│   └── docker-compose.yml
│
├── config/                       # 環境設定ファイル ★NEW
│   ├── README.md
│   └── sample_environment.yaml   # 設定ファイルテンプレート
│
└── docs/                         # ドキュメント
    ├── permissions.md            # 必要な権限一覧 ★NEW
    ├── rollback_limits.md        # 切り戻しの限界 ★NEW
    ├── ExchangeOnline移行プロジェクト実践ガイド.md
    ├── ExchangeOnline移行プロジェクト要件定義書（案）.md
    ├── ExchangeOnline移行プロジェクト基本設計書（案）.md
    ├── ExchangeOnline移行プロジェクト_お客様ヒアリング事項（スライド用）.md
    ├── ユーザー向けOutlook設定手順書.md    # ★NEW
    └── ユーザー向け過去メール移行手順書.md  # ★NEW
```

## 設計方針

### 冪等性（再実行可能性）

各スクリプトは**再実行しても安全**に設計されています。

| スクリプト | 再実行時の挙動 |
|-----------|---------------|
| `New-ADUsersFromCsv.ps1` | 既存ユーザーはスキップ |
| `New-EntraUsersFromCsv.ps1` | 既存ユーザーはスキップ、グループ追加のみ実行 |
| `Set-ADMailAddressesFromCsv.ps1` | 既存値を上書き（WhatIfで事前確認推奨） |
| `Add-UsersToLicenseGroup.ps1` | 既存メンバーはスキップ |
| `New-EXOConnectors.ps1` | 既存コネクタがあればエラー（手動確認推奨） |
| `New-EXOTransportRules.ps1` | 既存ルールがあればスキップ |
| `Invoke-RecipientRemediation.ps1` | 対処計画CSVに従い実行（WhatIf推奨） |
| `Set-AcceptedDomainType.ps1` | 変更なしの場合はスキップ |
| Bash系（transport変更） | バックアップを取って上書き |

### WhatIfモード

破壊的操作を行うスクリプトは `-WhatIfMode` スイッチをサポートしています。
**本番実行前に必ず WhatIf で確認してください。**

```powershell
# WhatIfで確認（実際には変更しない）
.\script.ps1 -SomeParam "value" -WhatIfMode

# 本番実行
.\script.ps1 -SomeParam "value"
```

### 出力形式

すべてのスクリプトは以下の形式で出力します：

| 出力 | 形式 | 用途 |
|------|------|------|
| 実行ログ | `run.log` | トランスクリプト、デバッグ |
| 結果CSV | `results.csv` | Excel等で確認 |
| 結果JSON | `*.json` | 機械処理、差分比較 |
| サマリー | `summary.txt` | 簡易レポート |

## 使用順序

### Phase 1: 棚卸し＆事前準備

#### 1-1. 前提条件チェック（全体）

```powershell
# ADスキーマ拡張前の権限チェック
.\execution\phase1-preparation\Test-Prerequisites.ps1 -CheckAD

# EXO/Graph接続チェック
.\execution\phase1-preparation\Test-Prerequisites.ps1 -CheckEXO -CheckGraph

# 全チェック
.\execution\phase1-preparation\Test-Prerequisites.ps1 -All
```

#### 1-2. 棚卸し（Linux環境）

```bash
# スクリプト配置（SCPで転送後）
chmod +x inventory/*.sh

# Postfix設定回収（メインSMTPサーバー）
sudo bash inventory/collect_postfix.sh /tmp/inventory

# Courier IMAP設定回収（メールボックスサーバー）
sudo bash inventory/collect_courier_imap.sh /tmp/inventory

# DMZ SMTP設定回収（AWS側・内部DMZ側それぞれ）
sudo bash inventory/collect_smtp_dmz.sh /tmp/inventory
```

#### 1-3. 棚卸し（Windows/PowerShell）

```powershell
# AD棚卸し
.\inventory\Collect-ADInventory.ps1 -OutRoot C:\temp\inventory

# Entra棚卸し
.\inventory\Collect-EntraInventory.ps1 -OutRoot C:\temp\inventory

# EXO棚卸し
.\inventory\Collect-EXOInventory.ps1 -OutRoot C:\temp\inventory

# DNS棚卸し
.\inventory\Collect-DNSRecords.ps1 -DomainsFile domains.txt -OutRoot C:\temp\inventory
```

#### 1-4. 分析（紛れ検出）

```powershell
# EXOの「紛れ」受信者検出
.\analysis\Detect-StrayRecipients.ps1 `
  -ExoRecipientsCsv C:\temp\inventory\exo_*\recipients.csv `
  -AdUsersCsv C:\temp\inventory\ad_*\ad_users_mailattrs.csv `
  -TargetDomainsFile domains.txt

# 紛れ対処計画を作成（検出結果をもとに）
.\analysis\Plan-RecipientRemediation.ps1 `
  -StrayReportPath C:\temp\stray_report\*\strays_action_required.csv `
  -AutoClassify

# 紛れ対処を実行（計画CSVを確認・承認後）
# WhatIfで確認
.\analysis\Invoke-RecipientRemediation.ps1 `
  -RemediationPlanPath C:\temp\remediation_plan\*\remediation_plan.csv `
  -WhatIfMode

# 本番実行
.\analysis\Invoke-RecipientRemediation.ps1 `
  -RemediationPlanPath C:\temp\remediation_plan\*\remediation_plan.csv
```

#### 1-5. EXO設定スナップショット

変更前の設定を保存しておきます。

```powershell
# 作業前スナップショット
.\inventory\Export-EXOConfigSnapshot.ps1 -SnapshotName "before_migration"

# 作業後スナップショット
.\inventory\Export-EXOConfigSnapshot.ps1 -SnapshotName "after_migration"
```

#### 1-6. ADスキーマ拡張

```powershell
# Schema Master DCで実行
.\execution\phase1-preparation\Invoke-ExchangeSchemaPrep.ps1 `
  -SetupExePath D:\ExchangeSetup\Setup.exe `
  -OrganizationName "Contoso"
```

### Phase 2: EXO箱作り

#### 2-0. ユーザー作成（検証環境または新規ユーザーの場合）

CSVテンプレートは `templates/` フォルダを参照。本番用・検証用で同じ形式で使い回せます。

```powershell
# パターンA: ADに作成 → Entra ID Connect同期
.\execution\phase2-setup\New-ADUsersFromCsv.ps1 `
  -CsvPath templates\sample_users_ad.csv `
  -TargetOU "OU=Users,DC=contoso,DC=local" `
  -SetMailAttributes

# パターンB: Entra IDに直接作成（クラウドオンリー）
# 既存ユーザーはスキップし、ライセンスグループに追加
.\execution\phase2-setup\New-EntraUsersFromCsv.ps1 `
  -CsvPath templates\sample_users_entra.csv `
  -LicenseGroupName "EXO-License-Pilot"
```

#### 2-1. SMTP重複チェック

```powershell
.\analysis\Test-SmtpDuplicates.ps1 `
  -CsvPath mail_addresses.csv `
  -AdUsersCsv C:\temp\inventory\ad_*\ad_users_mailattrs.csv
```

#### 2-2. ADメール属性投入

```powershell
# WhatIfで確認
.\execution\phase2-setup\Set-ADMailAddressesFromCsv.ps1 `
  -CsvPath mail_addresses.csv `
  -WhatIfMode

# 本番実行
.\execution\phase2-setup\Set-ADMailAddressesFromCsv.ps1 `
  -CsvPath mail_addresses.csv
```

#### 2-3. EXOコネクタ作成

```powershell
# WhatIfで確認
.\execution\phase2-setup\New-EXOConnectors.ps1 `
  -MailSecurityHost "mailsecurity.example.com" `  # 送信セキュリティ導入時のみ
  -OnPremDmzSmtpHost "dmz-smtp.internal.example.co.jp" `
  -AwsDmzSmtpIP "203.0.113.10" `
  -TargetDomainsFile domains.txt `
  -WhatIfMode

# 本番実行
.\execution\phase2-setup\New-EXOConnectors.ps1 `
  -MailSecurityHost "mailsecurity.example.com" `  # 送信セキュリティ導入時のみ
  -OnPremDmzSmtpHost "dmz-smtp.internal.example.co.jp" `
  -AwsDmzSmtpIP "203.0.113.10" `
  -TargetDomainsFile domains.txt
```

#### 2-4. EXO Transport Rule 作成

メールフロー制御に必要な Transport Rule を作成します。

```powershell
# WhatIfで確認
.\execution\phase2-setup\New-EXOTransportRules.ps1 `
  -TargetDomainsFile domains.txt `
  -WhatIfMode

# 本番実行
.\execution\phase2-setup\New-EXOTransportRules.ps1 `
  -TargetDomainsFile domains.txt
```

作成されるルール:
- **Block-ExternalForwarding**: 外部への自動転送をブロック
- **Add-LoopPreventionHeader**: ループ防止ヘッダを付与
- **Route-ExternalViaMailSecurity**: 外部宛を送信セキュリティサービス経由でルーティング（導入時）

#### 2-5. ライセンス付与用グループへのユーザー追加

移行中は**静的グループ**を使用し、CSVで指定したユーザーのみにライセンスを付与します。
動的グループは全ドメイン移行完了後に切り替えることで、意図しないメールボックス作成を防止します。

```powershell
# WhatIfで確認
.\execution\phase2-setup\Add-UsersToLicenseGroup.ps1 `
  -CsvPath migration_users.csv `
  -GroupName "EXO-License-Pilot" `
  -WhatIfMode

# 本番実行
.\execution\phase2-setup\Add-UsersToLicenseGroup.ps1 `
  -CsvPath migration_users.csv `
  -GroupName "EXO-License-Pilot"

# ユーザーを削除する場合
.\execution\phase2-setup\Add-UsersToLicenseGroup.ps1 `
  -CsvPath migration_users.csv `
  -GroupName "EXO-License-Pilot" `
  -RemoveMode
```

**注意**: グループベースライセンスはEntra ID Premium P1以上が必要です。

### Phase 3: ルーティング変更（★本番切替）

#### 3-0. テスト用メールボックス作成（テストドメイン検証用）

本番切替前にテストドメインでメールフローを検証するためのテストメールボックスを作成します。

```powershell
# WhatIfで確認
.\execution\phase3-routing\New-TestMailboxes.ps1 `
  -TestDomain "test.contoso.co.jp" `
  -Count 3 `
  -WhatIfMode

# 本番実行
.\execution\phase3-routing\New-TestMailboxes.ps1 `
  -TestDomain "test.contoso.co.jp" `
  -Count 3

# テスト完了後のクリーンアップ
# → 出力フォルダ内の cleanup_test_users.ps1 を実行
```

#### 3-1. EXO Accepted Domain を Internal Relay に変更

```powershell
# WhatIfで確認
.\execution\phase3-routing\Set-AcceptedDomainType.ps1 `
  -DomainsFile domains.txt `
  -DomainType InternalRelay `
  -WhatIfMode

# 本番実行
.\execution\phase3-routing\Set-AcceptedDomainType.ps1 `
  -DomainsFile domains.txt `
  -DomainType InternalRelay
```

#### 3-2. AWS DMZ SMTP ルーティング変更（移行対象ドメイン→EXO）

```bash
# ドライラン
sudo bash execution/phase3-routing/Set-DmzSmtpRouting.sh \
  -d domains.txt \
  -m tenant.mail.protection.outlook.com \
  -n

# 本番実行
sudo bash execution/phase3-routing/Set-DmzSmtpRouting.sh \
  -d domains.txt \
  -m tenant.mail.protection.outlook.com
```

#### 3-3. （オプション）メイン Postfix ルーティング変更

```bash
# 内部SMTPハブの設定変更（必要な場合のみ）
sudo bash execution/phase3-routing/Set-PostfixRouting.sh \
  -d domains.txt \
  -m tenant.mail.protection.outlook.com
```

### Phase 4: 検証

#### 4-1. テストメール送信

```powershell
# lab-env のツールを使用
.\lab-env\Send-TestEmail.ps1 -To "user@example.co.jp" -Subject "移行テスト"
```

#### 4-2. メールフロー検証

```powershell
# テストケースファイルを作成
.\execution\phase4-validation\Test-MailFlowMatrix.ps1 `
  -TestCasesFile test_cases.csv `
  -LookbackHours 24
```

### 切り戻し（緊急時）

#### 全体ロールバック手順

```powershell
# 1. EXO Accepted Domain を Authoritative に戻す
.\execution\rollback\Restore-AcceptedDomainType.ps1 `
  -DomainsFile domains.txt

# 2. EXO コネクタを削除
.\execution\rollback\Undo-EXOConnectors.ps1
```

```bash
# 3. DMZ SMTP ルーティングを復元
sudo bash execution/rollback/Restore-DmzSmtpRouting.sh --latest

# 4. Postfix ルーティングを復元（変更していた場合）
sudo bash execution/rollback/Restore-PostfixRouting.sh --latest
```

## 作成されるコネクタ

| # | 種類 | 名前 | 用途 |
|---|---|---|---|
| 1 | Outbound | To-MailSecurity-Service | 外部宛の添付URL化（導入時）（送信セキュリティ導入時） |
| 2 | Outbound | To-OnPrem-DMZ-Fallback | 未移行ユーザーへのフォールバック |
| 3 | Inbound | From-AWS-DMZ-SMTP | AWS DMZ SMTPからの受信許可 |

## 必要モジュール

### PowerShell

```powershell
# AD操作（通常は管理サーバーにインストール済み）
Import-Module ActiveDirectory

# Entra操作
Install-Module Microsoft.Graph -Scope CurrentUser
Import-Module Microsoft.Graph

# EXO操作
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Import-Module ExchangeOnlineManagement
```

### Linux

```bash
# 通常は運用環境にインストール済み
postfix      # postconfコマンド
dnsutils     # dig（DNS棚卸しはPowerShell版を使う場合不要）
tar, grep, find  # 標準ツール
```

## 出力ファイル

### 出力先

全スクリプト共通で以下の形式:
```
./inventory_YYYYMMDD_HHMMSS/<component>/
  ├── run.log      # 実行ログ（何を実行したか証跡）
  ├── *.txt        # コマンド出力
  ├── *.csv        # 一覧（突合用）
  ├── *.json       # 詳細データ（機械可読）
  └── *.tgz        # 設定ファイル原本
```

### 各スクリプトの出力

| スクリプト | 出力先 | 主なファイル |
|---|---|---|
| collect_postfix.sh | `postfix_<host>/` | postconf-n.txt/json, etc_postfix.tgz, key_params.txt |
| collect_courier_imap.sh | `courier_imap_<host>/` | maildir_candidates.txt/json, etc_courier.tgz |
| collect_smtp_dmz.sh | `dmz_smtp_<host>/` | postconf-n.txt/json, mta_type.txt |
| Collect-ADInventory.ps1 | `ad_<timestamp>/` | ad_users_mailattrs.csv/json, schema_version.txt |
| Collect-EntraInventory.ps1 | `entra_<timestamp>/` | users_license.csv/json, subscribed_skus.csv |
| Collect-EXOInventory.ps1 | `exo_<timestamp>/` | recipients.csv/json, mailboxes.csv, connectors.csv |
| Collect-DNSRecords.ps1 | `dns_<timestamp>/` | dns_records.csv/json, domains_no_spf.txt |
| Detect-StrayRecipients.ps1 | `stray_report/<timestamp>/` | stray_candidates.csv, strays_action_required.csv |
| Test-SmtpDuplicates.ps1 | `duplicate_check/<timestamp>/` | csv_duplicates.csv, ad_conflicts.csv |
| Test-Prerequisites.ps1 | `prereq_check/<timestamp>/` | prereq_check_results.json, summary.txt |
| Set-AcceptedDomainType.ps1 | `accepted_domain_change/<timestamp>/` | change_results.csv |
| Test-MailFlowMatrix.ps1 | `mailflow_validation/<timestamp>/` | validation_results.csv |
| New-EXOTransportRules.ps1 | `transport_rules/<timestamp>/` | rule_creation_results.csv |
| Invoke-RecipientRemediation.ps1 | `remediation_execution/<timestamp>/` | remediation_results.csv |

## 注意事項

- **機密情報は回収しない設計**: パスワード/秘密鍵/メール本文は含まれない
- **Linux**: 原則root（or sudo）で実行
- **PowerShell**: 適切な権限を持つアカウントで実行
- **バックアップ**: 本番環境での実行前に必ずADバックアップを取得
- **WhatIfMode**: 破壊的操作は必ず WhatIf で確認してから本番実行

## CSV形式

### domains.txt（ドメイン一覧）

```
# コメント行はスキップ
example.co.jp
example.com
sub.example.co.jp
...
```

### mail_addresses.csv（メール属性投入用）

```csv
UserPrincipalName,SamAccountName,PrimarySmtpAddress,Aliases
user1@example.local,user1,user1@example.co.jp,alias1@example.co.jp;alias2@example.co.jp
user2@example.local,user2,user2@example.co.jp,
```

### test_cases.csv（メールフロー検証用）

```csv
TestID,From,To,Subject,ExpectedPath,ExpectedResult
TC001,user1@contoso.co.jp,user2@contoso.co.jp,内部宛テスト,EXO_INTERNAL,Delivered
TC002,user1@contoso.co.jp,external@gmail.com,外部宛テスト,EXO_MAILSEC_INTERNET,Delivered
TC003,external@gmail.com,user1@contoso.co.jp,外部からの受信テスト,INTERNET_FIREEYE_DMZ_EXO,Delivered
TC004,user1@contoso.co.jp,unmigrated@contoso.co.jp,未移行ユーザー宛テスト,EXO_INTERNALRELAY_DMZ_COURIER,Delivered
```

## クリーンアップ

作業完了後、顧客環境から削除:

```bash
# Linux
rm -rf /tmp/inventory*
rm -rf ./inventory_*

# スクリプト本体も削除
rm -rf /path/to/exo-migration-tools
```

```powershell
# Windows
Remove-Item -Recurse -Force C:\temp\inventory*
Remove-Item -Recurse -Force .\inventory_*
Remove-Item -Recurse -Force .\stray_report
Remove-Item -Recurse -Force .\duplicate_check
Remove-Item -Recurse -Force .\prereq_check
Remove-Item -Recurse -Force .\accepted_domain_change
Remove-Item -Recurse -Force .\mailflow_validation
Remove-Item -Recurse -Force .\connector_rollback
```
