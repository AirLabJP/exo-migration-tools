# EXO移行スクリプト検証環境

顧客環境（Postfix + Courier IMAP）を模擬したDocker環境。

## テスト仕様書

| ファイル | 用途 | テストケース数 |
|---|---|---|
| 検証環境_結合総合試験仕様書.xlsx | 検証環境（lab-env）での結合・総合試験 | 約45件 |
| 本番環境テストドメイン_結合総合試験仕様書.xlsx | 本番環境にテストドメインを追加しての試験 | 約55件 |
| 本番環境_最終試験仕様書.xlsx | パイロット切替前後の最終確認 | 約30件 |

### テスト仕様書の構成

各仕様書は以下のシートで構成:

- **サマリー**: 結果集計・承認欄
- **テストケース**: 詳細なテスト項目

### テストカテゴリ

| カテゴリ | 内容 |
|---|---|
| メールフロー | 6送信パターン + 2受信パターン |
| EXOコネクタ | Inbound/Outbound各コネクタの動作確認 |
| Transport Rule | ルーティングルール・ブロックルールの確認 |
| ループ防止 | ヘッダマーキング・ホップ制限 |
| AD/Entra連携 | 属性投入・同期・ライセンス付与 |
| SMTP設定 | transport設定・中継確認 |
| セキュリティ | TLS・SPF/DKIM/DMARC |
| クライアント | Outlook/OWA/モバイル接続 |
| 異常系 | NDR・サイズ制限・障害時動作 |
| 切り戻し | 各復元スクリプトの動作確認 |
| 負荷試験 | 同時送信・連続送信 |

## 構成

```
┌─────────────────────────────────────────────────┐
│  Docker Network: exo-test-network               │
│                                                 │
│  ┌─────────────────┐    ┌─────────────────┐     │
│  │ dmz-smtp        │    │ mailserver      │     │
│  │ (Postfix)       │───▶│ (Postfix+Dovecot)│    │
│  │ Port: 2525      │    │ Port: 25,143    │     │
│  └─────────────────┘    └─────────────────┘     │
│                                                 │
│  模擬対象:                                       │
│  - AWS DMZ SMTP      - 内部メールサーバー        │
│  - 外部受口          - Courier IMAP (Dovecot)   │
└─────────────────────────────────────────────────┘
```

## クイックスタート

```bash
cd test-env

# 起動
docker-compose up -d

# 状態確認
docker-compose ps

# ログ確認
docker-compose logs -f

# 停止
docker-compose down
```

## スクリプトテスト

### 1. コンテナに入る

```bash
# メインサーバー（Postfix + Dovecot）
docker exec -it exo-test-mailserver bash

# DMZ SMTP
docker exec -it exo-test-dmz bash
```

### 2. スクリプトをコンテナにコピー

```bash
# メインサーバー
docker cp ../inventory/collect_postfix.sh exo-test-mailserver:/tmp/
docker cp ../inventory/collect_courier_imap.sh exo-test-mailserver:/tmp/

# DMZ
docker cp ../inventory/collect_smtp_dmz.sh exo-test-dmz:/tmp/
```

### 3. スクリプト実行

```bash
# メインサーバー内で実行
docker exec -it exo-test-mailserver bash -c "chmod +x /tmp/*.sh && /tmp/collect_postfix.sh /tmp/inventory"
docker exec -it exo-test-mailserver bash -c "/tmp/collect_courier_imap.sh /tmp/inventory"

# DMZ内で実行
docker exec -it exo-test-dmz bash -c "chmod +x /tmp/*.sh && /tmp/collect_smtp_dmz.sh /tmp/inventory"
```

### 4. 結果回収

```bash
# ローカルにコピー
docker cp exo-test-mailserver:/tmp/inventory ./results_mailserver
docker cp exo-test-dmz:/tmp/inventory ./results_dmz

# 確認
ls -la ./results_mailserver/
ls -la ./results_dmz/
```

## 一括テストスクリプト

```bash
./run-test.sh
```

## テスト用ユーザー作成

docker-mailserverのsetup.shを使用:

```bash
# ユーザー追加
docker exec -it exo-test-mailserver setup email add user1@example.local password123
docker exec -it exo-test-mailserver setup email add user2@example.local password123
docker exec -it exo-test-mailserver setup email add admin@example.local password123

# 確認
docker exec -it exo-test-mailserver setup email list
```

## 模擬設定

| 項目 | 設定値 | 顧客環境との対応 |
|---|---|---|
| ドメイン | example.co.jp, example.com, sub.example.co.jp | 40ドメインの一部 |
| メッセージサイズ制限 | 10MB | 顧客Postfixと同じ |
| IMAP | Dovecot (Courier IMAP互換) | Courier IMAP |
| リレー構成 | DMZ → 内部 | AWS → 内部 |

## トラブルシューティング

### ポートが使用中

```bash
# 既存のメールサーバーがあれば停止
# または docker-compose.yml のポートを変更
```

### postconfが見つからない

docker-mailserverではpostfixがsupervisordで管理されている。
コンテナ内で以下で確認:

```bash
postconf -n
cat /etc/postfix/main.cf
```

### ログが出ない

```bash
docker-compose logs mailserver
docker-compose logs dmz-smtp
```

## クリーンアップ

```bash
# コンテナ停止・削除
docker-compose down -v

# 生成されたデータも削除
rm -rf maildata mailstate maillogs dmz-logs results_*
```
