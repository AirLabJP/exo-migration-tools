# 検証環境 Docker構成

顧客環境（Courier IMAP + Postfix）を再現したDocker環境。

## 構成図

```
                    【外部】
                       │
                       ▼ Port:2525
              ┌─────────────────┐
              │    dmz-aws      │ ← EXOルーティング変更対象
              │   (Postfix)     │
              └────────┬────────┘
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
    ┌──────────┐  ┌──────────┐  ┌──────────┐
    │postfix-hub│  │(EXO移行後)│  │dmz-internal│
    │Port:25,587│  │EXOへ直接  │  │Port:2526   │
    └─────┬────┘  └──────────┘  └─────┬────┘
          │                           │
          └───────────┬───────────────┘
                      ▼
              ┌─────────────────┐
              │  courier-imap   │ ← メールボックス
              │  Port:143,993   │
              └─────────────────┘
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

# 停止
docker-compose down
```

## テストユーザー

自動作成される初期ユーザー:

| ユーザー | パスワード | 用途 |
|---|---|---|
| user1@test.example.co.jp | password123 | 一般ユーザー |
| user2@test.example.co.jp | password123 | 一般ユーザー |
| user3@test.example.co.jp | password123 | 一般ユーザー |
| admin@test.example.co.jp | adminpass123 | 管理者 |
| pilot01〜05@test.example.co.jp | pilot123 | パイロットユーザー |

同じユーザーが `example.co.jp`、`sub.example.co.jp` でも作成される。

## ポート一覧

| コンテナ | ホストポート | 用途 |
|---|---|---|
| courier-imap | 143 | IMAP |
| courier-imap | 993 | IMAPS |
| postfix-hub | 25 | SMTP |
| postfix-hub | 587 | Submission |
| dmz-aws | 2525 | 外部SMTP受口 |
| dmz-internal | 2526 | 内部DMZ（EXOフォールバック） |

## EXO移行シミュレーション

### 1. 移行前（現行状態）

```bash
# dmz-awsのtransport確認
docker exec lab-dmz-aws cat /etc/postfix/transport
# → 全ドメインがpostfix-hub経由
```

### 2. EXOルーティング切替

```bash
# EXO向けルーティングに切替
docker exec lab-dmz-aws /scripts/switch_to_exo.sh
# → test.example.co.jpがEXOへルーティング
```

### 3. 切り戻し

```bash
# 元に戻す
docker exec lab-dmz-aws /scripts/rollback.sh
```

## Thunderbird設定

| 項目 | 設定値 |
|---|---|
| 受信サーバー | localhost:143 (IMAP) |
| 送信サーバー | localhost:25 or localhost:587 |
| 認証 | 通常のパスワード |
| 接続の保護 | なし |

## ユーザー追加

```bash
# コンテナ内でユーザー追加
docker exec lab-courier-imap /scripts/add_user.sh newuser@test.example.co.jp password123
```

## トラブルシューティング

### メールが届かない

```bash
# Postfixキュー確認
docker exec lab-postfix-hub mailq
docker exec lab-dmz-aws mailq

# ログ確認
docker exec lab-postfix-hub cat /var/log/mail.log
docker exec lab-dmz-aws cat /var/log/mail.log
```

### IMAP接続できない

```bash
# Courier IMAP状態確認
docker exec lab-courier-imap supervisorctl status

# userdb確認
docker exec lab-courier-imap cat /etc/courier/userdb
```

## クリーンアップ

```bash
# コンテナ・ボリューム完全削除
docker-compose down -v

# イメージも削除
docker-compose down -v --rmi all
```
