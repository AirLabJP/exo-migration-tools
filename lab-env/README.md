# Exchange Online移行 検証環境構築セット（Windows環境向け）

Windows Server（Hyper-V）上で動作する検証環境の自動構築セット。

## 構成

```
【Windows Server VM環境】
├─ Active Directory Domain Services (AD DS)
│  └─ 検証用ドメイン: lab.local
│
└─ Docker環境（メールサーバー）
   ├─ Postfix (SMTPハブ) - 顧客の内部SMTPハブを模擬
   ├─ Courier IMAP (Dovecot) - メールボックスサーバー
   ├─ DMZ SMTP (AWS側) - 外部SMTP中継
   └─ DMZ SMTP (オンプレ側) - 内部DMZ SMTP中継
```

## 前提条件

### Windows Server VM（Hyper-V）

- **OS**: Windows Server 2022 Standard（評価版180日無料）
- **スペック**: vCPU 2コア以上、RAM 4GB以上、ディスク 60GB以上
- **役割**: 
  - Hyper-V（親ホストの場合）
  - Containers（Docker用）
  - またはDocker Desktop for Windows

### Docker

Windows Server 2022では以下のいずれか：

```powershell
# オプション1: Docker Desktop for Windows
# https://www.docker.com/products/docker-desktop/ からダウンロード

# オプション2: Containers役割 + Docker Engine（Server Core向け）
Install-WindowsFeature -Name Containers
```

## クイックスタート

### Step 1: Windows Server + AD DSの自動構築

```powershell
# 管理者権限でPowerShellを起動

# スクリプト実行ポリシーを変更（初回のみ）
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# AD DS構築スクリプトを実行
.\Setup-LabEnvironment.ps1
```

**実行内容**:
- AD DS役割のインストール
- ドメインコントローラーの昇格（`lab.local`）
- テストユーザー・グループの作成
- DNS設定

**所要時間**: 約10〜15分（再起動含む）

### Step 2: メールサーバー環境の起動

```powershell
# lab-envフォルダに移動
cd lab-env

# Docker Composeで起動
docker-compose up -d

# 状態確認
docker-compose ps

# ログ確認
docker-compose logs -f
```

**起動されるコンテナ**:
- `lab-postfix` - SMTPハブ（内部送信）
- `lab-mailbox` - メールボックスサーバー（Dovecot）
- `lab-dmz-aws` - AWS DMZ SMTP（外部受口）
- `lab-dmz-onprem` - オンプレDMZ SMTP（フォールバック）

## 構成詳細

### ネットワーク構成

```
[Docker Network: lab-network]

  ┌──────────────────┐
  │ lab-postfix      │  Port: 25,587
  │ (SMTPハブ)       │
  └────────┬─────────┘
           │
    ┌──────┴──────┐
    │             │
    ▼             ▼
┌──────────┐  ┌──────────────┐
│ lab-     │  │ lab-dmz-aws  │
│ mailbox  │  │ Port: 2525   │
│ (Dovecot)│  │ (AWS側)      │
│ Port:143 │  └──────────────┘
└──────────┘
              ┌──────────────┐
              │ lab-dmz-     │
              │ onprem       │
              │ Port: 2526   │
              │ (オンプレ側) │
              └──────────────┘
```

### 検証用ドメイン・ユーザー

| 項目 | 値 |
|---|---|
| ドメイン | `lab.local` |
| NetBIOS名 | `LAB` |
| テストユーザー | `testuser01@lab.local` (パスワード: `P@ssw0rd123`) |
| 管理者 | `LAB\Administrator` |

## メールフローテスト

### テスト1: 内部メール送信

```powershell
# コンテナ内からメール送信テスト
docker exec -it lab-postfix bash

# SMTP経由でメール送信
echo "Test email" | mail -s "Test Subject" testuser01@lab.local
```

### テスト2: 外部宛メール送信

```powershell
# DMZ SMTP経由で外部宛送信
docker exec -it lab-dmz-aws bash

# 外部宛メール送信（Gmail等）
echo "Test email" | mail -s "Test Subject" your-email@gmail.com
```

### テスト3: メール受信確認

```powershell
# Dovecotコンテナでメール確認
docker exec -it lab-mailbox bash

# Maildir確認
ls -la /var/mail/lab.local/testuser01/new/
```

## トラブルシューティング

### Dockerが起動しない

```powershell
# Dockerサービスの状態確認
Get-Service *docker*

# Docker Desktopの場合、再起動
Restart-Service docker
```

### AD DS構築が失敗する

```powershell
# エラーログ確認
Get-EventLog -LogName System -Source "ActiveDirectory*" -Newest 10

# DNS設定確認
Get-DnsServerZone

# 再実行（ドメイン参加済みの場合は先に離脱）
# Remove-Computer -Force -Restart
```

### メールが届かない

```powershell
# コンテナ間のネットワーク確認
docker network inspect lab-network

# Postfixログ確認
docker logs lab-postfix

# Dovecotログ確認
docker logs lab-mailbox
```

## クリーンアップ

### メールサーバー環境の削除

```powershell
cd lab-env
docker-compose down -v
```

### AD DSの削除（ドメイン離脱）

```powershell
# 注意: これはドメインコントローラーを破棄します
Uninstall-ADDSDomainController -ForceRemoval -IgnoreLastDnsServerForZone
```

## 参考

- [実践ガイド](../docs/ExchangeOnline移行プロジェクト実践ガイド.md)
- [要件定義書](../docs/ExchangeOnline移行プロジェクト要件定義書（案）.md)
