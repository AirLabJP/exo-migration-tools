# Execution Scripts - 実行スクリプト群

Exchange Online移行の各フェーズで使用する実行スクリプト群です。

## フェーズ構成

```
execution/
├── phase1-preparation/   # Phase1: 事前準備
├── phase2-setup/         # Phase2: EXO箱作り
├── phase3-routing/       # Phase3: ルーティング変更 ★本番切替
├── phase4-validation/    # Phase4: 検証
└── rollback/             # 切り戻し
```

---

## Phase1: 事前準備

### Test-Prerequisites.ps1

**目的**: 移行の各フェーズ実行前に、必要な前提条件を確認します。

```powershell
# 全チェック
.\phase1-preparation\Test-Prerequisites.ps1 -All

# AD関連のみ（スキーマ拡張前）
.\phase1-preparation\Test-Prerequisites.ps1 -CheckAD

# EXO + Graph（コネクタ作成前）
.\phase1-preparation\Test-Prerequisites.ps1 -CheckEXO -CheckGraph
```

**チェック項目**:
- AD: ドメイン接続、Schema/Enterprise/Domain Admins権限、Schema Master確認
- EXO: 接続状態、権限確認
- Graph: 接続状態、必要スコープの同意確認
- Network: 必要なエンドポイントへの疎通

### Invoke-ExchangeSchemaPrep.ps1

**目的**: Exchange用のADスキーマ拡張とAD準備を安全に実行します。

```powershell
# Schema Master DCで実行
.\phase1-preparation\Invoke-ExchangeSchemaPrep.ps1 `
  -SetupExePath D:\ExchangeSetup\Setup.exe `
  -OrganizationName "Contoso"
```

**前提条件**:
- Schema Master DCで実行
- Schema Admins + Enterprise Admins 権限
- Exchange Setup メディアが必要

---

## Phase2: EXO箱作り

### Set-ADMailAddressesFromCsv.ps1

**目的**: CSVファイルからADユーザーのmail/proxyAddresses属性を一括設定します。

```powershell
# WhatIfで確認（推奨）
.\phase2-setup\Set-ADMailAddressesFromCsv.ps1 -CsvPath mail_addresses.csv -WhatIfMode

# 本番実行
.\phase2-setup\Set-ADMailAddressesFromCsv.ps1 -CsvPath mail_addresses.csv
```

**入力CSV形式**:
```csv
UserPrincipalName,SamAccountName,PrimarySmtpAddress,Aliases
user1@example.local,user1,user1@example.co.jp,alias1@example.co.jp;alias2@example.co.jp
```

### New-EXOConnectors.ps1

**目的**: EXO移行に必要な3つのコネクタを作成します。

```powershell
# WhatIfで確認
.\phase2-setup\New-EXOConnectors.ps1 `
  -GwcSmartHost "gwc.example.com" `
  -OnPremDmzSmtpHost "dmz-smtp.internal.example.co.jp" `
  -AwsDmzSmtpIP "203.0.113.10" `
  -TargetDomainsFile domains.txt `
  -WhatIfMode

# 本番実行
.\phase2-setup\New-EXOConnectors.ps1 `
  -GwcSmartHost "gwc.example.com" `
  -OnPremDmzSmtpHost "dmz-smtp.internal.example.co.jp" `
  -AwsDmzSmtpIP "203.0.113.10" `
  -TargetDomainsFile domains.txt
```

**作成されるコネクタ**:
| 種類 | 名前 | 用途 |
|---|---|---|
| Outbound | To-GuardianWall-Cloud | 外部宛の添付URL化 |
| Outbound | To-OnPrem-DMZ-Fallback | 未移行ユーザーへのフォールバック |
| Inbound | From-AWS-DMZ-SMTP | AWS DMZ SMTPからの受信許可 |

### Add-UsersToLicenseGroup.ps1

**目的**: CSVで指定したユーザーをライセンス付与用グループに追加します。

**重要な方針**:
- 移行中は**静的グループ**を使用し、CSVで指定したユーザーのみにライセンスを付与
- 動的グループは全ドメイン移行完了後に切り替え → 意図しないメールボックス作成を防止

```powershell
# WhatIfで確認
.\phase2-setup\Add-UsersToLicenseGroup.ps1 `
  -CsvPath migration_users.csv `
  -GroupName "EXO-License-Pilot" `
  -WhatIfMode

# 本番実行
.\phase2-setup\Add-UsersToLicenseGroup.ps1 `
  -CsvPath migration_users.csv `
  -GroupName "EXO-License-Pilot"

# グループから削除
.\phase2-setup\Add-UsersToLicenseGroup.ps1 `
  -CsvPath migration_users.csv `
  -GroupName "EXO-License-Pilot" `
  -RemoveMode
```

**入力CSV形式**:
```csv
UserPrincipalName
user1@example.local
user2@example.local
```

**注意**: グループベースライセンスには Entra ID Premium P1 以上が必要です。

---

## Phase3: ルーティング変更 ★本番切替

**注意**: このフェーズの操作はメールフローに直接影響します。必ずドライランで確認してから本番実行してください。

### New-TestMailboxes.ps1

**目的**: テストドメインでのメールフロー検証用にテストメールボックスを作成します。

```powershell
# WhatIfで確認
.\phase3-routing\New-TestMailboxes.ps1 `
  -TestDomain "test.contoso.co.jp" `
  -Count 3 `
  -WhatIfMode

# 本番実行（ライセンス自動選択）
.\phase3-routing\New-TestMailboxes.ps1 `
  -TestDomain "test.contoso.co.jp" `
  -Count 3

# ライセンス指定
.\phase3-routing\New-TestMailboxes.ps1 `
  -TestDomain "test.contoso.co.jp" `
  -SkuId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

**出力**:
- `test_users.csv` - 作成したユーザー一覧（パスワード含む）
- `cleanup_test_users.ps1` - テストユーザー削除用スクリプト

**注意**: ライセンス付与後、メールボックス作成には数分〜数十分かかります。

### Set-AcceptedDomainType.ps1

**目的**: EXOのAccepted Domainタイプを一括変更します。

```powershell
# InternalRelayに変更（移行開始時）
.\phase3-routing\Set-AcceptedDomainType.ps1 `
  -DomainsFile domains.txt `
  -DomainType InternalRelay `
  -WhatIfMode

# Authoritativeに変更（移行完了時）
.\phase3-routing\Set-AcceptedDomainType.ps1 `
  -DomainsFile domains.txt `
  -DomainType Authoritative
```

**タイプの意味**:
- `Authoritative`: EXOでメールボックスがない宛先はNDR
- `InternalRelay`: EXOでメールボックスがない宛先はOutbound Connectorで転送

### Set-DmzSmtpRouting.sh

**目的**: AWS DMZ SMTP（または内部DMZ SMTP）のルーティング設定を変更します。

```bash
# ドライラン
sudo bash phase3-routing/Set-DmzSmtpRouting.sh \
  -d domains.txt \
  -m tenant.mail.protection.outlook.com \
  -n

# 本番実行
sudo bash phase3-routing/Set-DmzSmtpRouting.sh \
  -d domains.txt \
  -m tenant.mail.protection.outlook.com
```

**変更内容**: `/etc/postfix/transport` に移行対象ドメインのルーティングを追加

```
example.co.jp    smtp:[tenant.mail.protection.outlook.com]
```

### Set-PostfixRouting.sh

**目的**: メインPostfixのtransport設定を変更します（必要な場合のみ）。

```bash
# ドライラン
sudo bash phase3-routing/Set-PostfixRouting.sh \
  -d domains.txt \
  -m tenant.mail.protection.outlook.com \
  -n

# 本番実行
sudo bash phase3-routing/Set-PostfixRouting.sh \
  -d domains.txt \
  -m tenant.mail.protection.outlook.com
```

---

## Phase4: 検証

### Test-MailFlowMatrix.ps1

**目的**: 移行後のメールフローが想定どおりに動作しているかを検証します。

```powershell
# テストケースファイルで検証
.\phase4-validation\Test-MailFlowMatrix.ps1 -TestCasesFile test_cases.csv

# 過去48時間を検索
.\phase4-validation\Test-MailFlowMatrix.ps1 -TestCasesFile test_cases.csv -LookbackHours 48
```

**テストケースCSV形式**:
```csv
TestID,From,To,Subject,ExpectedPath,ExpectedResult
TC001,user1@contoso.co.jp,user2@contoso.co.jp,内部宛テスト,EXO_INTERNAL,Delivered
TC002,user1@contoso.co.jp,external@gmail.com,外部宛テスト,EXO_GWC_INTERNET,Delivered
```

---

## Rollback: 切り戻し

緊急時または移行ロールバック時に使用します。

### 全体ロールバック手順

```powershell
# 1. EXO Accepted Domain を Authoritative に戻す
.\rollback\Restore-AcceptedDomainType.ps1 -DomainsFile domains.txt

# 2. EXO コネクタを削除
.\rollback\Undo-EXOConnectors.ps1
```

```bash
# 3. DMZ SMTP ルーティングを復元
sudo bash rollback/Restore-DmzSmtpRouting.sh --latest

# 4. Postfix ルーティングを復元（変更していた場合）
sudo bash rollback/Restore-PostfixRouting.sh --latest
```

### Undo-EXOConnectors.ps1

**目的**: New-EXOConnectors.ps1 で作成したコネクタを削除します。

```powershell
# WhatIfで確認
.\rollback\Undo-EXOConnectors.ps1 -WhatIfMode

# 本番実行
.\rollback\Undo-EXOConnectors.ps1
```

### Restore-AcceptedDomainType.ps1

**目的**: Accepted Domainを元のタイプ（通常はAuthoritative）に戻します。

```powershell
# ドメインファイルから復元
.\rollback\Restore-AcceptedDomainType.ps1 -DomainsFile domains.txt

# バックアップファイルから復元
.\rollback\Restore-AcceptedDomainType.ps1 `
  -BackupFile .\accepted_domain_change\20260117_120000\target_domains_before.json
```

### Restore-PostfixRouting.sh / Restore-DmzSmtpRouting.sh

**目的**: Postfix/DMZ SMTPのtransport設定を復元します。

```bash
# 最新のバックアップから復元
sudo bash rollback/Restore-PostfixRouting.sh --latest
sudo bash rollback/Restore-DmzSmtpRouting.sh --latest

# 特定のバックアップから復元
sudo bash rollback/Restore-PostfixRouting.sh /etc/postfix/transport.backup.20260117_120000
```

---

## 注意事項

- **WhatIfMode**: 破壊的操作は必ず WhatIf/ドライラン で確認してから本番実行
- **バックアップ**: 各スクリプトは自動でバックアップを作成しますが、事前に手動バックアップも推奨
- **順序**: Phase1 → Phase2 → Phase3 → Phase4 の順序で実行
- **切り戻し**: 問題発生時は rollback/ のスクリプトで速やかに復元
