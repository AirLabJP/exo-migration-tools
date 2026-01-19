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

### 構成オプション

#### オプション1: 単一DC構成（シンプル）

```powershell
# Step 1: Windows Server + AD DSの自動構築
.\Setup-LabEnvironment.ps1
```

#### オプション2: 2台DC構成（レプリケーション検証用）

```powershell
# Step 1: Hyper-V上で2台のVMを作成
.\Setup-ADDSReplication.ps1 -IsoPath "D:\ISO\Windows_Server_2022.iso"

# Step 2: DC01でドメイン構築
# （Hyper-VマネージャーでDC01に接続後）
.\Setup-LabEnvironment.ps1

# Step 3: DC02でドメイン参加（自動化）
# DC01のIPアドレスを確認後（DC01で: ipconfig）
$dc01Cred = Get-Credential -UserName "LAB\Administrator" -Message "DC01の管理者資格情報"
.\Setup-DC02DomainJoin.ps1 -Dc01IPAddress "192.168.1.10" -Dc01AdminCredential $dc01Cred

# ※ レプリケーションは自動で開始されます
```

#### オプション3: 3台構成（AD 2台 + Entra Connect専用 1台）★推奨★

本番相当の検証環境。EXOメールボックス作成までの全フローを検証できます。

```
【構成図】

  ┌─────────────────────────────────────────────────────────────┐
  │  Hyper-V ホスト（Windows 10/11 Pro または Windows Server）   │
  │                                                             │
  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
  │  │ VM: DC01    │  │ VM: DC02    │  │ VM: AADC01          │  │
  │  │ AD DS      │◄─►│ AD DS      │  │ Entra ID Connect   │  │
  │  │ (PDC)       │  │ (レプリカ)  │  │ (同期専用)          │  │
  │  │ lab.local   │  │ lab.local   │  │ lab.local参加       │  │
  │  └─────────────┘  └─────────────┘  └──────────┬──────────┘  │
  └───────────────────────────────────────────────┼─────────────┘
                                                  │ 同期
                                                  ▼
                                      ┌───────────────────────┐
                                      │ Microsoft Entra ID    │
                                      │ (試用版テナント)       │
                                      │ *.onmicrosoft.com     │
                                      └───────────┬───────────┘
                                                  │
                                                  ▼
                                      ┌───────────────────────┐
                                      │ Exchange Online       │
                                      │ メールボックス作成     │
                                      └───────────────────────┘
```

**VMスペック目安**:
| VM | vCPU | RAM | ディスク | 用途 |
|----|------|-----|----------|------|
| DC01 | 2 | 4GB | 60GB | AD DS (PDC) |
| DC02 | 2 | 4GB | 60GB | AD DS (レプリカ) |
| AADC01 | 2 | 4GB | 60GB | Entra ID Connect |

**ホストマシン要件**: 16GB以上のRAM推奨

##### Step 1: Hyper-V VMの作成

```powershell
# Hyper-Vホストで実行
# 3台のVMを作成（ISO指定）
$isoPath = "D:\ISO\Windows_Server_2022_Evaluation.iso"

# DC01用VM作成
New-VM -Name "DC01" -MemoryStartupBytes 4GB -NewVHDPath "D:\VMs\DC01.vhdx" -NewVHDSizeBytes 60GB -Generation 2
Set-VMDvdDrive -VMName "DC01" -Path $isoPath
Start-VM -Name "DC01"

# DC02用VM作成
New-VM -Name "DC02" -MemoryStartupBytes 4GB -NewVHDPath "D:\VMs\DC02.vhdx" -NewVHDSizeBytes 60GB -Generation 2
Set-VMDvdDrive -VMName "DC02" -Path $isoPath
Start-VM -Name "DC02"

# AADC01用VM作成
New-VM -Name "AADC01" -MemoryStartupBytes 4GB -NewVHDPath "D:\VMs\AADC01.vhdx" -NewVHDSizeBytes 60GB -Generation 2
Set-VMDvdDrive -VMName "AADC01" -Path $isoPath
Start-VM -Name "AADC01"
```

##### Step 2: DC01でドメイン構築

```powershell
# DC01のVMコンソールで実行
.\Setup-LabEnvironment.ps1

# 再起動後、IPアドレスを確認
ipconfig
# → 例: 192.168.1.10
```

##### Step 3: DC02のドメイン参加

```powershell
# DC02のVMコンソールで実行
$dc01Cred = Get-Credential -UserName "LAB\Administrator" -Message "DC01の管理者資格情報"
.\Setup-DC02DomainJoin.ps1 -Dc01IPAddress "192.168.1.10" -Dc01AdminCredential $dc01Cred
```

##### Step 4: AADC01のドメイン参加 + Entra ID Connect

```powershell
# AADC01のVMコンソールで実行

# 1. DNSをDC01に向ける
$adapter = Get-NetAdapter | Where-Object Status -eq "Up"
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses "192.168.1.10"

# 2. ドメイン参加
$dc01Cred = Get-Credential -UserName "LAB\Administrator" -Message "DC01の管理者資格情報"
Add-Computer -DomainName "lab.local" -Credential $dc01Cred -Restart

# --- 再起動後 ---

# 3. Entra ID Connect インストール
$password = ConvertTo-SecureString "YourGlobalAdminPassword" -AsPlainText -Force
.\Setup-EntraIDConnect.ps1 `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -GlobalAdminUPN "admin@yourtenant.onmicrosoft.com" `
    -GlobalAdminPassword $password `
    -SyncMode "PasswordHashSync"
```

##### Step 5: テストユーザー作成 → 同期 → メールボックス確認

```powershell
# DC01またはAADC01で実行

# 1. ADにテストユーザー作成（CSVベース）
.\execution\phase2-setup\New-ADUsersFromCsv.ps1 `
  -CsvPath templates\sample_users_ad.csv `
  -TargetOU "OU=Users,DC=lab,DC=local" `
  -SetMailAttributes

# 2. Entra ID Connect 差分同期
Start-ADSyncSyncCycle -PolicyType Delta

# 3. 同期状況確認
Get-ADSyncConnectorRunStatus

# 4. Entra IDでユーザー確認
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUser -Filter "onPremisesSyncEnabled eq true" | Select DisplayName,UserPrincipalName

# 5. ライセンスグループにユーザー追加（CSVから）
.\execution\phase2-setup\Add-UsersToLicenseGroup.ps1 `
  -CsvPath .\ad_user_creation\*\results.csv `
  -GroupName "EXO-License-Pilot"

# 6. EXOメールボックス作成を待機（数分〜数十分）
Connect-ExchangeOnline
Get-Mailbox -ResultSize 10 | Sort-Object WhenCreated -Descending
```

##### Entra ID試用版テナントの取得方法

1. [Microsoft 365管理センター](https://admin.microsoft.com)にアクセス
2. 新規アカウント作成 または 既存テナントで試用版を追加
3. **Microsoft 365 E3/E5 試用版**（30日無料）を有効化
   - Exchange Onlineライセンスが含まれる
4. または**Entra ID Premium P1/P2 試用版**を追加
   - グループベースライセンスに必要

**実行内容**:
- AD DS役割のインストール
- ドメインコントローラーの昇格（`lab.local`）
- テストユーザー・グループの作成
- DNS設定
- レプリケーション設定（2台構成の場合）

**所要時間**: 
- 単一DC: 約10〜15分（再起動含む）
- 2台DC: 約30〜40分（VM作成 + インストール + 設定）

**レプリケーションについて**:
- `Install-ADDSDomainController`を実行すると、**自動的にレプリケーションが開始されます**
- 手動で開始する必要はありません
- レプリケーション完了まで数分〜数十分かかります
- 完了確認: `repadmin /showrepl` または `dcdiag /test:replications`

### Step 2: Entra ID Connectの構築（オプション）

```powershell
$password = ConvertTo-SecureString "YourPassword" -AsPlainText -Force
.\Setup-EntraIDConnect.ps1 `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -GlobalAdminUPN "admin@tenant.onmicrosoft.com" `
    -GlobalAdminPassword $password `
    -SyncMode "PasswordHashSync"
```

**前提条件**:
- AD DSドメインに参加済み
- Entra ID（Azure AD）テナントが準備済み
- グローバル管理者アカウントの資格情報

**注意**: インストール後、GUIウィザードで詳細設定が必要です。

### Step 3: メールサーバー環境の起動

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

## スクリプト一覧

| スクリプト | 用途 | 実行場所 |
|---|---|---|
| `Setup-LabEnvironment.ps1` | 単一DC + AD DS構築 | Windows Server VM（DC01） |
| `Setup-ADDSReplication.ps1` | 2台DC構成のVM作成 | Hyper-V親ホスト |
| `Setup-DC02DomainJoin.ps1` | DC02のドメイン参加（自動化） | Windows Server VM（DC02） |
| `Setup-EntraIDConnect.ps1` | Entra ID Connect構築 | AD DS参加済みサーバー |
| `Send-TestEmail.ps1` | 検証用メール送信（Thunderbird代替） | 任意のWindows端末 |
| `Test-MailHeader.ps1` | メールヘッダー解析（CSV出力） | 任意のWindows端末 |

## 検証ツール

### メール送信テスト（Thunderbird代替）

```powershell
# 内部宛（Courier IMAP）
.\Send-TestEmail.ps1 -To "testuser02@lab.local" -Subject "内部宛テスト"

# Exchange Online宛
.\Send-TestEmail.ps1 -To "user@exo-tenant.onmicrosoft.com" -Subject "EXO宛テスト"

# 外部宛
.\Send-TestEmail.ps1 -To "your-email@gmail.com" -Subject "外部宛テスト"
```

### メールヘッダー解析

```powershell
# .emlファイルから解析
.\Test-MailHeader.ps1 -HeaderPath "C:\mail.eml"

# CSV形式で出力（デフォルト）
# → mail_header_analysis_YYYYMMDD_HHMMSS.csv
# → mail_header_analysis_YYYYMMDD_HHMMSS_hops.csv

# JSON形式で出力
.\Test-MailHeader.ps1 -HeaderPath "mail.eml" -OutFormat JSON
```

**解析項目**:
- 送信経路（Receivedヘッダー、ホップ数）
- SPF/DKIM/DMARC認証結果
- ループ検出
- 送信元・宛先情報
- メッセージID

## 参考

- [実践ガイド](../docs/ExchangeOnline移行プロジェクト実践ガイド.md)
- [要件定義書](../docs/ExchangeOnline移行プロジェクト要件定義書（案）.md)
