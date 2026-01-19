# CSVテンプレート

ユーザー作成スクリプトで使用するCSVテンプレートです。

## sample_users_ad.csv - ADユーザー作成用

`New-ADUsersFromCsv.ps1` で使用します。

| 列名 | 必須 | 説明 |
|------|------|------|
| SamAccountName | ○ | ADのsAMAccountName（ログオン名） |
| UserPrincipalName | - | UPN（省略時はSamAccountName@ドメインで生成） |
| DisplayName | ○ | 表示名 |
| GivenName | - | 名 |
| Surname | - | 姓 |
| PrimarySmtpAddress | - | プライマリSMTPアドレス（-SetMailAttributes時に使用） |
| Aliases | - | エイリアス（セミコロン区切り） |
| Description | - | 説明 |

### 使用例

```powershell
# 本番環境
.\execution\phase2-setup\New-ADUsersFromCsv.ps1 `
  -CsvPath templates\sample_users_ad.csv `
  -TargetOU "OU=Users,DC=contoso,DC=local" `
  -SetMailAttributes

# 検証環境
.\execution\phase2-setup\New-ADUsersFromCsv.ps1 `
  -CsvPath templates\sample_users_ad.csv `
  -TargetOU "OU=TestUsers,DC=lab,DC=local"
```

---

## sample_users_entra.csv - Entra IDユーザー作成用

`New-EntraUsersFromCsv.ps1` で使用します。

| 列名 | 必須 | 説明 |
|------|------|------|
| UserPrincipalName | ○ | UPN（＝メールアドレスになることが多い） |
| DisplayName | - | 表示名（省略時はUPNから生成） |
| GivenName | - | 名 |
| Surname | - | 姓 |
| MailNickname | - | メールニックネーム（省略時はUPNから生成） |

### 使用例

```powershell
# ユーザー作成＋ライセンスグループ追加
.\execution\phase2-setup\New-EntraUsersFromCsv.ps1 `
  -CsvPath templates\sample_users_entra.csv `
  -LicenseGroupName "EXO-License-Pilot"

# ユーザー作成のみ（グループ追加なし）
.\execution\phase2-setup\New-EntraUsersFromCsv.ps1 `
  -CsvPath templates\sample_users_entra.csv `
  -SkipGroupAdd
```

---

## ライセンスグループについて

### 推奨運用

| フェーズ | グループ種別 | 理由 |
|----------|-------------|------|
| **移行中** | 静的グループ | CSVで指定したユーザーのみライセンス付与 → 意図しないメールボックス作成を防止 |
| **移行完了後** | 動的グループ | ドメインベースの規則で自動化 → 運用負荷軽減 |

### グループの事前作成

Entra ID管理センターでライセンス付与用の静的セキュリティグループを作成してください。

1. [Entra ID管理センター](https://entra.microsoft.com) にアクセス
2. [グループ] → [新しいグループ]
3. グループの種類: セキュリティ
4. グループ名: `EXO-License-Pilot`（例）
5. メンバーシップの種類: **割り当て済み**（静的）
6. 作成後、[ライセンス] → Exchange Online を含むライセンスを割り当て

---

## 検証環境での使い方

### 1. ADに作成 → Entra ID Connect同期 → EXOメールボックス

```powershell
# 1. ADにユーザー作成
.\execution\phase2-setup\New-ADUsersFromCsv.ps1 `
  -CsvPath templates\sample_users_ad.csv `
  -TargetOU "OU=Users,DC=lab,DC=local" `
  -SetMailAttributes

# 2. Entra ID Connect 差分同期
Start-ADSyncSyncCycle -PolicyType Delta

# 3. 同期完了を待ってからライセンスグループに追加
.\execution\phase2-setup\Add-UsersToLicenseGroup.ps1 `
  -CsvPath .\ad_user_creation\*\results.csv `
  -GroupName "EXO-License-Pilot"
```

### 2. Entra IDに直接作成（クラウドオンリー）

```powershell
# ユーザー作成＋グループ追加を一括実行
.\execution\phase2-setup\New-EntraUsersFromCsv.ps1 `
  -CsvPath templates\sample_users_entra.csv `
  -LicenseGroupName "EXO-License-Pilot"
```
