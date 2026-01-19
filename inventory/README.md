# Inventory Scripts - 現調スクリプト群

Exchange Online（EXO）への移行に必要な現地調査データを収集するスクリプト群です。

## 📋 概要

以下のスクリプトで、オンプレミス環境とクラウド環境の現状を網羅的に収集します：

| スクリプト | 対象環境 | 説明 |
|----------|---------|------|
| **Collect-ADInventory.ps1** | AD Domain Controller | ADユーザー・グループ・連絡先のメール属性、SMTP重複検出、Exchangeスキーマ拡張状態 |
| **Collect-DNSRecords.ps1** | DNS参照可能な環境 | MX/SPF/DKIM/DMARC/TLS-RPT/MTA-STS/BIMI、品質チェック、弱点フラグ付き |
| **Collect-EXOInventory.ps1** | Exchange Online接続可能な環境 | EXO受信者、コネクタ、EOP/Defenderポリシー・ルール、権限、転送設定、InboxRule外部転送 |
| **Collect-EntraInventory.ps1** | Entra ID接続可能な環境 | ユーザー、ライセンス、同期状態、Exchange Online有効判定、ドメイン一覧 |
| **Collect-EntraConnectInventory.ps1** | Entra Connectサーバー | ADSyncスケジューラ、コネクタ、同期ルール、属性フロー、sourceAnchor、同期状況 |
| **collect_courier_imap.sh** | Courier IMAP / Dovecot サーバー | メールボックス一覧、ユーザー突合、SQL/LDAP設定マスク |
| **collect_postfix.sh** | Postfix サーバー | メールフロー設定、postmulti対応、マップファイル自動検出 |
| **collect_smtp_dmz.sh** | DMZ SMTP サーバー | MTA検出、ファイアウォール詳細、ネットワーク設定 |

---

## 🔧 前提条件

### PowerShellスクリプト共通

- **PowerShell**: Version 5.1 以降 または PowerShell 7+
- **実行ポリシー**: `Set-ExecutionPolicy RemoteSigned` 以上
- **管理者権限**: 必須（ADスクリプトのみ）

### 各スクリプト固有の要件

#### Collect-ADInventory.ps1

- **モジュール**: `ActiveDirectory` (RSAT-AD-PowerShell)
- **権限**: Domain Admins または Read権限を持つアカウント
- **実行場所**: Active Directory Domain Controller または RSAT導入済みクライアント

```powershell
# モジュールインストール（Windows Serverの場合）
Install-WindowsFeature -Name RSAT-AD-PowerShell

# モジュールインストール（Windows 10/11の場合）
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
```

#### Collect-DNSRecords.ps1

- **モジュール**: なし（`Resolve-DnsName` コマンドレット使用）
- **権限**: 不要
- **ネットワーク**: インターネット接続（外部DNS参照）

#### Collect-EXOInventory.ps1

- **モジュール**: `ExchangeOnlineManagement` (v3.0 以降推奨)
- **権限**: Exchange Administrator または Global Reader
- **実行場所**: インターネット接続可能な環境

```powershell
# モジュールインストール
Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber
```

#### Collect-EntraInventory.ps1

- **モジュール**: `Microsoft.Graph.Users`, `Microsoft.Graph.Identity.DirectoryManagement`, `Microsoft.Graph.Groups`
- **権限**: `User.Read.All`, `Directory.Read.All`, `Organization.Read.All`, `Domain.Read.All`, `Group.Read.All`
- **実行場所**: インターネット接続可能な環境

```powershell
# モジュールインストール
Install-Module -Name Microsoft.Graph -Force -AllowClobber
```

#### Collect-EntraConnectInventory.ps1

- **モジュール**: `ADSync`（Entra Connectサーバーにインストール済み）
- **権限**: 管理者権限
- **実行場所**: Entra Connect（Azure AD Connect）サーバー上

```powershell
# モジュールは Entra Connect インストール時に自動的にインストールされます
# Import-Module ADSync でインポート可能
```

### Shellスクリプト共通

- **OS**: Linux (RHEL/CentOS/Ubuntu/Debian 等)
- **実行権限**: root または sudo 権限
- **実行方法**: `bash` または `sudo bash`

#### 個別の要件

- **collect_courier_imap.sh**: Courier IMAP または Dovecot がインストールされている環境
- **collect_postfix.sh**: Postfix がインストールされている環境（`postconf` コマンド必須）
- **collect_smtp_dmz.sh**: Postfix/Exim/Sendmail のいずれかがインストールされている環境

---

## 🚀 実行例

### PowerShellスクリプト

```powershell
# AD棚卸し
.\Collect-ADInventory.ps1 -OutRoot C:\temp\inventory

# AD棚卸し（検索ベース指定、無効ユーザー含む）
.\Collect-ADInventory.ps1 -SearchBase "OU=Tokyo,DC=contoso,DC=com" -IncludeDisabled

# DNS棚卸し（ドメインリストファイル指定）
.\Collect-DNSRecords.ps1 -DomainsFile domains.txt -OutRoot C:\temp\inventory

# DNS棚卸し（配列で直接指定）
.\Collect-DNSRecords.ps1 -Domains @("example.com","example.co.jp") -OutRoot C:\temp\inventory

# EXO棚卸し
.\Collect-EXOInventory.ps1 -OutRoot C:\temp\inventory

# EXO棚卸し（EXOv3 REST API使用）
.\Collect-EXOInventory.ps1 -OutRoot C:\temp\inventory -UseEXOv3

# Entra ID棚卸し
.\Collect-EntraInventory.ps1 -OutRoot C:\temp\inventory

# Entra ID棚卸し（大規模環境向け逐次CSV出力）
.\Collect-EntraInventory.ps1 -OutRoot C:\temp\inventory -StreamToCsv

# Entra Connect棚卸し（Entra Connectサーバー上で実行）
.\Collect-EntraConnectInventory.ps1 -OutRoot C:\temp\inventory
```

### Shellスクリプト

```bash
# Courier IMAP / Dovecot 棚卸し
sudo bash collect_courier_imap.sh /tmp/inventory

# Postfix 棚卸し
sudo bash collect_postfix.sh /tmp/inventory

# DMZ SMTP 棚卸し
sudo bash collect_smtp_dmz.sh /tmp/inventory
```

---

## 📁 出力ファイル一覧

### 共通

全てのスクリプトで以下が生成されます：

- **run.log**: 実行ログ（標準出力/標準エラー出力の完全記録）
- **summary.txt** または **summary.json**: サマリー情報
- **error.log**: エラー発生時のエラー情報（エラー時のみ）

### 二段出力（要約CSV + 詳細XML/JSON）

人が読む要約CSVと、機械可読のXML/JSONの両方が出力されます：

#### Collect-ADInventory.ps1

| ファイル | 形式 | 説明 |
|---------|------|------|
| `ad_users_mailattrs.csv` | 要約CSV | ユーザーのメール属性一覧 |
| `ad_users_mailattrs.json` | 詳細JSON | ユーザー詳細データ（機械可読） |
| `ad_users_mailattrs.xml` | 詳細XML | ユーザー詳細データ（PowerShell互換） |
| `ad_groups_mailattrs.csv` | 要約CSV | グループのメール属性一覧 |
| `ad_groups_mailattrs.json` | 詳細JSON | グループ詳細データ |
| `ad_groups_mailattrs.xml` | 詳細XML | グループ詳細データ |
| `ad_forest.json` / `ad_forest.txt` | JSON/TXT | フォレスト情報 |
| `ad_domain.json` / `ad_domain.txt` | JSON/TXT | ドメイン情報 |
| `schema_version.txt` | TXT | Exchangeスキーマ拡張状態 |
| `entra_connect_scp.json` / `entra_connect_scp.txt` | JSON/TXT | Entra Connect同期状態 |

#### Collect-DNSRecords.ps1

| ファイル | 形式 | 説明 |
|---------|------|------|
| `dns_records.csv` | 要約CSV | 全ドメインのDNSレコード一覧（MX/SPF/DMARC/DKIM/TLS-RPT/MTA-STS/BIMI/弱点フラグ） |
| `dns_records.json` | 詳細JSON | DNS詳細データ |
| `dns_records.xml` | 詳細XML | DNS詳細データ |
| `domains_with_issues.csv` | 要約CSV | 弱点フラグが付いたドメイン |
| `domains_no_spf.txt` | TXT | SPF未設定ドメイン |
| `domains_no_dmarc.txt` | TXT | DMARC未設定ドメイン |

**弱点フラグ**:
- `NoMX`: MXレコード未設定
- `NoSPF`: SPFレコード未設定
- `NoDMARC`: DMARCレコード未設定
- `DMARC_p_none`: DMARCポリシーが `p=none`（監視のみ）
- `DMARC_pct_low`: DMARC適用率が100%未満
- `SPF_softfail`: SPF設定が `~all`（推奨は `-all`）
- `SPF_neutral`: SPF設定が `?all`（推奨は `-all`）

#### Collect-EXOInventory.ps1

| ファイル | 形式 | 説明 |
|---------|------|------|
| `accepted_domains.csv` | 要約CSV | 承認済みドメイン |
| `accepted_domains.json` | 詳細JSON | 承認済みドメイン詳細 |
| `inbound_connectors.csv` / `.json` | CSV/JSON | 受信コネクタ |
| `outbound_connectors.csv` / `.json` | CSV/JSON | 送信コネクタ |
| `recipients.csv` / `.json` | CSV/JSON | 全受信者一覧 |
| `mailboxes.csv` / `.json` | CSV/JSON | メールボックス詳細 |
| `transport_rules.csv` / `.json` | CSV/JSON | トランスポートルール |
| `remote_domains.csv` / `.json` | CSV/JSON | リモートドメイン設定 |
| `eop_antiphish.csv` / `.json` | CSV/JSON | EOP AntiPhishポリシー |
| `eop_malware.csv` / `.json` | CSV/JSON | EOP Malwareポリシー |
| `eop_spam.csv` / `.json` | CSV/JSON | EOP スパムフィルター |
| `defender_safelinks.csv` / `.json` | CSV/JSON | Defender SafeLinksポリシー |
| `defender_safeattach.csv` / `.json` | CSV/JSON | Defender SafeAttachmentsポリシー |
| `cas_mailbox_protocols.csv` / `.json` | CSV/JSON | POP/IMAP/MAPI/ActiveSync設定 |
| `mailbox_permissions.csv` / `.json` | CSV/JSON | メールボックス権限 |
| `sendas_permissions.csv` / `.json` | CSV/JSON | SendAs権限 |
| `mailbox_forwarding.csv` / `.json` | CSV/JSON | 転送設定（外部転送検出） |
| `retention_policies.csv` / `.json` | CSV/JSON | 保持ポリシー |
| `transport_config.csv` / `.json` | CSV/JSON | サイズ制限/TLS設定 |

#### Collect-EntraInventory.ps1

| ファイル | 形式 | 説明 |
|---------|------|------|
| `org.json` | JSON | テナント情報（DirSync状態含む） |
| `domains.csv` / `.json` | CSV/JSON | ドメイン一覧 |
| `subscribed_skus.csv` | 要約CSV | ライセンスSKU一覧 |
| `subscribed_skus.json` / `.xml` | JSON/XML | ライセンスSKU詳細 |
| `users_license.csv` | 要約CSV | ユーザー×ライセンス対応表（HasExoEnabled含む） |
| `users_license.json` / `.xml` | JSON/XML | ユーザー詳細データ |
| `users_licence_issues.csv` | CSV | ライセンス問題ユーザー |
| `license_groups.csv` | CSV | ライセンス割当グループ |

#### Collect-EntraConnectInventory.ps1

| ファイル | 形式 | 説明 |
|---------|------|------|
| `version.json` | JSON | Entra Connectバージョン |
| `scheduler.json` | JSON | スケジューラ状態（同期間隔、有効/無効） |
| `global_settings.json` | JSON | グローバル設定 |
| `connectors.csv` / `.json` | CSV/JSON | AD/Entra ID Connectors構成 |
| `sync_rules.csv` / `.json` | CSV/JSON | 同期ルール一覧 |
| `attribute_flows_mail.csv` / `.json` | CSV/JSON | mail/proxyAddresses/mailNickname/targetAddress属性フロー |
| `source_anchor.json` | JSON | sourceAnchor設定（msDS-ConsistencyGuid or objectGUID） |
| `run_history.csv` | CSV | 直近の同期実行履歴 |
| `run_history_errors.csv` | CSV | 同期エラー一覧 |
| `pending_exports.csv` | CSV | 保留中のエクスポート |
| `server_config/` | DIR | Export-ADSyncServerConfiguration出力 |

### Shellスクリプト

#### collect_courier_imap.sh

| ファイル | 形式 | 説明 |
|---------|------|------|
| `maildir_candidates.txt` | TXT | メールボックス（Maildir）一覧 |
| `maildir_candidates.json` | JSON | メールボックス詳細データ |
| `getent_passwd.txt` | TXT | システムユーザー一覧 |
| `getent_passwd.json` | JSON | システムユーザー詳細データ |
| `etc_courier.tgz` | TGZ | Courier IMAP設定アーカイブ（秘密鍵除外） |
| `etc_dovecot.tgz` | TGZ | Dovecot設定アーカイブ（秘密鍵除外） |
| `userdb.masked` / `users.masked` | TXT | 仮想ユーザー定義（パスワードハッシュマスク済み） |
| `summary.json` | JSON | サマリー情報 |

#### collect_postfix.sh

| ファイル | 形式 | 説明 |
|---------|------|------|
| `postconf-n.txt` | TXT | 有効な設定一覧 |
| `postconf-n.json` | JSON | 設定詳細データ |
| `key_params.txt` | TXT | メールフロー・サイズ制限の主要パラメータ |
| `size_limits.txt` | TXT | サイズ制限設定 |
| `tls_cert_paths.txt` | TXT | TLS証明書パス |
| `etc_postfix.tgz` | TGZ | /etc/postfix設定アーカイブ（秘密鍵・パスワード除外） |
| `maps/` | DIR | transport, virtual等のマップファイル（パスワードマスク済み） |
| `summary.json` | JSON | サマリー情報 |

#### collect_smtp_dmz.sh

| ファイル | 形式 | 説明 |
|---------|------|------|
| `mta_type.txt` | TXT | 検出されたMTA種類（postfix/exim/sendmail） |
| `postconf-n.txt` / `.json` | TXT/JSON | Postfix有効設定（Postfixの場合） |
| `key_params.txt` | TXT | メールフロー設定 |
| `etc_postfix.tgz` / `etc_exim4.tgz` / `etc_mail.tgz` | TGZ | MTA設定アーカイブ（秘密鍵・パスワード除外） |
| `ip_addr.txt` | TXT | IPアドレス一覧 |
| `ip_route.txt` | TXT | ルーティングテーブル |
| `iptables.txt` | TXT | ファイアウォール設定 |
| `summary.json` | JSON | サマリー情報 |

---

## 🔒 セキュリティに関する注意事項

### 秘匿情報の除外・マスキング

全てのスクリプトで、以下の秘匿情報が**自動的に除外またはマスキング**されます：

#### PowerShellスクリプト

- **パスワードハッシュ**: 取得していません（ADのunicodePwd等は収集対象外）
- **認証トークン**: セッションは収集完了後に必ず切断されます

#### Shellスクリプト

- **秘密鍵**: `.key`, `.pem`, `.p12`, `.pfx` ファイルは収集されません
- **パスワードファイル**:
  - Postfix: `sasl_passwd` 等は `***MASKED***` に置換
  - Courier/Dovecot: `userdb`, `users` のパスワードハッシュは `***MASKED***` に置換
- **TLS証明書**: 公開鍵（.crt, .cert）のみ収集、秘密鍵は除外

### エラー時の後片付け保証

#### PowerShellスクリプト

全てのスクリプトで `try-catch-finally` を使用し、エラー発生時も以下が保証されます：

- `Stop-Transcript`: ログの確実な記録
- `Disconnect-ExchangeOnline` / `Disconnect-MgGraph`: セッションの確実な切断

#### Shellスクリプト

全てのスクリプトで `trap cleanup EXIT ERR INT TERM` を使用し、以下が保証されます：

- ログの確実な記録
- 一時ファイルの削除（必要に応じて）
- スクリプト中断時（Ctrl+C等）も後片付けを実行

---

## 🔍 トラブルシューティング

### PowerShellスクリプトで「実行ポリシーエラー」が出る

```powershell
# 実行ポリシーを確認
Get-ExecutionPolicy

# RemoteSigned に変更（管理者権限が必要）
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### ExchangeOnline接続で「認証エラー」が出る

```powershell
# モジュールを最新版に更新
Update-Module -Name ExchangeOnlineManagement -Force

# 既存のセッションを切断してから再実行
Disconnect-ExchangeOnline -Confirm:$false
```

### Shellスクリプトで「Permission denied」が出る

```bash
# スクリプトに実行権限を付与
chmod +x collect_*.sh

# root権限で実行
sudo bash collect_postfix.sh
```

### DNSレコード取得で「NXDOMAIN」エラーが出る

- 対象ドメインが存在しない、またはDNSサーバーで解決できない
- `-DnsServer` パラメータで外部DNSサーバーを指定してみてください：

```powershell
.\Collect-DNSRecords.ps1 -DomainsFile domains.txt -DnsServer 8.8.8.8
```

---

## 📚 参考情報

### EXO移行時のDNS変更

スクリプトで収集したDNS情報を元に、以下のDNS変更を実施してください：

| レコード | 移行後の値 | 備考 |
|---------|-----------|------|
| **MX** | `<tenant>.mail.protection.outlook.com` | 優先度: 0 または 10 |
| **SPF** | `v=spf1 include:spf.protection.outlook.com ...` | 既存のSPFに追加 |
| **DKIM** | EXO管理画面で有効化後、CNAMEを設定 | セレクタは `selector1`, `selector2` |
| **DMARC** | `v=DMARC1; p=quarantine;` または `p=reject;` | 段階的に強化を推奨 |

### EXOサイズ制限

スクリプトで収集したサイズ制限と、EXOの制限を比較してください：

| 項目 | EXO制限 | オンプレ確認先 |
|-----|---------|---------------|
| 送信メール | 35 MB | `message_size_limit` (Postfix) |
| 受信メール | 36 MB | TransportConfig (EXO) |
| メールボックス | 50 GB〜100 GB（プランによる） | RetentionPolicy (EXO) |

---

## 📝 ライセンス

このスクリプト群は、exo-migration-tools プロジェクトの一部です。

---

## 🙏 貢献

改善提案やバグ報告は、GitHubのIssueまでお願いします。
