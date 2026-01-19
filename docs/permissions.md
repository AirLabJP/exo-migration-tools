# 必要な権限一覧

各スクリプトの実行に必要な権限をまとめています。
**作業開始前に権限取得を完了しておくこと**が重要です。

---

## 権限サマリー

| カテゴリ | 必要な権限 | 取得方法 |
|----------|-----------|----------|
| **Active Directory** | Domain Admins / Account Operators | ADグループへの追加 |
| **AD スキーマ拡張** | Schema Admins + Enterprise Admins | 一時的に付与→作業後削除 |
| **Exchange Online** | Exchange Administrator | Entra IDロール割り当て |
| **Microsoft Graph** | 各種スコープ（下記参照） | Connect-MgGraph -Scopes で同意 |
| **Linux (Postfix)** | root / sudo | SSH + sudo権限 |

---

## フェーズ別の権限要件

### Phase 1: 棚卸し・事前準備

| スクリプト | 必要な権限 | 備考 |
|-----------|-----------|------|
| `Collect-ADInventory.ps1` | **Domain Users** + ADモジュール読み取り | 読み取りのみ |
| `Collect-EntraInventory.ps1` | **User.Read.All**, Group.Read.All | Graph API |
| `Collect-EXOInventory.ps1` | **View-Only Organization Management** | EXO読み取り専用ロール |
| `Collect-DNSRecords.ps1` | なし（外部DNS問い合わせ） | |
| `collect_postfix.sh` | **root** または sudo | 設定ファイル読み取り |
| `collect_courier_imap.sh` | **root** または sudo | 設定ファイル読み取り |
| `Test-Prerequisites.ps1` | 各種（チェック対象による） | |
| `Invoke-ExchangeSchemaPrep.ps1` | **Schema Admins + Enterprise Admins** | ★ 最も高い権限 |

### Phase 2: EXO箱作り

| スクリプト | 必要な権限 | 備考 |
|-----------|-----------|------|
| `New-ADUsersFromCsv.ps1` | **Domain Admins** または Account Operators + 対象OUへの書き込み | ユーザー作成 |
| `New-EntraUsersFromCsv.ps1` | **User.ReadWrite.All**, Group.ReadWrite.All | Graph API |
| `Set-ADMailAddressesFromCsv.ps1` | **Domain Admins** または 対象OUへの書き込み | 属性変更 |
| `Add-UsersToLicenseGroup.ps1` | **Group.ReadWrite.All** | Graph API |
| `New-EXOConnectors.ps1` | **Exchange Administrator** | コネクタ作成 |

### Phase 3: ルーティング変更

| スクリプト | 必要な権限 | 備考 |
|-----------|-----------|------|
| `Set-AcceptedDomainType.ps1` | **Exchange Administrator** | Accepted Domain変更 |
| `Set-DmzSmtpRouting.sh` | **root** または sudo | Postfix設定変更 |
| `Set-PostfixRouting.sh` | **root** または sudo | Postfix設定変更 |
| `New-TestMailboxes.ps1` | **User.ReadWrite.All**, Directory.ReadWrite.All | テストユーザー作成 |

### Phase 4: 検証

| スクリプト | 必要な権限 | 備考 |
|-----------|-----------|------|
| `Test-MailFlowMatrix.ps1` | **View-Only Organization Management** | Message Trace読み取り |

### Rollback

| スクリプト | 必要な権限 | 備考 |
|-----------|-----------|------|
| `Undo-EXOConnectors.ps1` | **Exchange Administrator** | コネクタ削除 |
| `Restore-AcceptedDomainType.ps1` | **Exchange Administrator** | Accepted Domain変更 |
| `Restore-DmzSmtpRouting.sh` | **root** または sudo | Postfix設定復元 |
| `Restore-PostfixRouting.sh` | **root** または sudo | Postfix設定復元 |

### 分析

| スクリプト | 必要な権限 | 備考 |
|-----------|-----------|------|
| `Detect-StrayRecipients.ps1` | なし（CSVファイル分析） | |
| `Plan-RecipientRemediation.ps1` | なし（CSVファイル分析） | |
| `Test-SmtpDuplicates.ps1` | なし（CSVファイル分析） | |

---

## Microsoft Graph スコープ一覧

```powershell
# 棚卸し（読み取りのみ）
Connect-MgGraph -Scopes "User.Read.All","Group.Read.All"

# ユーザー作成・グループ管理（書き込み）
Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","Directory.ReadWrite.All"
```

---

## Exchange Online 権限

### 推奨ロール

| 作業 | 推奨ロール | 代替 |
|------|-----------|------|
| 棚卸し（読み取り） | View-Only Organization Management | |
| コネクタ作成・変更 | Exchange Administrator | Organization Management |
| Accepted Domain変更 | Exchange Administrator | Organization Management |
| Message Trace | View-Only Organization Management | Compliance Management |

### 接続方法

```powershell
# 基本接続
Connect-ExchangeOnline -UserPrincipalName admin@contoso.onmicrosoft.com

# アプリ認証（自動化用）
Connect-ExchangeOnline -AppId $appId -CertificateThumbprint $thumbprint -Organization "contoso.onmicrosoft.com"
```

---

## Active Directory 権限

### ADスキーマ拡張（Phase 1）

**必要なグループ**:
- Schema Admins
- Enterprise Admins

**注意**: 
- Schema Master DCで実行すること
- 作業完了後、グループから削除することを推奨

### AD属性変更（Phase 2）

**最小権限での委任例**:

```powershell
# 特定OUへの書き込み権限を委任
# OU=Users,DC=contoso,DC=local に対して
# - mail属性の書き込み
# - proxyAddresses属性の書き込み
```

---

## Linux サーバー権限

### 必要な権限

| サーバー | 必要な権限 | 用途 |
|----------|-----------|------|
| Postfix (SMTPハブ) | root / sudo | 設定読み取り・変更 |
| Courier IMAP | root / sudo | 設定読み取り |
| AWS DMZ SMTP | root / sudo | transport設定変更 |
| 内部DMZ SMTP | root / sudo | transport設定変更 |

### SSH接続

```bash
# 設定ファイル転送
scp inventory/*.sh user@postfix-server:/tmp/

# 実行
ssh user@postfix-server "sudo bash /tmp/collect_postfix.sh /tmp/output"
```

---

## 権限取得チェックリスト

作業開始前に以下を確認：

- [ ] AD: Domain Admins または Account Operators 権限
- [ ] AD: Schema Admins + Enterprise Admins（スキーマ拡張時のみ）
- [ ] EXO: Exchange Administrator ロール割り当て
- [ ] Graph: 必要なスコープへの同意
- [ ] Linux: SSH接続とsudo権限
- [ ] Postfix設定ファイルのバックアップ権限

---

## トラブルシューティング

### 権限エラーが出る場合

1. **AD**: `Get-ADUser -Identity $user` で読み取りできるか確認
2. **EXO**: `Get-OrganizationConfig` で接続できているか確認
3. **Graph**: `Get-MgContext` でスコープを確認

### 権限昇格が必要な場合

お客様IT部門に以下の情報を提供して依頼：
- 作業者のUPN
- 必要な権限（上記表を参照）
- 権限が必要な期間
- 作業内容の説明

