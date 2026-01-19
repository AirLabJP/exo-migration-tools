# 環境設定ファイル

## 概要

このフォルダには環境固有の設定値を集約するファイルを配置します。
各スクリプトはコマンドラインパラメータで値を指定できますが、
設定ファイルに集約することで以下のメリットがあります：

- **事故防止**: コピペミスが減る
- **レビュー容易**: PM/顧客が確認しやすい
- **再現性**: 同じ設定で再実行できる

---

## 使い方

### 1. サンプルをコピー

```powershell
# 本番環境用
cp sample_environment.yaml production.yaml

# 検証環境用
cp sample_environment.yaml lab.yaml
```

### 2. 環境に合わせて編集

```yaml
# production.yaml
microsoft365:
  tenant_id: "実際のテナントID"
  tenant_domain: "contoso.onmicrosoft.com"

target_domains:
  - "example.co.jp"

smtp_servers:
  aws_dmz:
    ip_address: "実際のIPアドレス"
```

### 3. .gitignore に追加

```
# 機密情報を含む設定ファイルはコミットしない
config/production.yaml
config/*.local.yaml
```

---

## ファイル一覧

| ファイル | 用途 | Gitコミット |
|----------|------|-------------|
| `sample_environment.yaml` | テンプレート | ○ コミット可 |
| `production.yaml` | 本番環境設定 | ✕ コミット不可 |
| `lab.yaml` | 検証環境設定 | △ 環境による |

---

## 設定ファイルの読み込み（PowerShell）

```powershell
# YAMLを読み込む（powershell-yaml モジュールが必要）
Install-Module -Name powershell-yaml -Scope CurrentUser

$config = Get-Content -Path "config/production.yaml" -Raw | ConvertFrom-Yaml

# 値を使用
$tenantId = $config.microsoft365.tenant_id
$targetDomains = $config.target_domains
$gwcHost = $config.mail_security.guardianwall.smart_host
```

---

## 注意事項

- **パスワードは含めない**: パスワードは実行時に入力
- **IPアドレスは本番値を確認**: ファイアウォール設定と整合性を取る
- **ドメイン名は正確に**: typoがメールロスの原因になる
