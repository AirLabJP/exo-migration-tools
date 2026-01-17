# Exchange Online Migration Tools

Linux（Postfix/Courier IMAP）ベースのメールシステムからExchange Onlineへの移行に必要なスクリプト群。

## 想定環境

```
[外部]
   │
   ▼ MX
┌──────────────────────────────────────────────────┐
│  AWS (DMZ)                                       │
│  ┌─────────────────┐                             │
│  │ EC2: Postfix    │ ← 外部メール受口            │
│  │ (SMTP中継)      │                             │
│  └────────┬────────┘                             │
└───────────┼──────────────────────────────────────┘
            │
            ▼ (フォールバック: 内部DMZ経由も可)
┌──────────────────────────────────────────────────┐
│  内部ネットワーク                                │
│                                                  │
│  ┌─────────────────┐    ┌─────────────────┐      │
│  │ Postfix/FireEye │    │ Courier IMAP    │      │
│  │ (内部DMZ)       │───▶│ (メールボックス) │      │
│  └─────────────────┘    └─────────────────┘      │
│                                                  │
│  ┌─────────────────┐    ┌─────────────────┐      │
│  │ Active Directory│    │ 管理端末        │      │
│  │ (オンプレ)      │    │ (PowerShell)    │      │
│  └─────────────────┘    └─────────────────┘      │
└──────────────────────────────────────────────────┘
```

## フォルダ構成

```
exo-migration-tools/
├── inventory/          # 棚卸しスクリプト
│   ├── collect_postfix.sh
│   ├── collect_courier_imap.sh
│   ├── collect_smtp_dmz.sh
│   ├── Collect-ADInventory.ps1
│   ├── Collect-EntraInventory.ps1
│   ├── Collect-EXOInventory.ps1
│   └── Collect-DNSRecords.ps1
├── analysis/           # 分析・検証スクリプト
│   ├── Detect-StrayRecipients.ps1
│   └── Test-SmtpDuplicates.ps1
└── execution/          # 実行スクリプト
    ├── Invoke-ExchangeSchemaPrep.ps1
    ├── Set-ADMailAddressesFromCsv.ps1
    └── New-EXOConnectors.ps1       # EXOコネクタ作成
```

## 使用順序

### Phase 1: 棚卸し

#### Linux環境（AWS EC2 / 内部サーバー）

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

#### Windows/PowerShell（管理端末）

```powershell
# AD棚卸し（内部ネットワークから実行）
.\inventory\Collect-ADInventory.ps1 -OutRoot C:\temp\inventory

# Entra棚卸し（Graph接続必要）
.\inventory\Collect-EntraInventory.ps1 -OutRoot C:\temp\inventory

# EXO棚卸し（EXO接続必要）
.\inventory\Collect-EXOInventory.ps1 -OutRoot C:\temp\inventory

# DNS棚卸し（外部DNS＝公開情報なのでどこからでもOK）
.\inventory\Collect-DNSRecords.ps1 -DomainsFile domains.txt -OutRoot C:\temp\inventory
```

### Phase 2: 分析（紛れ検出）

```powershell
# 単一ドメイン
.\analysis\Detect-StrayRecipients.ps1 `
  -ExoRecipientsCsv C:\temp\inventory\exo_*\recipients.csv `
  -AdUsersCsv C:\temp\inventory\ad_*\ad_users_mailattrs.csv `
  -TargetDomains "example.co.jp"

# 複数ドメイン（配列指定）
.\analysis\Detect-StrayRecipients.ps1 `
  -ExoRecipientsCsv C:\temp\inventory\exo_*\recipients.csv `
  -AdUsersCsv C:\temp\inventory\ad_*\ad_users_mailattrs.csv `
  -TargetDomains @("example.co.jp","example.com","sub.example.co.jp")

# 複数ドメイン（ファイル指定：40ドメイン等）
.\analysis\Detect-StrayRecipients.ps1 `
  -ExoRecipientsCsv C:\temp\inventory\exo_*\recipients.csv `
  -AdUsersCsv C:\temp\inventory\ad_*\ad_users_mailattrs.csv `
  -TargetDomainsFile domains.txt
```

### Phase 3: ADスキーマ拡張

```powershell
# Schema Master DCで実行（Enterprise Admins + Schema Admins権限必要）
.\execution\Invoke-ExchangeSchemaPrep.ps1 `
  -SetupExePath D:\ExchangeSetup\Setup.exe `
  -OrganizationName "Contoso"
```

### Phase 4: メール属性投入

```powershell
# 1) SMTP重複チェック（投入CSVの検証）
.\analysis\Test-SmtpDuplicates.ps1 `
  -CsvPath mail_addresses.csv `
  -AdUsersCsv C:\temp\inventory\ad_*\ad_users_mailattrs.csv `
  -OutDir C:\temp\duplicates

# 2) WhatIfで確認（実際には変更しない）
.\execution\Set-ADMailAddressesFromCsv.ps1 `
  -CsvPath mail_addresses.csv `
  -WhatIfMode

# 3) 問題なければ本番実行
.\execution\Set-ADMailAddressesFromCsv.ps1 `
  -CsvPath mail_addresses.csv
```

### Phase 5: EXOコネクタ作成

```powershell
# 1) WhatIfで確認（実際には作成しない）
.\execution\New-EXOConnectors.ps1 `
  -GwcSmartHost "gwc.example.com" `
  -OnPremDmzSmtpHost "dmz-smtp.internal.example.co.jp" `
  -AwsDmzSmtpIP "203.0.113.10" `
  -TargetDomainsFile domains.txt `
  -WhatIfMode

# 2) 問題なければ本番実行
.\execution\New-EXOConnectors.ps1 `
  -GwcSmartHost "gwc.example.com" `
  -OnPremDmzSmtpHost "dmz-smtp.internal.example.co.jp" `
  -AwsDmzSmtpIP "203.0.113.10" `
  -TargetDomainsFile domains.txt

# 3) Accepted Domain を Internal Relay に設定（スクリプト実行後に表示されるコマンド）
Set-AcceptedDomain -Identity "example.co.jp" -DomainType InternalRelay
```

### 作成されるコネクタ

| # | 種類 | 名前 | 用途 |
|---|---|---|---|
| 1 | Outbound | To-GuardianWall-Cloud | 外部宛の添付URL化 |
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
  └── *.tgz        # 設定ファイル原本
```

### 各スクリプトの出力

| スクリプト | 出力先 | 主なファイル |
|---|---|---|
| collect_postfix.sh | `postfix_<host>/` | postconf-n.txt, etc_postfix.tgz, key_params.txt |
| collect_courier_imap.sh | `courier_imap_<host>/` | etc_courier.tgz, maildir_candidates.txt |
| collect_smtp_dmz.sh | `dmz_smtp_<host>/` | postconf-n.txt, mta_type.txt |
| Collect-ADInventory.ps1 | `ad_<timestamp>/` | ad_users_mailattrs.csv, schema_version.txt |
| Collect-EntraInventory.ps1 | `entra_<timestamp>/` | users_license.csv, subscribed_skus.csv |
| Collect-EXOInventory.ps1 | `exo_<timestamp>/` | recipients.csv, mailboxes.csv, connectors.csv |
| Collect-DNSRecords.ps1 | `dns_<timestamp>/` | dns_records.csv, domains_no_spf.txt |
| Detect-StrayRecipients.ps1 | `stray_report/<timestamp>/` | stray_candidates.csv, strays_action_required.csv |
| Test-SmtpDuplicates.ps1 | `duplicate_check/<timestamp>/` | csv_duplicates.csv, ad_conflicts.csv |
| New-EXOConnectors.ps1 | (コンソール出力のみ) | — コネクタをEXOに直接作成 |

### クリーンアップ

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
```

## 注意事項

- **機密情報は回収しない設計**: パスワード/秘密鍵/メール本文は含まれない
- **Linux**: 原則root（or sudo）で実行
- **PowerShell**: 適切な権限を持つアカウントで実行
- **バックアップ**: 本番環境での実行前に必ずADバックアップを取得
- **/tmp**: 既存の/tmpフォルダへの影響なし（サブフォルダを作成）

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
