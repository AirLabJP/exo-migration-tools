# メールフロー再検証：DMZ と Courier IMAP 間の経路

## 目的

現行資料では **DMZ SMTP → Courier IMAP 直** と記載している箇所があるが、実環境では **DMZ と Courier の間に中継 MTA（Postfix 等）が存在する** 可能性が高い。本ドキュメントはその疑義を整理し、棚卸し時の確認事項を定義する。

---

## 1. 疑義の根拠

### 1.1 Courier IMAP の役割

- Courier IMAP は **IMAP サーバー（メールボックス）** であり、SMTP の 25 番で直接受信する構成は少ない。
- 一般的な構成では **中継 MTA（Postfix 等）が SMTP で受信し、local 配送（maildir 等）で Courier のメールボックスに届ける**。
- したがって「DMZ SMTP → Courier IMAP」と書くより、**「DMZ SMTP → 中継 Postfix（内部）→ Courier IMAP（local 配送）」** の方が実態に近い可能性が高い。

### 1.2 資料上の「直」記載箇所

| 資料 | 箇所 | 現状の記載 | 疑義 |
|------|------|------------|------|
| 要件定義書 2.3 | 受信フロー | FireEye → AWS DMZ SMTP → Courier IMAP | AWS DMZ の**次のホップ**が Courier か、中継 MTA か不明 |
| 要件定義書 2.3 | フォールバック | 内部DMZ SMTP → Courier IMAP | 内部 DMZ の**次のホップ**が Courier か、中継 MTA か不明 |
| 基本設計書 2.1 | 論理構成図 | 内部DMZ SMTP → Courier IMAP（矢印1本） | 中継の有無が図にない |
| 基本設計書 3.2 | 受信フロー | 未移行ドメイン宛 → Courier IMAP（既存のまま） | AWS DMZ から Courier への**経路の詳細**が省略 |
| 基本設計書 3.3 | マトリクス #8 | FireEye → AWS DMZ → Courier | 同上 |
| 基本設計書 6.2 | 内部DMZ SMTP設定 | 「Courier IMAPへ中継」、transport で `courier-imap.internal:25` | Courier が 25 で受ける前提。中継 Postfix の FQDN の可能性あり |
| 実践ガイド | 受信フロー図 | AWS DMZ → Courier / 内部DMZ → Courier | 同上 |

---

## 2. 想定される実構成（棚卸しで確認）

### 2.1 受信：外部 → 未移行ユーザー

**案A（資料上の記載）**  
`FireEye → AWS DMZ SMTP → Courier IMAP`

**案B（中継 Postfix あり）**  
`FireEye → AWS DMZ SMTP → 内部中継 Postfix（SMTPハブ等）→ Courier IMAP（local 配送）`

- AWS DMZ の `transport` の**次のホップ**が「Courier のホスト」なのか「内部の別 MTA（Postfix）」なのかを棚卸しで確認する。

### 2.2 フォールバック：EXO → 未移行ユーザー

**案A（資料上の記載）**  
`EXO → 内部DMZ SMTP → Courier IMAP`

**案B（中継 Postfix あり）**  
`EXO → 内部DMZ SMTP → 内部中継 Postfix → Courier IMAP（local 配送）`

- 内部 DMZ SMTP の `transport` の**次のホップ**が Courier なのか、内部の別 MTA なのかを棚卸しで確認する。
- 基本設計書 6.2 の `courier-imap.internal:25` は、実態では **中継 Postfix の FQDN** である可能性がある。

### 2.3 送信：未移行 → 未移行（内部）

- 要件定義・基本設計では「Thunderbird → Postfix（SMTPハブ）→ Courier IMAP」とあり、**送信経路には既に Postfix（SMTPハブ）が明示**されている。
- 受信経路側に同じ「SMTPハブ」や別の中継が介在するかは、棚卸しで確認する。

---

## 3. 棚卸し時の確認事項

Phase 1 の現行環境棚卸しで、以下を**現地で確認**すること（お客様の事前説明のみに依存しない）。

### 3.1 AWS DMZ SMTP

| # | 確認項目 | 確認方法 | 記録先 |
|---|----------|----------|--------|
| 1 | `/etc/postfix/transport` の内容 | 未移行ドメイン宛の**次のホップ**（FQDN/IP）を記録 | 棚卸しレポート |
| 2 | 次のホップの役割 | そのホストが「Courier 本体」か「中継 MTA（Postfix 等）」か | 同上 |
| 3 | 中継 MTA の場合、そのホストの `transport` / `virtual` 等 | Courier（maildir）への配送方法 | 同上 |

### 3.2 内部 DMZ SMTP

| # | 確認項目 | 確認方法 | 記録先 |
|---|----------|----------|--------|
| 1 | `/etc/postfix/transport`（または同等）の内容 | 内部ドメイン宛の**次のホップ**を記録 | 棚卸しレポート |
| 2 | 次のホップが Courier 直か、中継 MTA か | 実機・設定確認 | 同上 |
| 3 | EXO からのフォールバック経路で使う場合、同じ経路でよいか | 設計との整合 | 同上 |

### 3.3 内部ネットワーク側（Postfix / その他 MTA）

| # | 確認項目 | 確認方法 | 記録先 |
|---|----------|----------|--------|
| 1 | 「SMTPハブ」「中継」として存在するホストの一覧 | 構成図・ヒアリング＋現地確認 | 棚卸しレポート |
| 2 | 各 MTA の `transport` / `virtual` / `local_recipient_maps` | Courier（maildir）への配送設定 | 同上 |
| 3 | DMZ からの受け入れ先 | DMZ の転送先と、内部 Postfix の `mynetworks` 等 | 同上 |

### 3.4 Courier IMAP サーバー

| # | 確認項目 | 確認方法 | 記録先 |
|---|----------|----------|--------|
| 1 | SMTP 25 で受信しているか、それとも local 配送のみか | リスニングポート・設定確認 | 棚卸しレポート |
| 2 | メールの届き方 | 同一ホストの Postfix → local か、他ホストから SMTP か | 同上 |

---

## 4. 設計・資料への反映方針

- 棚卸しで **「DMZ の次は中継 Postfix」「その Postfix が Courier に local 配送」** と判明した場合：
  - 基本設計書・要件定義書・実践ガイドの**受信フロー図・経路表**を「中継 Postfix あり」前提に更新する。
  - 内部 DMZ SMTP の設定例（6.2）で、`transport` の宛先を「中継 Postfix の FQDN」に合わせて修正する。
- 棚卸しで **「DMZ の次が Courier 直（Courier が 25 で受信）」** と判明した場合：
  - 現状の「DMZ → Courier 直」の記載をそのまま採用し、本ドキュメントは「検証済み」として参照のみ残す。

---

## 5. 関連ドキュメント

- [ExchangeOnline移行プロジェクト要件定義書（案）](ExchangeOnline移行プロジェクト要件定義書（案）.md) 2.3
- [ExchangeOnline移行プロジェクト基本設計書（案）](ExchangeOnline移行プロジェクト基本設計書（案）.md) 2.1, 3.2, 6.2
- [ExchangeOnline移行プロジェクト実践ガイド](ExchangeOnline移行プロジェクト実践ガイド.md) 受信フロー図
- [決め打ち前提・リスク管理表](決め打ち前提・リスク管理表.md)

---

## 改訂履歴

| 版 | 日付 | 変更内容 |
|----|------|----------|
| 0.1 | 2026-02-01 | 初版（DMZ–Courier 間の中継 Postfix 疑義の整理、棚卸し確認事項の追加） |
