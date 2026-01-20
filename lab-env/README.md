# Exchange Online移行 検証環境構築セット

## 概要

本検証環境は、Exchange Online移行プロジェクトの以下の目的で使用します:

1. **暗黙知の可視化**: 実際に環境を構築・運用し、現行環境の暗黙知を洗い出す
2. **スクリプト・手順の妥当性検証**: 本番投入前にスクリプトと手順書の動作を確認
3. **課題の早期発見**: 移行作業における潜在的な問題を事前に特定

## 構成図

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  検証用 Windows クライアント端末（物理: 1台）                                 │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ GUI アプリケーション                                                  │   │
│  │ - Thunderbird（社内所定配置先より取得）                               │   │
│  │ - Outlook（社内所定配置先より取得）                                   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Hyper-V（Windows Server 2022 × 3台）                                 │   │
│  │                                                                       │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │   │
│  │  │ VM1: DC01    │  │ VM2: DC02    │  │ VM3: AADC01  │               │   │
│  │  │ AD DS        │  │ AD DS        │  │ Entra Connect│               │   │
│  │  │ (PDC)        │  │ (Replica)    │  │              │               │   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘               │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Docker Desktop（Courier IMAP + Postfix構成）                         │   │
│  │                                                                       │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │   │
│  │  │ courier-imap│  │ postfix-hub │  │ dmz-aws     │  │ dmz-internal│ │   │
│  │  │ (IMAP)      │  │ (内部SMTP)  │  │ (外部受口)  │  │ (EXO fallback)│ │   │
│  │  │ :143,:993   │  │ :25,:587    │  │ :2525       │  │ :2526       │ │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘ │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│                           ↕ Entra ID Connect 同期                           │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Microsoft クラウド（試験版テナント）                                   │   │
│  │                                                                       │   │
│  │  ┌──────────────────┐  ┌──────────────────┐                          │   │
│  │  │ Entra ID         │  │ Exchange Online  │                          │   │
│  │  └──────────────────┘  └──────────────────┘                          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## ディレクトリ構成

```
lab-env/
├── README.md                        # このファイル
├── 検証環境構築手順書.md              # 詳細な構築手順
├── docker/                          # Docker関連ファイル
│   ├── docker-compose.yml           # メイン構成ファイル
│   ├── README.md                    # Docker環境の詳細説明
│   ├── courier-imap/                # Courier IMAP（メールボックス）
│   │   ├── Dockerfile
│   │   ├── imapd
│   │   ├── imapd-ssl
│   │   ├── authdaemonrc
│   │   ├── supervisord.conf
│   │   └── scripts/
│   │       ├── entrypoint.sh
│   │       ├── create_users.sh      # テストユーザー一括作成
│   │       └── add_user.sh          # 個別ユーザー追加
│   ├── postfix-hub/                 # 内部SMTPハブ
│   │   ├── Dockerfile
│   │   ├── main.cf
│   │   ├── master.cf
│   │   ├── transport
│   │   ├── virtual
│   │   ├── supervisord.conf
│   │   └── scripts/
│   │       └── entrypoint.sh
│   ├── dmz-postfix-aws/             # AWS DMZ SMTP（外部受口）
│   │   ├── Dockerfile
│   │   ├── main.cf
│   │   ├── master.cf
│   │   ├── transport                # ← EXO移行時に変更
│   │   ├── transport.bak            # 切り戻し用バックアップ
│   │   ├── supervisord.conf
│   │   └── scripts/
│   │       └── entrypoint.sh
│   └── dmz-postfix-internal/        # 内部DMZ SMTP（EXOフォールバック）
│       ├── Dockerfile
│       ├── main.cf
│       ├── master.cf
│       ├── transport
│       ├── header_checks            # ループ防止設定
│       ├── supervisord.conf
│       └── scripts/
│           └── entrypoint.sh
└── scripts/                         # 検証スクリプト
    └── (今後追加)
```

## クイックスタート

### 1. Docker環境起動

```bash
cd lab-env/docker
docker-compose up -d --build
docker-compose ps
```

### 2. テストメール送受信確認

```bash
# Thunderbirdで接続
# 受信サーバー: localhost:143 (IMAP)
# 送信サーバー: localhost:25 (SMTP)
# ユーザー: user1@test.example.co.jp / password123
```

### 3. Hyper-V環境構築

詳細は「検証環境構築手順書.md」を参照。

## テストユーザー

Docker起動時に以下のユーザーが自動作成されます:

| ユーザー | パスワード | 用途 |
|---|---|---|
| user1@test.example.co.jp | password123 | 一般ユーザー |
| user2@test.example.co.jp | password123 | 一般ユーザー |
| user3@test.example.co.jp | password123 | 一般ユーザー |
| admin@test.example.co.jp | adminpass123 | 管理者 |
| pilot01〜05@test.example.co.jp | pilot123 | パイロットユーザー |

同じユーザーが以下のドメインでも利用可能:
- example.co.jp
- sub.example.co.jp

## メールフロー

### 現行環境（EXO移行前）

```
【送信】
Thunderbird → postfix-hub(:25) → courier-imap (内部配送)
                              → dmz-aws → インターネット (外部送信)

【受信】
インターネット → dmz-aws(:2525) → postfix-hub → courier-imap
```

### EXO移行後

```
【送信】
Outlook → Exchange Online → dmz-internal(:2526) → courier-imap (未移行ユーザー宛)
                         → インターネット (外部宛)

【受信】
インターネット → dmz-aws → Exchange Online (移行済みユーザー宛)
                        → postfix-hub → courier-imap (未移行ユーザー宛)
```

## EXO移行シミュレーション

### Phase 1: 現行環境確認

```bash
# 内部メール送受信確認
docker exec -it postfix-hub bash -c 'echo "Test" | mail -s "Test" user1@test.example.co.jp'

# ログ確認
docker-compose logs courier-imap | tail -20
```

### Phase 2: EXO移行（transport変更）

```bash
# dmz-awsのtransportファイルを編集
vi lab-env/docker/dmz-postfix-aws/transport

# 変更内容:
# test.example.co.jp      smtp:[postfix-hub]:25
# ↓
# test.example.co.jp      smtp:[tenant.mail.protection.outlook.com]:25

# 設定反映
docker exec -it dmz-aws postmap /etc/postfix/transport
docker exec -it dmz-aws postfix reload
```

### Phase 3: 切り戻し

```bash
docker exec -it dmz-aws bash -c "cp /etc/postfix/transport.bak /etc/postfix/transport && postmap /etc/postfix/transport && postfix reload"
```

## 検証シナリオ

| Phase | 内容 | 確認項目 |
|---|---|---|
| 1 | 現行環境再現 | Dockerコンテナ起動、メール送受信 |
| 2 | Microsoft環境構築 | ADスキーマ拡張、Entra ID Connect同期 |
| 3 | AD属性投入 | Set-ADMailAddressesFromCsv.ps1実行 |
| 4 | EXOコネクタ設定 | New-EXOConnectors.ps1、Transport Rule設定 |
| 5 | ルーティング切替 | dmz-aws transport変更、メールフロー検証 |
| 6 | 切り戻し検証 | 復元スクリプト実行、正常性確認 |

## 関連ドキュメント

- [検証環境構築手順書](./検証環境構築手順書.md) - Hyper-V、AD、Docker構築の詳細手順
- [Docker README](./docker/README.md) - Docker環境の詳細説明
- [実践ガイド](../docs/ExchangeOnline移行プロジェクト実践ガイド.md)
- [基本設計書](../docs/ExchangeOnline移行プロジェクト基本設計書（案）.md)

## 注意事項

- **Courier IMAP**: 顧客環境のCourier IMAPを再現（Dovecotではない）
- **GWサーバー除外**: 検証環境ではGuardianWallサーバーを構築しない
- **リレー設定**: 現行環境のリレー構成を再現（GW除外）
- **テストドメイン**: test.example.co.jp等の架空ドメインを使用

## トラブルシューティング

### Docker起動失敗

```bash
docker-compose logs
docker-compose down -v
docker-compose up -d --build
```

### 認証失敗

```bash
docker exec -it courier-imap cat /etc/courier/userdb
docker exec -it courier-imap makeuserdb
```

### メールが届かない

```bash
docker exec -it postfix-hub mailq
docker exec -it postfix-hub tail -50 /var/log/mail.log
```
