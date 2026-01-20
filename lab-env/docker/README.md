# EXO移行検証環境 Docker構成

顧客環境（Courier IMAP + Postfix）を再現したDocker環境。

## 構成図

```
                                    【検証環境】
                                         │
    ┌────────────────────────────────────┼────────────────────────────────────┐
    │                                    │                                    │
    │  ┌─────────────────────────────────┴─────────────────────────────────┐ │
    │  │                    Docker Network (exo-lab-network)               │ │
    │  │                                                                    │ │
    │  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐           │ │
    │  │  │ postfix-hub │───▶│ courier-imap│◀───│ dmz-internal│           │ │
    │  │  │ (内部SMTP)  │    │ (IMAP)      │    │ (EXO fallback)│          │ │
    │  │  │ :25,:587    │    │ :143,:993   │    │ :2526       │           │ │
    │  │  └──────┬──────┘    └─────────────┘    └─────────────┘           │ │
    │  │         │                                                         │ │
    │  │         │ 外部送信                                                 │ │
    │  │         ▼                                                         │ │
    │  │  ┌─────────────┐                                                  │ │
    │  │  │ dmz-aws     │ ◀── 外部受信（FireEye経由を模擬）               │ │
    │  │  │ (外部受口)  │                                                  │ │
    │  │  │ :2525       │                                                  │ │
    │  │  └─────────────┘                                                  │ │
    │  │                                                                    │ │
    │  └────────────────────────────────────────────────────────────────────┘ │
    │                                                                         │
    └─────────────────────────────────────────────────────────────────────────┘
```

## クイックスタート

```bash
cd lab-env/docker

# ビルド＆起動
docker-compose up -d --build

# 状態確認
docker-compose ps

# ログ確認
docker-compose logs -f

# 個別コンテナのログ
docker-compose logs -f courier-imap

# 停止
docker-compose down

# 完全削除（ボリューム含む）
docker-compose down -v
```

## コンテナ一覧

| コンテナ | ポート | 役割 |
|---|---|---|
| courier-imap | 143, 993 | メールボックス（Courier IMAP） |
| postfix-hub | 25, 587 | 内部SMTPハブ（MUA送信受付） |
| dmz-aws | 2525 | AWS DMZ SMTP（外部受口） |
| dmz-internal | 2526 | 内部DMZ SMTP（EXOフォールバック） |

## テストユーザー

起動時に以下のユーザーが自動作成されます:

| ユーザー | パスワード | 用途 |
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

同じユーザーが以下のドメインでも利用可能:
- example.co.jp
- sub.example.co.jp

## メールクライアント設定

### Thunderbird

| 項目 | 設定値 |
|---|---|
| 受信サーバー（IMAP） | localhost:143 |
| 送信サーバー（SMTP） | localhost:25 または localhost:587 |
| 接続の保護 | なし |
| 認証方式 | 通常のパスワード |

### テストメール送信

```bash
# コンテナ内から送信
docker exec -it postfix-hub bash -c 'echo "Test message" | mail -s "Test" user1@test.example.co.jp'

# telnetで直接送信
telnet localhost 25
HELO test
MAIL FROM:<test@example.com>
RCPT TO:<user1@test.example.co.jp>
DATA
Subject: Test
Test message
.
QUIT
```

## EXO移行シミュレーション

### 1. 現行環境確認

```bash
# 内部メール送受信
docker exec -it postfix-hub bash -c 'echo "Internal test" | mail -s "Internal" user1@test.example.co.jp'

# ログ確認
docker-compose logs postfix-hub | tail -20
docker-compose logs courier-imap | tail -20
```

### 2. EXO移行（transport変更）

```bash
# dmz-awsのtransportファイルを編集
# 移行対象ドメインをEXOにルーティング
# （本番ではtenant.mail.protection.outlook.comを指定）

# transportファイル更新後
docker exec -it dmz-aws postmap /etc/postfix/transport
docker exec -it dmz-aws postfix reload
```

### 3. 切り戻し

```bash
# バックアップから復元
docker exec -it dmz-aws bash -c "cp /etc/postfix/transport.bak /etc/postfix/transport && postmap /etc/postfix/transport && postfix reload"
```

## ユーザー追加

```bash
# Courier IMAPにユーザー追加
docker exec -it courier-imap /scripts/add_user.sh newuser@test.example.co.jp password123
```

## トラブルシューティング

### ポートが使用中

```bash
# 使用中のポートを確認
netstat -an | findstr :25
netstat -an | findstr :143

# docker-compose.ymlのポートマッピングを変更
```

### 認証失敗

```bash
# userdb確認
docker exec -it courier-imap cat /etc/courier/userdb

# userdb再構築
docker exec -it courier-imap makeuserdb
```

### メールが届かない

```bash
# Postfixキュー確認
docker exec -it postfix-hub mailq
docker exec -it dmz-aws mailq

# ログ確認
docker exec -it postfix-hub tail -50 /var/log/mail.log
```

## クリーンアップ

```bash
# コンテナ停止・削除
docker-compose down

# ボリュームも削除
docker-compose down -v

# イメージも削除
docker-compose down --rmi all -v
```
