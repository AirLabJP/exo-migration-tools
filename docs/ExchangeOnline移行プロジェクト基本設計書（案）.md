---
created: 2026-01-19
tags:
  - permanent
  - tech-cloud
  - tech-backend
---

# Exchange Online 移行プロジェクト 基本設計書（案）

## 概要

本書は、○○株式会社様におけるメールシステムのExchange Online移行に関する基本設計を記述する。
要件定義書（案）に基づき、システム構成・メールフロー・移行手順の詳細を定義する。

---

## 1. 設計方針

### 1.1 基本方針

| # | 方針 | 詳細 |
|---|---|---|
| 1 | **MX変更なし** | FireEye継続利用、DNS設定変更を最小化 |
| 2 | **段階的移行** | パイロット1ドメイン→評価→本格展開 |
| 3 | **ダウンタイム最小化** | transport設定変更のみで切替、計画停止なし |
| 4 | **メールロス防止** | Internal Relay + フォールバック経路で未移行ユーザーを救済 |
| 5 | **ルーティング制御** | AWS DMZ SMTPのtransport設定でドメイン単位制御 |

### 1.2 設計上の前提条件

| # | 前提条件 | 備考 |
|---|---|---|
| 1 | Active Directoryスキーマ拡張済み | Exchange属性（mail, proxyAddresses等）が利用可能 |
| 2 | Entra ID Connectで同期構成済み | ユーザー＋セキュリティグループ同期 |
| 3 | Exchange Online環境存在 | 現状未使用、EWSのみオン |
| 4 | ライセンス調達済み | Microsoft 365 E3/E5等、Exchange Online含む |

---

## 2. システム構成

### 2.1 移行後の論理構成

```
                          【外部】
                             │
                             ▼ MX
                    ┌────────────────┐
                    │ FireEye        │ ← 受信セキュリティ（継続）
                    │ (設定変更なし) │
                    └───────┬────────┘
                            │
                            ▼
                    ┌────────────────┐
                    │ AWS DMZ SMTP   │ ← transport設定で振り分け
                    │ (Postfix)      │
                    └───────┬────────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
          ▼ 移行対象ドメイン ▼ 未移行ドメイン   ▼ 例外
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │ Exchange     │  │ Courier IMAP │  │ 外部転送     │
   │ Online       │  │ (既存)       │  │ (ブロック)   │
   └──────┬───────┘  └──────────────┘  └──────────────┘
          │
          │ Internal Relay（メールボックスなし宛先）
          ▼
   ┌──────────────┐
   │ 内部DMZ SMTP │ ← フォールバック経路
   │ (オンプレ)   │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │ Courier IMAP │
   │ (未移行ユーザー)│
   └──────────────┘
```

### 2.2 コンポーネント一覧

| # | コンポーネント | 役割 | 変更内容 |
|---|---|---|---|
| 1 | FireEye | 受信セキュリティ（MX） | **変更なし** |
| 2 | AWS DMZ SMTP | メール振り分け | transport設定追加 |
| 3 | Exchange Online | 移行後メールボックス | Accepted Domain、コネクタ設定 |
| 4 | 内部DMZ SMTP | フォールバック中継 | EXOからの受信許可 |
| 5 | Courier IMAP | 未移行ユーザーメールボックス | **変更なし** |
| 6 | 送信セキュリティサービス | 送信セキュリティ（添付URL化） | EXO連携設定（導入時） |
| 7 | Active Directory | ID管理 | スキーマ拡張、メール属性投入 |
| 8 | Entra ID Connect | 同期 | **変更なし**（同期対象属性追加） |

---

## 3. メールフロー設計

### 3.1 送信フロー（6パターン）

#### パターン1: EXOユーザー → EXOユーザー（内部）

```
Outlook → Exchange Online → Exchange Online（宛先メールボックス）
```

- **経路**: EXO内部配送
- **セキュリティ**: 内部メールのため外部経路に出さない

#### パターン2: EXOユーザー → 未移行ユーザー（Internal Relay）

```
Outlook → Exchange Online → [Outbound Connector: To-OnPrem-DMZ-Fallback]
         → 内部DMZ SMTP → Courier IMAP
```

- **トリガー**: Accepted Domain = InternalRelay、EXOにメールボックスなし
- **Transport Rule**: 内部ドメイン宛はフォールバック経路を使用

#### パターン3: EXOユーザー → 外部（添付URL化ありの場合）

```
Outlook → Exchange Online → [Outbound Connector: To-MailSecurity-Service]
         → 送信セキュリティサービス → インターネット
```

- **トリガー**: 宛先が外部ドメイン
- **Transport Rule**: 外部宛はセキュリティサービス経由
- **備考**: 送信セキュリティサービス未導入の場合はEXOから直接送信

#### パターン4: 未移行ユーザー → EXOユーザー

```
Thunderbird → Postfix（SMTPハブ）→ AWS DMZ SMTP → Exchange Online
```

- **経路**: 既存の送信経路、AWS DMZ SMTPでEXO向けにルーティング

#### パターン5: 未移行ユーザー → 未移行ユーザー

```
Thunderbird → Postfix（SMTPハブ）→ Courier IMAP
```

- **経路**: 既存のまま（変更なし）

#### パターン6: 未移行ユーザー → 外部

```
Thunderbird → Postfix（SMTPハブ）→ 現行GWサーバー → AWS DMZ SMTP → インターネット
```

- **経路**: 既存のまま（変更なし）
- **備考**: 現行AWS上のGuardianWallサーバー版を継続利用

### 3.2 受信フロー

#### 全ての外部受信

```
インターネット → FireEye（MX）→ AWS DMZ SMTP
  │
  ├─ 移行対象ドメイン宛 → Exchange Online
  │     │
  │     └─ メールボックスなし → [Internal Relay] → 内部DMZ SMTP → Courier IMAP
  │
  └─ 未移行ドメイン宛 → Courier IMAP（既存のまま）
```

### 3.3 メールフローマトリクス

| # | 送信元 | 宛先 | 経路 | 備考 |
|---|---|---|---|---|
| 1 | EXO | EXO | EXO内部 | |
| 2 | EXO | 未移行 | EXO → 内部DMZ → Courier | Internal Relay |
| 3 | EXO | 外部 | EXO → セキュリティサービス → Internet | 添付URL化（導入時） |
| 4 | 未移行 | EXO | Postfix → AWS DMZ → EXO | |
| 5 | 未移行 | 未移行 | Postfix → Courier | 既存のまま |
| 6 | 未移行 | 外部 | Postfix → 現行GW → AWS DMZ | 既存のまま |
| 7 | 外部 | EXO | FireEye → AWS DMZ → EXO | |
| 8 | 外部 | 未移行 | FireEye → AWS DMZ → Courier | 既存のまま |

---

## 4. Exchange Online 設計

### 4.1 Accepted Domain

| # | ドメイン | Type | 備考 |
|---|---|---|---|
| 1 | （パイロットドメイン） | **InternalRelay** | 移行中：未移行ユーザーをフォールバック |
| 2 | （その他ドメイン） | 未設定 or InternalRelay | Phase 2以降で順次追加 |

※ 全ユーザー移行完了後、`Authoritative` に変更

**InternalRelayの動作**:
- EXOにメールボックスがある宛先 → メールボックスに配送
- EXOにメールボックスがない宛先 → Outbound Connectorで外部転送

### 4.2 Connector設計

#### Inbound Connector: From-AWS-DMZ-SMTP

| 項目 | 設定値 |
|---|---|
| 名前 | From-AWS-DMZ-SMTP |
| 種類 | Partner |
| 送信元IP | （AWS DMZ SMTPのIP）※要確認 |
| TLS | 必須 |
| 用途 | 内部からの受信を許可 |

#### Outbound Connector: To-MailSecurity-Service（送信セキュリティサービス導入時）

| 項目 | 設定値 |
|---|---|
| 名前 | To-MailSecurity-Service（例: To-GuardianWall-Cloud） |
| 種類 | Partner |
| SmartHost | （セキュリティサービスのスマートホスト）※要確認 |
| TLS | 必須 |
| 用途 | 外部宛の添付URL化 |
| 適用条件 | Transport Ruleで外部宛を指定 |
| 備考 | 送信セキュリティサービス未導入の場合は不要 |

#### Outbound Connector: To-OnPrem-DMZ-Fallback

| 項目 | 設定値 |
|---|---|
| 名前 | To-OnPrem-DMZ-Fallback |
| 種類 | Partner |
| SmartHost | （内部DMZ SMTPのFQDN）※要確認 |
| TLS | 任意（内部のため） |
| 用途 | 未移行ユーザーへのフォールバック |
| 適用条件 | Transport Ruleで内部ドメイン宛を指定 |

### 4.3 Transport Rule設計

#### ルール1: 外部宛はセキュリティサービス経由（導入時）

| 項目 | 設定値 |
|---|---|
| 名前 | Route-External-Via-MailSecurity |
| 条件 | 宛先が組織外 |
| アクション | To-MailSecurity-Service経由でルーティング |
| 優先度 | 1 |
| 備考 | 送信セキュリティサービス未導入の場合はこのルール不要 |

#### ルール2: 未移行ユーザー宛はフォールバック経由

| 項目 | 設定値 |
|---|---|
| 名前 | Route-Internal-Unmigrated-Via-Fallback |
| 条件 | 宛先が内部ドメイン AND EXOにメールボックスなし |
| アクション | To-OnPrem-DMZ-Fallback経由でルーティング |
| 優先度 | 2 |
| 備考 | Internal Relay動作と連動 |

#### ルール3: 外部転送ブロック

| 項目 | 設定値 |
|---|---|
| 名前 | Block-External-Forwarding |
| 条件 | 自動転送メッセージ AND 宛先が組織外 |
| アクション | 拒否（NDR返送） |
| 優先度 | 0（最優先） |

### 4.4 ループ防止設計

| # | 対策 | 実装方法 |
|---|---|---|
| 1 | ヘッダマーキング | Transport Ruleでカスタムヘッダを付与 |
| 2 | ヘッダチェック | 内部DMZ SMTPでヘッダ存在時に拒否 |
| 3 | 最大ホップ数 | Postfix側で制限（hop_count_limit） |

---

## 5. Active Directory 設計

### 5.1 スキーマ拡張

Exchange Server Setup.exeの`/PrepareSchema`および`/PrepareAD`を実行。

**拡張される属性**:
- `mail`
- `proxyAddresses`
- `msExchRecipientDisplayType`
- `msExchRecipientTypeDetails`
- その他Exchange関連属性

### 5.2 メール属性投入

| 属性 | 形式 | 例 |
|---|---|---|
| mail | SMTP形式 | user1@example.co.jp |
| proxyAddresses | SMTP:プライマリ, smtp:エイリアス | SMTP:user1@example.co.jp, smtp:alias@example.co.jp |

**投入ルール**:
- お客様提供のCSVに基づく
- 1ユーザー1プライマリアドレス + 0〜n個のエイリアス
- UPN（AD）とメールアドレス（mail属性）は異なる可能性あり

### 5.3 ライセンスグループ運用

| フェーズ | グループ種別 | 理由 |
|---|---|---|
| 移行中 | **静的グループ** | CSVで指定したユーザーのみライセンス付与 |
| 移行完了後 | 動的グループ | ドメインベースの規則で自動化 |

**移行中の運用**:
1. 静的セキュリティグループ `EXO-License-Pilot` を作成
2. グループにExchange Onlineライセンスを割り当て（グループベースライセンス）
3. 移行対象ユーザーをCSVでグループに追加
4. 自動的にライセンス付与 → メールボックス作成

---

## 6. Postfix / DMZ SMTP 設計

### 6.1 AWS DMZ SMTP transport設定

`/etc/postfix/transport` に移行対象ドメインのルーティングを追加。

**設定例**:
```
# === EXO Migration Routing ===
# 移行対象ドメインはExchange Onlineにルーティング
example.co.jp    smtp:[tenant.mail.protection.outlook.com]
# === End of EXO Migration Routing ===
```

**適用手順**:
```bash
postmap /etc/postfix/transport
postfix reload
```

### 6.2 内部DMZ SMTP設定

EXOからの接続を許可し、Courier IMAPへ中継。

**mynetworks追加**:
```
# EXO Outbound Connector からの接続許可
# Microsoft 365 の送信IPレンジを許可
```

**transport設定**:
```
# 内部ドメインはCourier IMAPへ
example.co.jp    smtp:[courier-imap.internal:25]
```

### 6.3 ループ防止（header_checks）

```
/^X-EXO-Loop-Marker:/    REJECT Mail loop detected
```

---

## 7. 移行手順概要

### 7.1 事前準備（Phase 1-2）

| # | 作業 | 担当 | 成果物 |
|---|---|---|---|
| 1 | 現行環境棚卸し | ベンダー | 棚卸しレポート |
| 2 | 紛れメールボックス検出 | ベンダー | 紛れレポート |
| 3 | ADスキーマ拡張 | ベンダー | 完了報告 |
| 4 | 移行対象ユーザー一覧提供 | お客様 | CSV |
| 5 | AD属性投入（テスト） | ベンダー | 完了報告 |
| 6 | EXOコネクタ設定 | ベンダー | 完了報告 |
| 7 | テストドメインで検証 | ベンダー | 検証レポート |

### 7.2 パイロット切替（Phase 4）

| # | 作業 | コマンド/手順 | 確認ポイント |
|---|---|---|---|
| 1 | AD属性投入（本番） | Set-ADMailAddressesFromCsv.ps1 | proxyAddresses確認 |
| 2 | Entra ID同期 | Start-ADSyncSyncCycle | 同期完了確認 |
| 3 | ライセンスグループ追加 | Add-UsersToLicenseGroup.ps1 | メールボックス作成確認 |
| 4 | Accepted Domain変更 | Set-AcceptedDomainType.ps1 | InternalRelay確認 |
| 5 | AWS DMZ transport変更 | Set-DmzSmtpRouting.sh | postmap/reload |
| 6 | メールフロー検証 | Test-MailFlowMatrix.ps1 | 6パターン疎通 |
| 7 | 監視（30分〜1時間） | Message Trace | NDR/遅延確認 |

### 7.3 切り戻し手順

| # | 作業 | コマンド/手順 |
|---|---|---|
| 1 | AWS DMZ transport復元 | Restore-DmzSmtpRouting.sh |
| 2 | Accepted Domain復元 | Restore-AcceptedDomainType.ps1 |
| 3 | コネクタ削除（必要時） | Undo-EXOConnectors.ps1 |

---

## 8. 監視・運用設計

### 8.1 切替当日の監視ポイント

| # | 監視対象 | 確認内容 | 閾値 |
|---|---|---|---|
| 1 | EXO Message Trace | NDR件数 | 0件が理想 |
| 2 | EXO Message Trace | 配送遅延 | 5分以内 |
| 3 | AWS DMZ SMTPログ | transport振り分け | 想定通りの振り分け |
| 4 | 内部DMZ SMTPログ | フォールバック利用 | 未移行ユーザー宛のみ |

### 8.2 定常運用

| # | 作業 | 頻度 | 担当 |
|---|---|---|---|
| 1 | メールボックス容量監視 | 週次 | 運用 |
| 2 | 紛れメールボックスチェック | 月次 | 運用 |
| 3 | ライセンス使用状況確認 | 月次 | 運用 |
| 4 | コネクタ動作確認 | 月次 | 運用 |

---

## 9. セキュリティ設計

### 9.1 認証・暗号化

| # | 項目 | 設定 |
|---|---|---|
| 1 | Inbound Connector認証 | 送信元IP制限 + TLS必須 |
| 2 | Outbound Connector認証 | TLS必須 |
| 3 | ユーザー認証 | Entra ID認証（SSO） |

### 9.2 アクセス制御

| # | 項目 | 設定 |
|---|---|---|
| 1 | 外部転送 | トランスポートルールでブロック |
| 2 | OWAアクセス | 許可（ポリシー検討） |
| 3 | モバイルアクセス | Phase 2以降で検討 |

---

## 10. 制約・注意事項

### 10.1 既知の制約

| # | 制約 | 影響 | 対策 |
|---|---|---|---|
| 1 | 過去メール移行なし | ユーザー対応が必要 | 手順書提供 |
| 2 | 移行中の二重管理 | 運用負荷 | フェーズを短く |
| 3 | Internal Relay設定中のNDR | 設定ミスでNDR | テスト徹底 |

### 10.2 パラメータ一覧（お客様確認待ち）

| # | パラメータ | 用途 | 状況 |
|---|---|---|---|
| 1 | パイロットドメイン | Accepted Domain、transport | 選定済み・未共有 |
| 2 | 移行対象ユーザー一覧 | AD属性投入 | 未受領 |
| 3 | 送信セキュリティスマートホスト | Outbound Connector | 未確認（サービス選定後） |
| 4 | 内部DMZ SMTP FQDN/IP | Outbound Connector | 未確認 |
| 5 | AWS DMZ SMTP IP | Inbound Connector | 未確認 |
| 6 | ライセンスグループ名 | グループベースライセンス | 未決定 |

---

## 付録

### A. スクリプト一覧

| # | スクリプト | 用途 |
|---|---|---|
| 1 | Set-ADMailAddressesFromCsv.ps1 | ADメール属性投入 |
| 2 | Add-UsersToLicenseGroup.ps1 | ライセンスグループ追加 |
| 3 | New-EXOConnectors.ps1 | EXOコネクタ作成 |
| 4 | Set-AcceptedDomainType.ps1 | Accepted Domain変更 |
| 5 | Set-DmzSmtpRouting.sh | AWS DMZ transport変更 |
| 6 | Test-MailFlowMatrix.ps1 | メールフロー検証 |
| 7 | Restore-*.ps1 / .sh | 各種切り戻し |

### B. 検証項目チェックリスト

| # | 検証項目 | 期待結果 | 結果 |
|---|---|---|---|
| 1 | EXO→EXO | 配送成功 | □ |
| 2 | EXO→未移行 | Courier IMAPに配送 | □ |
| 3 | EXO→外部 | セキュリティサービス経由で配送 | □ |
| 4 | 未移行→EXO | EXOに配送 | □ |
| 5 | 外部→EXO | EXOに配送 | □ |
| 6 | 外部転送ブロック | 拒否 | □ |

---

## 改訂履歴

| 版 | 日付 | 変更内容 | 作成者 |
|---|---|---|---|
| 0.1 | 2026/01/19 | 初版作成（案） | |
| | | | |
