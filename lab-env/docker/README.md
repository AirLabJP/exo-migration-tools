# EXO移行検証環境 Docker構成

## 概要

顧客環境（Postfix + Courier IMAP）を Docker で再現した検証環境です。
Dovecot ではなく **Courier IMAP** を使用して、顧客環境との互換性を確保しています。

## コンテナ構成

| コンテナ | ホスト名 | ポート | 役割 |
|---|---|---|---|
| courier-imap | courier-imap.lab.local | 143, 993 | メールボックスサーバー（Courier IMAP） |
| postfix-hub | postfix-hub.lab.local | 25, 587 | 内部SMTPハブ（MUA送信受付） |
| dmz-aws | dmz-aws.lab.local | 2525 | AWS DMZ SMTP（外部受口） |
| dmz-internal | dmz-internal.lab.local | 2526 | 内部DMZ SMTP（EXOフォールバック用） |

## メールフロー

### 現行環境（EXO移行前）

```
【内部送信】
Thunderbird → postfix-hub:587 → courier-imap（Maildir配送）

【外部送信】
Thunderbird → postfix-hub:587 → dmz-aws:25 → インターネット

【外部受信】
インターネット → dmz-aws:2525 → postfix-hub:25 → courier-imap
```

### EXO移行後

```
【EXOからの配送（移行済みユーザー）】
Outlook → Exchange Online → 外部/内部

【EXOからの配送（未移行ユーザー宛 = Internal Relay）】
Exchange Online → dmz-internal:2526 → courier-imap

【外部からの配送（移行済みドメイン宛）】
インターネット → dmz-aws:2525 → Exchange Online

【外部からの配送（未移行ドメイン宛）】
インターネット → dmz-aws:2525 → postfix-hub:25 → courier-imap
```

## クイックスタート

### 起動

```bash
cd lab-env/docker
docker-compose up -d --build
```

### 状態確認

```bash
docker-compose ps
docker-compose logs -f
```

### 停止

```bash
docker-compose down
```

### 完全クリーンアップ

```bash
docker-compose down -v
docker volume prune -f
```

## テストユーザー

起動時に自動作成されるユーザー:

| メールアドレス | パスワード | 用途 |
|---|---|---|
| user1@test.example.co.jp | password123 | 一般ユーザー |
| user2@test.example.co.jp | password123 | 一般ユーザー |
| user3@test.example.co.jp | password123 | 一般ユーザー |
| admin@test.example.co.jp | adminpass123 | 管理者 |
| pilot01@test.example.co.jp | pilot123 | パイロットユーザー |
| pilot02@test.example.co.jp | pilot123 | パイロットユーザー |
| pilot03@test.example.co.jp | pilot123 | パイロットユーザー |
| pilot04@test.example.co.jp | pilot123 | パイロットユーザー |
| pilot05@test.example.co.jp | pilot123 | パイロットユーザー |
| test-ml@test.example.co.jp | mlpass123 | メーリングリスト用 |

**注**: 同じユーザーが example.co.jp、sub.example.co.jp でも利用可能

### ユーザー追加

```bash
# 個別ユーザー追加
docker exec -it exo-lab-courier-imap /scripts/add_user.sh newuser@test.example.co.jp newpassword
```

## クライアント接続設定

### Thunderbird（IMAP + SMTP）

| 項目 | 設定値 |
|---|---|
| メールアドレス | user1@test.example.co.jp |
| 受信サーバー（IMAP） | localhost |
| 受信ポート | 143 |
| 送信サーバー（SMTP） | localhost |
| 送信ポート | 25 または 587 |
| 接続の保護 | なし（検証環境） |
| 認証方式 | 通常のパスワード |
| ユーザー名 | user1@test.example.co.jp |
| パスワード | password123 |

## EXO移行シミュレーション

### Step 1: 現行環境でのメール送受信確認

```bash
# コンテナ内からテストメール送信
docker exec -it exo-lab-postfix-hub bash -c 'echo "Test from postfix-hub" | mail -s "Test Mail" user1@test.example.co.jp'

# ログ確認
docker exec -it exo-lab-courier-imap tail -20 /var/log/supervisor/courier-imap.log
```

### Step 2: dmz-aws の transport 変更（EXO移行）

```bash
# dmz-awsコンテナに入る
docker exec -it exo-lab-dmz-aws bash

# transportファイルを編集
vi /etc/postfix/transport

# 移行済みドメインをEXOへルーティング変更:
# test.example.co.jp      smtp:[postfix-hub]:25
# ↓
# test.example.co.jp      smtp:[tenant.mail.protection.outlook.com]:25

# 設定反映
postmap /etc/postfix/transport
postfix reload
```

または、切替スクリプトを使用:

```bash
docker exec -it exo-lab-dmz-aws /scripts/switch_to_exo.sh test.example.co.jp tenant.mail.protection.outlook.com
```

### Step 3: 切り戻し

```bash
docker exec -it exo-lab-dmz-aws /scripts/rollback.sh
```

## ログ確認

### 各コンテナのメールログ

```bash
# Courier IMAP
docker exec -it exo-lab-courier-imap tail -f /var/log/supervisor/courier-imap.log

# Postfix Hub
docker exec -it exo-lab-postfix-hub tail -f /var/log/mail.log

# DMZ AWS
docker exec -it exo-lab-dmz-aws tail -f /var/log/mail.log

# DMZ Internal
docker exec -it exo-lab-dmz-internal tail -f /var/log/mail.log
```

### メールキュー確認

```bash
docker exec -it exo-lab-postfix-hub mailq
docker exec -it exo-lab-dmz-aws mailq
```

## 設定ファイル

### postfix-hub

| ファイル | 内容 |
|---|---|
| main.cf | メイン設定（relayhost、transport_maps等） |
| master.cf | サービス定義（smtp、submission） |
| transport | 宛先別ルーティング（内部→courier-imap） |
| virtual | バーチャルエイリアス、メーリングリスト |

### dmz-aws

| ファイル | 内容 |
|---|---|
| main.cf | メイン設定（relay_domains等） |
| transport | **EXO移行時に変更** |
| transport.bak | 切り戻し用バックアップ |

### dmz-internal

| ファイル | 内容 |
|---|---|
| main.cf | メイン設定（EXO用設定） |
| transport | Courier IMAP へのルーティング |
| header_checks | ループ防止（X-EXO-Loop-Marker検出） |

### courier-imap

| ファイル | 内容 |
|---|---|
| imapd | IMAP デーモン設定 |
| imapd-ssl | IMAPS 設定 |
| authdaemonrc | 認証デーモン設定（userdb使用） |
| /etc/courier/userdb | ユーザーデータベース |

## トラブルシューティング

### コンテナが起動しない

```bash
# ログ確認
docker-compose logs courier-imap
docker-compose logs postfix-hub

# 再ビルド
docker-compose down -v
docker-compose up -d --build
```

### IMAP認証失敗

```bash
# userdb確認
docker exec -it exo-lab-courier-imap cat /etc/courier/userdb

# userdb再生成
docker exec -it exo-lab-courier-imap /scripts/create_users.sh
docker exec -it exo-lab-courier-imap makeuserdb
```

### メールが配送されない

```bash
# キュー確認
docker exec -it exo-lab-postfix-hub mailq

# ログ確認
docker exec -it exo-lab-postfix-hub tail -50 /var/log/mail.log

# 設定確認
docker exec -it exo-lab-postfix-hub postconf -n
```

### ポート競合

```bash
# 使用中のポート確認
netstat -an | findstr :143
netstat -an | findstr :25

# docker-compose.yml のポートを変更
```

## ネットワーク構成

```
Docker Network: exo-lab-network (172.28.0.0/16)

┌─────────────────┐     ┌─────────────────┐
│ courier-imap    │     │ dmz-internal    │
│ (IMAP:143,993)  │◀────│ (SMTP:25)       │
└────────▲────────┘     └─────────────────┘
         │                      ▲
         │                      │ EXOフォールバック
┌────────┴────────┐             │
│ postfix-hub     │     ┌───────┴─────────┐
│ (SMTP:25,587)   │     │ Exchange Online │
└────────▲────────┘     │ (クラウド)      │
         │              └─────────────────┘
┌────────┴────────┐
│ dmz-aws         │◀──── 外部受信
│ (SMTP:25)       │
└─────────────────┘
```

## 関連ドキュメント

- [検証環境構築手順書](../検証環境構築手順書.md)
- [lab-env README](../README.md)
