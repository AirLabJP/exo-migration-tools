---
created: 2026-01-17
tags:
  - permanent
  - tutorial
  - tech-cloud
  - tech-devops
  - business-strategy
---

# Exchange Online移行プロジェクト実践ガイド

## 概要

Linux（Postfix/Courier IMAP）ベースのメールシステムからExchange Online（EXO）への移行において、事故を起こさないための設計思想と作業手順を体系化したガイド。40ドメイン中1ドメインを先行移行し、ハイブリッド並行稼働を実現するケースを想定。

---

## 前提条件・対象外

### 前提条件（Assumptions）

| # | 前提 |
|---|---|
| 1 | パイロット移行は1ドメインのみ |
| 2 | FireEyeは継続利用（設定変更なし）、**MXも変更しない（DNS変更なし）**。AWS DMZ SMTPのtransport設定でパイロットドメインをEXOへ振り分け |
| 3 | 添付ファイルURL化は送信セキュリティサービスで実現（導入時） |
| 4 | Active DirectoryとEntra ID Connectは構成済み |
| 5 | EXOライセンスは調達済み |
| 6 | 検証環境なし（本番テナントでテスト） |

### 対象外（Non-goals）

| # | 対象外項目 | 理由 |
|---|---|---|
| 1 | 過去メールの中央移行 | ユーザー任せ（手順書提供） |
| 2 | Thunderbirdアドレス帳の移行 | ユーザー任せ（GAL利用推奨） |
| 3 | Roundcubeの移行/廃止 | ほぼ未使用、スコープ外 |
| 4 | 統合アカウントシステムの改修 | 別案件 |
| 5 | 残り39ドメインの移行 | Phase 2以降 |
| 6 | 誤送信対策（DLP等） | Phase 2以降で検討 |

---

## プロジェクト背景

### スケジュール想定

| フェーズ | 期間 | 内容 |
|---|---|---|
| **導入PJ** | 5〜6月（2ヶ月） | パイロット1ドメインのEXO移行 |
| **ユーザーテスト** | 7〜9月（3ヶ月） | 実運用・課題抽出 |
| **稟議** | 10月 | 残り39ドメイン移行計画の承認 |
| **本格移行** | 11月〜 | 39ドメイン順次移行 |

### 制約条件

- **WBS 2ヶ月**でパイロット完了が求められる（タイト）
- 全ユーザーが一度に移行しきれない可能性
- メールボックスがEXOとCourier IMAPに分散する期間が発生

### 既存関係

- 運用担当2名が既に常駐中、評価良好
- お客様は導入後、同担当者に運用を引き継ぎたい意向

---

## 移行後メールフロー設計

### 設計方針

- **変更箇所を最小限に**（FireEyeは変更なし）
- **内部宛メールは外部向けセキュリティ経路（セキュリティサービス経由）に出さず、組織内配送として扱う**
- **AWS DMZ SMTPのtransport設定で制御**

### 用語定義

| 用語 | 範囲 |
|---|---|
| **内部** | 同一組織（Thunderbird/Postfix/Courier環境 + Exchange Online/Outlook） |
| **外部** | インターネット上の他組織 |

---

### 送信フロー①: 内部→外部（Thunderbird起点）

```
Thunderbird（現行ユーザー）
    │ SMTP
    ▼
Postfix（SMTPハブ）
    │
    ▼
現行GWサーバー（添付URL化）
    │
    ▼
AWS DMZ SMTP
    │
    ▼
インターネット → 外部宛先
```

### 送信フロー②: 内部→外部（Outlook起点）

```
Outlook（移行済みユーザー）
    │
    ▼
Exchange Online
    │
    │ Outbound Connector #1
    ▼
送信セキュリティサービス（添付URL化・導入時）
    │
    ▼
インターネット → 外部宛先
```

---

### 送信フロー③: 内部→内部（Thunderbird → 未移行ユーザー）

```
Thunderbird
    │ SMTP
    ▼
Postfix（SMTPハブ）
    │
    │ 未移行ドメイン宛
    ▼
Courier IMAP → 未移行ユーザーのメールボックス

※ 現行通り、変更なし
```

### 送信フロー④: 内部→内部（Thunderbird → 移行済みユーザー）

```
Thunderbird
    │ SMTP
    ▼
Postfix（SMTPハブ）
    │
    │ 移行済みドメイン宛
    ▼
AWS DMZ SMTP
    │
    │ transport設定
    ▼
Exchange Online（Inbound Connector）
    │
    ▼
移行済みユーザーのメールボックス
```

### 送信フロー⑤: 内部→内部（Outlook → 移行済みユーザー）

```
Outlook（移行済みユーザー）
    │
    ▼
Exchange Online
    │
    │ 内部配信
    ▼
移行済みユーザーのメールボックス

※ EXO内で完結、外部経路なし
```

### 送信フロー⑥: 内部→内部（Outlook → 未移行ユーザー）

```
Outlook（移行済みユーザー）
    │
    ▼
Exchange Online
    │
    │ Internal Relay（BOXなし）
    │ Outbound Connector #2
    ▼
内部DMZ SMTP
    │
    │ 40ドメイン転送設定
    ▼
Courier IMAP → 未移行ユーザーのメールボックス
```

---

### 受信フロー: 外部→内部

```
インターネット（外部送信者）
    │
    │ MX（変更なし）
    ▼
FireEye（変更なし - AWS DMZ SMTP向き）
    │
    ▼
AWS DMZ SMTP
    │
    ├─ 未移行ドメイン宛
    │       │
    │       ▼
    │   Postfix → Courier IMAP → 未移行ユーザー（現行通り）
    │
    └─ 移行済みドメイン宛
            │
            │ transport設定
            ▼
        Exchange Online
            │
       ┌────┴────┐
       │         │
       ▼         ▼
    BOXあり   BOXなし
       │         │
       ▼         │ Internal Relay
    EXO配信      │ Outbound Connector #2
       │         ▼
       ▼     内部DMZ SMTP
    移行済み      │
    ユーザー      ▼
             Courier IMAP → 未移行ユーザー
```

---

### フローまとめ

| # | 起点 | 宛先 | 経路 |
|---|---|---|---|
| ① | Thunderbird | 外部 | Postfix → 現行GW → AWS DMZ → インターネット |
| ② | Outlook | 外部 | EXO → セキュリティサービス → インターネット（導入時） |
| ③ | Thunderbird | 未移行ユーザー | Postfix → Courier（現行通り） |
| ④ | Thunderbird | 移行済みユーザー | Postfix → AWS DMZ → EXO |
| ⑤ | Outlook | 移行済みユーザー | EXO内完結 |
| ⑥ | Outlook | 未移行ユーザー | EXO → 内部DMZ → Courier |
| 受信 | 外部 | 内部 | FireEye → AWS DMZ → Postfix → EXO/Courier |

---

### 変更箇所まとめ

| コンポーネント | 変更 | 内容 |
|---|---|---|
| **Postfix（SMTPハブ）** | ✅ 変更 | 移行済みドメイン → AWS DMZ SMTP（現状Courier直送なら） |
| **AWS DMZ SMTP** | ✅ 変更 | transport設定（移行済みドメイン → EXO） |
| **内部DMZ SMTP** | ✅ 確認 | EXOからの受信許可、40ドメイン→Postfixへ中継（現行リレー設定） |
| FireEye | ❌ 変更なし | AWS DMZ SMTP向きのまま |
| Courier IMAP | ❌ 変更なし | — |

---

## EXOコネクタ設計

### コネクタ一覧（合計3本）

| # | 種類 | 名前 | 宛先 | 用途 |
|---|---|---|---|---|
| 1 | Outbound | To-MailSecurity-Service | セキュリティサービス | 外部宛の添付URL化（導入時） |
| 2 | Outbound | To-OnPrem-DMZ-Fallback | 内部DMZ SMTP | 未移行ユーザーへのフォールバック |
| 3 | Inbound | From-AWS-DMZ-SMTP | AWS DMZ SMTPから | 内部からの受信許可 |

### Outbound #1: GuardianWall Cloud向け

```powershell
New-OutboundConnector -Name "To-MailSecurity-Service" `
    -ConnectorType Partner `
    -SmartHosts "mailsecurity.example.com" `
    -TlsSettings EncryptionOnly `  # ※値はテナント/モジュール仕様に合わせて調整
    -UseMXRecord $false `
    -RecipientDomains "*" `
    -IsTransportRuleScoped $true  # トランスポートルールで外部宛のみ発動
```

> **注**: TlsSettingsの値（`EncryptionOnly`, `CertificateValidation`等）はテナントや接続先の仕様に合わせて調整。上記は例。

**連携するトランスポートルール**:

`-IsTransportRuleScoped $true` の場合、**ルール側でコネクタを指定**する必要がある。

```powershell
# 外部宛メールをセキュリティサービスコネクタ経由で送信
New-TransportRule -Name "Route External via MailSecurity" `
    -SentToScope NotInOrganization `
    -RouteMessageOutboundConnector "To-MailSecurity-Service" `
    -Enabled $true
```

| ルール条件 | 意味 |
|---|---|
| `SentToScope NotInOrganization` | 組織外（外部）宛のメール |
| `RouteMessageOutboundConnector` | 指定したコネクタ経由で送信 |

### Outbound #2: 内部DMZ SMTP向け（フォールバック）

```powershell
New-OutboundConnector -Name "To-OnPrem-DMZ-Fallback" `
    -ConnectorType OnPremises `
    -SmartHosts "dmz-smtp.internal.example.co.jp" `
    -TlsSettings EncryptionOnly `
    -UseMXRecord $false `
    -RecipientDomains "example.co.jp","sub.example.co.jp"  # 移行対象ドメイン
```

**Internal Relayの動作**:
- メールボックスあり → EXO配信
- メールボックスなし → このコネクタで内部DMZへ転送

### Inbound #1: AWS DMZ SMTPから

```powershell
New-InboundConnector -Name "From-AWS-DMZ-SMTP" `
    -ConnectorType Partner `
    -SenderIPAddresses "AWS DMZ SMTPのグローバルIP" `
    -RestrictDomainsToIPAddresses $true `
    -RequireTls $true
```

**認証方針**: IP制限 + TLS必須（採用）

| 方式 | メリット | デメリット | 採用 |
|---|---|---|---|
| IP制限 + TLS必須 | シンプル、導入容易 | IP変更時に設定変更必要 | **✅** |
| 証明書認証 | IP変更に強い | 証明書管理が必要 | 将来検討 |

※ 現場的には「まずIP制限 + TLS必須」で開始し、余力があれば証明書認証を追加

### Accepted Domain設定

```powershell
# 移行対象ドメインをInternal Relayとして登録
Set-AcceptedDomain -Identity "example.co.jp" -DomainType InternalRelay
```

---

## 段階的移行アーキテクチャ

### 課題

移行中、メールボックスがEXOとCourier IMAPに分散する。  
**未移行ユーザー宛のメールがEXOに届いた場合、どう救済するか？**

### 解決策: Internal Relay + 内部DMZ SMTPフォールバック

EXOで対象ドメインを **Internal Relay** として登録し、メールボックスが存在しない宛先は内部DMZ SMTP経由でCourier IMAPに転送する。

### メリット

1. **移行を段階的に進められる**
   - 全員一斉でなく、準備できたユーザーから順次移行可能
2. **未移行ユーザーへのメールロスを防止**
   - EXOに届いてもCourier IMAPにフォールバック
3. **既存インフラの有効活用**
   - 使われていなかった内部DMZ SMTPを救済先として活用

### 注意点

1. **Internal Relayの動作**
   - EXOで受信者が見つかれば → EXO配信
   - EXOで受信者が見つからなければ → 該当ドメイン宛のOutbound Connector経由で次ホップへ転送
   - **Mail User/Contactを作らなくても「未知宛先の救済」はできる**（Authoritativeとの違い）
   - ただし「既知宛先として扱いたい（GAL表示・アドレス解決・送信抑止制御）」場合はMail User/Contactが必要

2. **Internal Relayの必須条件** ⚠️
   - Internal Relayに設定したAccepted Domainには、**必ず一致するRecipientDomainsを持つOutbound Connector**が必要
   - 存在しないと警告が表示され、配送不能になる可能性あり
   - 本設計では Outbound #2（To-OnPrem-DMZ-Fallback）がこの役割を担う

3. **Outbound Connectorのスコープ**
   - 移行対象ドメイン宛のみ発動するように設定
   - 外部宛メールはセキュリティサービスコネクタが処理

3. **内部DMZ SMTP側の設定**
   - EXOからの接続を許可（IPレンジ or 証明書認証）
   - 既存の40ドメイン→Postfix中継設定を確認

4. **本格移行時の出口戦略**
   - 全員移行完了後、Accepted DomainをAuthoritativeに変更
   - フォールバック用Outbound Connector削除
   - 内部DMZ SMTPを廃止 or 別用途に

5. **フォールバック経路の廃止基準（運用ポリシー）**
   - EXO Message Traceでフォールバック経路の利用状況を監視
   - **廃止判断の目安**: フォールバック経路の利用が2週間ゼロなら停止検討
   - 停止前に残存ユーザーの有無を最終確認

### 確認事項（内部検討用）

| # | 確認事項 | 備考 |
|---|---|---|
| 1 | 内部DMZ SMTPへの疎通 | EXOからオンプレへの経路確認 |
| 2 | 内部DMZ SMTPの現行設定 | 40ドメイン転送設定の有無 |
| 3 | EXO送信コネクタの設計 | スコープ（対象ドメイン）、認証方式 |
| 4 | メールループ防止 | 転送ループにならないことの確認 |
| 5 | お客様ネットワーク許可 | EXO IPレンジの許可 |

### メールループ防止の具体ガード

「偶然に頼らない」思想に基づき、ループ防止は設計段階で仕組み化する。

| # | ガード手段 | 実装場所 | 内容 |
|---|---|---|---|
| 1 | **ヘッダマーキング** | EXO Transport Rule | 救済ルートを通ったメールにカスタムヘッダ付与 |
| 2 | **ヘッダ検査** | 内部DMZ SMTP | 付与されたヘッダがあれば再投入を拒否 |
| 3 | **コネクタスコープ制限** | EXO Outbound Connector | 対象ドメイン限定（`RecipientDomains`で絞る） |

**EXOでのヘッダ付与ルール例**:
```powershell
# フォールバック経路を通るメールにマーキング
# 例外条件：既にヘッダが付いている場合は適用しない（二重マーキング防止）
New-TransportRule -Name "Mark Fallback Route" `
    -FromScope InOrganization `
    -RouteMessageOutboundConnector "To-OnPrem-DMZ-Fallback" `
    -ExceptIfHeaderContainsMessageHeader "X-EXO-Fallback" `
    -ExceptIfHeaderContainsWords "true" `
    -SetHeaderName "X-EXO-Fallback" `
    -SetHeaderValue "true"
```

**内部DMZ SMTP（Postfix）でのチェック例**:
```
# /etc/postfix/header_checks
/^X-EXO-Fallback: true/ REJECT Mail loop detected (already routed via EXO fallback)
```

**Postfix header_checks適用の注意点**:
- header_checksはPostfixのcleanup/SMTP受信経路で適用される
- 効かない場合は、main.cfで `header_checks = regexp:/etc/postfix/header_checks` が有効か確認
- smtpd_recipient_restrictions等での適用順序も確認

---

## 顧客環境構成

### 現行システム構成図

```
【メール送信フロー】内部→外部

  ┌─────────────────────────────────────────────────────────────────────┐
  │ 内部ネットワーク                                                     │
  │  ┌──────────────┐  ┌──────────────┐                                 │
  │  │ ユーザー端末  │  │ システムメール │                                │
  │  │ Thunderbird  │  │ (統合ID等)   │                                 │
  │  │ (AD認証/POP) │  │              │                                 │
  │  └──────┬───────┘  └──────┬───────┘                                 │
  │         └────────┬────────┘                                         │
  └──────────────────┼──────────────────────────────────────────────────┘
            │ SMTP送信
            ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │ AWS環境                                                             │
  │  ┌──────────────┐                                                   │
  │  │ Postfix      │ ルーティング判定                                   │
  │  │ (SMTPハブ)   │                                                   │
  │  └──────┬───────┘                                                   │
  │         │                                                           │
  │    ┌────┴────┐                                                      │
  │    │         │                                                      │
  │    ▼         ▼                                                      │
  │ 内部宛    外部宛                                                     │
  │ (40ドメイン)                                                         │
  │    │         │                                                      │
  │    │    ┌────▼────────┐                                             │
  │    │    │ GuardianWall│ 添付ファイルURL化                           │
  │    │    └────┬────────┘                                             │
  │    │         │                                                      │
  │    │    ┌────▼────────┐                                             │
  │    │    │ DMZ SMTP    │ 外部宛 → インターネット                     │
  │    │    │ (中継)      │ 内部宛（40ドメイン）→ Postfix               │
  │    │    └─────────────┘                                             │
  │    │                                                                │
  │    └────────┐                                                       │
  │             ▼                                                       │
  │  ┌──────────────┐                                                   │
  │  │ Courier IMAP │ メールボックス（最終着弾点）                       │
  │  │              │ ユーザーはPOPで受信                               │
  │  └──────────────┘                                                   │
  └─────────────────────────────────────────────────────────────────────┘


【メール受信フロー】外部→内部

  インターネット
       │
       │ MXレコード参照
       ▼
  ┌──────────────┐
  │ FireEye      │ メールセキュリティ（全40ドメインのMXがここを向く）
  │              │
  └──────┬───────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
  メイン    フォールバック
    │         │
  ┌─▼───────┐ ┌─▼─────────────┐
  │ AWS      │ │ 内部ネットワーク│
  │ DMZ SMTP │ │ DMZ SMTP      │ ※ほとんど通らない実態
  └────┬─────┘ └──────┬────────┘
       │              │ 40ドメイン宛 → Postfixへ中継
       ▼              │
  ┌──────────────┐    │
  │ Postfix      │◄───┘
  │ (SMTPハブ)   │
  └──────┬───────┘
         │ 40ドメイン宛
         ▼
  ┌──────────────┐
  │ Courier IMAP │
  └──────────────┘
```

### ID管理システム構成

```
【ID作成・管理フロー】

  ユーザー申請
       │
       ▼
  ┌─────────────────────┐
  │ 電話帳/メールアドレス │ AWS上（PHP + PostgreSQL）
  │ 管理システム         │ ※命名規則が緩く自由度が高い
  └──────────┬──────────┘
             │
             ▼
  ┌─────────────────────┐
  │ 統合アカウントシステム│ 内部ネットワーク（LDAP）
  │                     │ ユーザー/パスワード/メールアドレス管理
  └──────────┬──────────┘
             │
      ┌──────┴──────┐
      ▼             ▼
  ┌────────┐   ┌────────────┐
  │ 社内    │   │ Active     │ ※メール属性はほぼ空
  │ システム │   │ Directory  │
  └────────┘   └──────┬─────┘
                      │ Entra Connect
                      ▼
               ┌────────────┐
               │ Entra ID   │ ユーザー + セキュリティグループ同期済み
               └──────┬─────┘
                      │
                      ▼
               ┌────────────┐
               │ Exchange   │ 環境はあるが未使用
               │ Online     │ EWSのみオン、他はオフ
               └────────────┘
```

### 現状の特徴

| 項目 | 現状 | 備考 |
|---|---|---|
| メーラー | Thunderbird | 移行後はOutlook希望 |
| プロトコル | POP | サーバーにメール残らない |
| メールボックス | Courier IMAP | 40ドメイン |
| セキュリティ | FireEye + 現行GWサーバー | 添付URL化あり |
| AD mail属性 | ほぼ空 | 全投入が必要 |
| ID作成 | 独自システム（自由度高） | 命名規則整理が必要 |
| 1ユーザー複数アドレス | あり | 同一ドメイン/複数ドメイン両方 |
| Webメール | Roundcube（AWS） | ほぼ使われていない |
| 共有アドレス | あり（詳細不明） | 要確認 |
| メール転送 | 横行している | お客様は防ぎたい意向 |
| クライアント | Thunderbird + システムメール | システムメール＝統合ID等からの通知 |

### 各コンポーネントのリレー設定（現行）

| コンポーネント | 受信元 | リレー先 | 備考 |
|---|---|---|---|
| **Postfix（SMTPハブ）** | Thunderbird、システムメール、AWS DMZ SMTP、内部NW DMZ SMTP | 40ドメイン宛→Courier IMAP、外部宛→GuardianWall | SMTPハブとして全経路を集約 |
| **GuardianWall** | Postfix | AWS DMZ SMTP | 添付ファイルURL化後に中継 |
| **AWS DMZ SMTP** | GuardianWall、FireEye | 40ドメイン宛→Postfix、外部宛→インターネット | transport設定でドメイン単位制御 |
| **内部NW DMZ SMTP** | FireEye（フォールバック） | 40ドメイン宛→Postfix（全てPostfixへ中継） | ほぼ使われていない。FireEyeのフォールバック先 |
| **FireEye** | インターネット（MX） | AWS DMZ SMTP（メイン）、内部NW DMZ SMTP（フォールバック） | 受信専用、40ドメインのMX |
| **Courier IMAP** | Postfix | —（最終配送先） | メールボックス、40ドメイン |

### 付帯環境・運用上の課題

#### Roundcube（Webメール）

- **場所**: AWS上
- **用途**: Courier IMAPのメールをWeb経由で閲覧
- **実態**: ほぼ使われていない
- **今回の対応**: スコープ外（触らない）

#### 共有アドレスの実態

**推測**（要確認）:
- Courier IMAPにはメーリングリスト機能がない
- 特定ユーザーのメールボックスを「共有アドレス」として運用している可能性
- ただしPOP受信なので共有には向かない（1台でダウンロードすると他で見れない）

**EXO移行後の選択肢**:
| 現行運用 | EXOでの実現方法 |
|---|---|
| 特定ユーザーのBOXを共有 | 共有メールボックス（Shared Mailbox） |
| メーリングリスト的な配信 | 配布グループ（Distribution Group） |
| 複数人で同じメールを管理 | Microsoft 365グループ |

**判定基準（共有アドレスの振り分け）**:
| 条件 | 選択 | 理由 |
|---|---|---|
| 複数人で受信し、それぞれが返信する | **共有メールボックス** | 受信トレイを共有、送信元も統一可能 |
| 複数人に同時配信するだけ（返信不要） | **配布グループ** | シンプル、ライセンス不要 |
| チームでスレッド管理、ファイル共有も | **M365グループ** | Teams/SharePoint連携 |

**確認事項**:
- 共有アドレスの件数と用途
- 現在の運用方法（どのように「共有」しているか）

#### メール転送の横行

**現状の問題**:
- POP受信 → 端末依存（その端末でしかメールが見れない）
- 他の端末から見たい → 転送で対応している
- セキュリティ・情報管理上の問題

**お客様の意向**: 転送を防ぎたい

**EXO移行による自然解消**:
- Outlook + EXOはクラウドメールボックス
- どの端末からでも同じメールが見れる
- 転送の動機がなくなる

**追加対策（必要に応じて）**:
| 対策 | 内容 |
|---|---|
| トランスポートルール | 外部への自動転送をブロック |
| OWAポリシー | 転送設定の無効化 |
| 監査ログ | 転送設定の監視 |

**EXOでの転送ブロック設定例**:
```powershell
# 外部への自動転送をブロックするトランスポートルール
New-TransportRule -Name "Block External Forwarding" `
    -FromScope InOrganization `
    -SentToScope NotInOrganization `
    -MessageTypeMatches AutoForward `
    -RejectMessageReasonText "外部への自動転送は禁止されています"
```

#### アドレス帳の扱い

**現状の推測**:
| コンポーネント | アドレス帳機能 |
|---|---|
| Courier IMAP | なし（メールボックスのみ） |
| Thunderbird | あり（ローカル保存） |
| 電話帳システム | あり（AWS上） |

**可能性**:
- Thunderbirdローカルにアドレス帳を保持
- 電話帳システムを参照
- メール履歴から宛先を選択（特に管理なし）

**EXO移行後の方針**:
| 用途 | EXOでの対応 | 移行作業 |
|---|---|---|
| 社内連絡先 | **GAL（グローバルアドレス一覧）** | 不要（AD連携で自動生成） |
| 個人の連絡先 | Outlook連絡先（個人管理） | ユーザー任せ |
| 外部取引先等 | Outlook連絡先（個人管理） | ユーザー任せ |

**方針**: 
- **GALを使ってもらう**（社内宛先はこれで十分）
- 個人の連絡先はユーザー自身で登録
- Thunderbirdアドレス帳の移行はスコープ外
- 必要に応じてユーザー向け手順書で移行方法を案内

**確認事項**:
| # | 確認事項 | 備考 |
|---|---|---|
| 1 | ユーザーは現在どうやって宛先を選んでいるか | アドレス帳 or メール履歴 |
| 2 | 電話帳システムとの連携はあるか | Thunderbirdにインポート等 |
| 3 | アドレス帳移行の要望があるか | あれば手順書で対応 |

---

## 懸念事項と対策（確定方針）

### ✅ 対策確定

#### 1. 過去メールの扱い

**方針**: 移行しない（案A採用）

- 過去メールはThunderbirdローカルに残る
- ユーザー向けに「Outlook移行手順書」を作成
- 必要に応じてユーザー自身でPSTインポート

**成果物**: ユーザー向けOutlook移行手順書

#### 2. 移行対象データの準備

**方針**: お客様に移行対象一覧を用意してもらう

- 統合アカウントシステムはスコープ外（触らない）
- お客様が移行対象ユーザー×メールアドレスをCSVで提供
- 我々はそれを元にAD投入・EXO設定を行う

**お客様依頼事項**:
```
【移行対象一覧CSV】
必須項目:
- ADユーザー識別子（UPN or SamAccountName）
- プライマリメールアドレス
- エイリアス（あれば、セミコロン区切り）

例:
UserPrincipalName,SamAccountName,PrimarySmtpAddress,Aliases
user1@contoso.local,user1,user1@example.co.jp,alias1@example.co.jp;alias2@example.co.jp
```

#### 3. 1ユーザー複数アドレス

**方針**: 同一ドメイン内はプライマリ + proxyAddressesで対応

| パターン | 対応方針 |
|---|---|
| 同一ドメインで複数 | プライマリ1つ + proxyAddressesにエイリアス |
| 複数ドメインで1ユーザー | 要整理（下記参照） |
| 部署メール | 共有メールボックス or 配布グループ（要整理） |

**⚠️ 要確認**: 1人のユーザーが複数ADアカウントを持っている可能性
- ドメインごとにADユーザーが分かれているケースがあり得る
- お客様提供の移行対象一覧で実態を確認

#### 4. 送信セキュリティ（添付URL化）

**方針**: GuardianWall Cloud を導入

```
【移行後の送信フロー】

  Outlook
     │
     ▼
  Exchange Online
     │
     │ Outbound Connector
     ▼
  GuardianWall Cloud  ← 添付ファイルURL化
     │
     ▼
  インターネット
```

**準備タスク**:
- [ ] 送信セキュリティサービス契約・環境準備
- [ ] EXO Outbound Connector作成（GWC向け）
- [ ] 現行GuardianWall設定のエクスポート・移行

#### 5. 受信セキュリティ

**方針**: FireEye継続使用

- 現行のMXレコード（FireEye向き）は変更なし
- FireEyeの転送先をEXOに変更（パイロットドメインのみ）

```
【移行後の受信フロー】

  インターネット
     │
     │ MX（変更なし）
     ▼
  FireEye  ← 継続使用
     │
     │ パイロットドメイン → EXO
     │ 他ドメイン → AWS DMZ SMTP（現行通り）
     ▼
  Exchange Online / Courier IMAP
```

**準備タスク**:
- [ ] FireEye現行設定の棚卸し
- [ ] パイロットドメインの転送先変更設定

### 🟡 Warning（要調査・注意喚起）

#### 6. スキーマ拡張の影響確認

**懸念**: ADスキーマ拡張が統合アカウントシステムからのデータ連携に影響しないか

**確認ポイント**:
- 統合アカウントシステム→ADの連携で、msExch系属性がある前提のコードになっていないか
- スキーマ拡張後にAD書き込みエラーが発生しないか

**対策**: 
- スコープ外（触らない）だが、お客様に注意喚起
- 問題が起きた場合の切り分け手順を用意

#### 7. EXO先行設定の確認

**懸念**: お客様が先行して環境準備している可能性

- ライセンスが既に割り当たっている可能性
- 意図しないメールボックスが存在する可能性
- EWSがオンになっている理由（何かが使っている？）

**確認タスク**:
- [ ] EXOライセンス割当状況の棚卸し
- [ ] 既存メールボックス/受信者の全件抽出（紛れ検出）
- [ ] EWS利用状況の確認（お客様ヒアリング）

#### 8. 1ユーザー複数ADアカウント問題

**懸念**: ドメインごとにADユーザーが分かれている可能性

**影響**:
- 同一人物が複数のADユーザーを持っている場合、EXOでどう扱うか
- メールボックスを1つにまとめるか、別々にするか

**対策**: 
- お客様提供の移行対象一覧で実態を確認
- 方針決定はお客様判断

#### 9. 内部DMZ SMTPの扱い

**現状**: フォールバック用だがほとんど通っていない

**確認ポイント**:
- 内部DMZ SMTPを使っている他システムの有無
- ADからのメール通知等がないか

**想定**: 多分使っていない（ADぐらい）→ 確認は必要

#### 10. GuardianWall / FireEye設定エクスポート

**タスク**:
- [ ] 現行GuardianWall設定のエクスポート（GWC移行用）
- [ ] 現行FireEye設定の確認（お客様申告だけでなく実設定を確認）

---

## お客様依頼事項

### 必須（移行作業の前提）

| # | 依頼内容 | 用途 | 形式 |
|---|---|---|---|
| 1 | **移行対象ユーザー一覧CSV** | AD属性投入の元データ | 下記テンプレート参照 |
| 2 | **1ユーザー複数アドレスの実態** | 設計判断 | 一覧内に含める |
| 3 | **パイロットドメインの選定** | 先行移行対象 | ドメイン名 |

### 確認（影響範囲の把握）

| # | 確認事項 | 回答例 |
|---|---|---|
| 4 | EWSを使っているシステムはあるか | なし / ○○システム |
| 5 | 内部DMZ SMTPを使っている他システムはあるか | なし / AD通知 |
| 6 | 1人が複数ADアカウントを持つケースはあるか | なし / ○○の場合あり |

### 移行対象一覧CSVテンプレート

```csv
# 移行対象ユーザー一覧
# 
# 【記入方法】
# - 1行1ユーザー
# - エイリアスは複数ある場合セミコロン(;)区切り
# - 空欄の場合は省略可
#
UserPrincipalName,SamAccountName,PrimarySmtpAddress,Aliases,備考
user1@contoso.local,user1,user1@example.co.jp,alias1@example.co.jp;sales@example.co.jp,営業部
user2@contoso.local,user2,user2@example.co.jp,,
```

---

## 追加棚卸し項目

今回の情報を踏まえ、Phase 1で追加で確認すべき項目：

| 項目 | 確認内容 | 確認先 | 優先度 |
|---|---|---|---|
| EXOライセンス割当 | 既に割り当たっているユーザー | Entra管理画面 | 高 |
| EXO既存受信者 | 紛れメールボックスの有無 | EXO PowerShell | 高 |
| FireEye設定 | 40ドメインの転送先設定（→AWS DMZ SMTP確認） | FireEye管理画面 | 高 |
| GuardianWall設定 | 現行ルール・ポリシー（GWC移行用） | GW管理画面 | 中 |
| EWS利用状況 | 使用システムの有無 | お客様ヒアリング | 中 |
| 内部DMZ SMTP | EXOからの疎通、40ドメイン転送設定 | 内部DMZ SMTP設定 | 中 |
| システムメール | 送信元・経路・宛先の確認 | お客様ヒアリング/構成図 | 中 |
| Postfix（SMTPハブ） | 内部ドメイン宛のルーティング設定確認 | Postfix設定 | 中 |
| AWS DMZ SMTP | transport設定（ドメインごとの転送先） | Postfix設定 | 高 |
| **共有アドレス** | 件数、用途、現在の運用方法 | お客様ヒアリング | 中 |
| **メール転送** | 転送設定の実態、転送ブロック要件 | お客様ヒアリング | 中 |
| **アドレス帳** | ユーザーの宛先選択方法、移行要望 | お客様ヒアリング | 低 |
| Roundcube | 利用状況（ほぼ未使用の確認） | お客様ヒアリング | 低 |

### システムメールについて

統合アカウントシステム等から発行されるシステムメールの経路確認が必要。

**想定**:
```
システム → Postfix（SMTPハブ）→ Courier IMAP
```
- ユーザーメールと同じ経路を通る想定
- 移行対象ドメイン宛のシステムメールはEXOに届くことになる
- 基本的にいじらなくてもOKだが、確認は必要

**確認事項**:
| # | 確認事項 | 備考 |
|---|---|---|
| 1 | システムメールの送信元 | 統合ID、その他システム |
| 2 | 送信に使うSMTPサーバー | Postfix経由か直接か |
| 3 | 宛先ドメイン | 移行対象ドメイン宛があるか |

---

## 設計哲学（3つの鉄則）

1. **箱を作る前に、箱を壊す**
   - EXOに意図しないメールボックスが存在しないことを確認してから進める
2. **フローは最後まで触らない**
   - SMTPルーティングの切替は全準備完了後に実施
3. **「自動でそうなる」ではなく「そうなるように作る」**
   - 偶然の動作に頼らず、意図的に設計・検証する

---

## 全体構造：3層モデル

移行作業は以下の3層を順に確定させる作業として捉える。

| 層 | 役割 | 確定させること |
|---|---|---|
| **ID層** | ユーザーがEXOを使う資格があるか | ライセンス棚卸し・付与制御 |
| **箱層** | EXO側に正しいメールボックスが1つだけ存在するか | AD属性整備・紛れ検出・クリーン |
| **フロー層** | SMTPがどこに最終配達されるか | コネクタ設定・MX切替 |

**事故パターン**
- 箱が2つある（重複メールボックス）
- フローが先に切り替わる（準備不足での切替）

---

## 前提：検証環境がない現場での進め方

本プロジェクトでは**お客様の本番テナントにテストドメインを作成**し、環境構築とテスト環境整備を同時進行で進める。

```
【基本方針】
1. テストドメインでメール経路が通る状態を先に作る
2. テストで問題ないことを確認してから本番ドメイン切替
3. 環境構築 → テスト → 本番切替 が1つのフェーズ内で完結
```

---

## 作業フェーズ（推奨順序）

### Phase 1: 全体棚卸し（現状把握）

**目的**: 移行設計の土台となる情報を全て回収

#### 1-1. EXO/Entra棚卸し
- EXO系ライセンス割当状況の確認
- 既存EXOメールボックス/受信者の全件抽出
- Accepted Domain/コネクタの現状確認

#### 1-2. AD棚卸し
- ユーザー/グループのメール属性（mail, proxyAddresses）
- msExch系属性の有無
- Entra Connect同期状態

#### 1-3. Linux環境棚卸し
- Postfix設定（ルーティング、サイズ制限）
- DMZ SMTP設定
- Courier IMAP（メールボックス実在一覧）

#### 1-4. DNS棚卸し
- 40ドメイン分のMX/SPF/DKIM/DMARC一括取得

#### 1-5. 紛れ検出
- EXO受信者とADを突合
- `STRAY_EXO_ONLY`（EXOにいるがADにいない）を特定
- **この時点で地雷候補をリスト化**

**成果物**:
- 棚卸しCSV一式
- 紛れ候補レポート
- 現行ルーティング図

---

### Phase 2: EXOクリーン（箱を作る前に箱を壊す）

**目的**: 「EXOに意図しない箱がない」状態を作る

#### 2-1. 不要オブジェクトの削除
- 紛れメールボックスの`Remove-Mailbox`
- 不要なMailUser/Contact/Groupの削除
- 不要ライセンスの剥奪

#### 2-2. クリーン確認
- 紛れ検出スクリプト再実行
- `STRAY_EXO_ONLY`がゼロであることを確認

**重要**: 「自然消滅」ではなく「意図的に消す」（監査・説明のため）

---

### Phase 3: テスト環境構築（テストドメインでの経路確立）

**目的**: 本番ドメインを触らずにメール経路を検証できる状態を作る

#### 3-1. テストドメイン準備
- テストドメインをEXOにAccepted Domain登録（Internal Relay）
- DNS設定（MX/SPF/DKIM/DMARC）

#### 3-2. コネクタ作成
- **Inbound Connector**: DMZ SMTPからの受信許可（テストドメイン含む）
- **Outbound Connector**: EXOからDMZ SMTPへの送信（救済ルート用）

#### 3-3. DMZ SMTP分岐設定
- DMZ SMTPに「テストドメインはEXO宛て」のルーティング追加
- 本番ドメインの経路は**一切触らない**

#### 3-4. テストアカウント作成
- **まずEntra ID直作り**でルーティング確認（早い・軽い）
- ライセンス付与でテスト用メールボックス作成

#### 3-5. メール経路テスト

| テスト項目 | 内容 | 確認ポイント |
|---|---|---|
| 外→EXO | インターネット→テストドメイン | 到達、迷惑メール判定、TLS |
| EXO→外 | テストドメイン→外部アドレス | SPF/DKIM/DMARC検証 |
| EXO→EXO | 同一テナント内送受信 | アドレス解決、GAL |
| 内部→EXO | DMZ SMTP→テストドメイン | ルーティング分岐 |
| システムメール | 監視・通知からの受信 | 想定外送信元の動作 |

**成果物**:
- テスト結果報告書
- 「テストドメインでEXOにメールが流れる」ことの確認

---

### Phase 4: AD準備（箱の設計図）

**目的**: 本番ドメインのメール属性を整備

#### 4-1. ADスキーマ拡張
- Schema Master DCで`/PrepareSchema` → `/PrepareAD`実行
- `repadmin /syncall /AdeP`で強制レプリケーション
- スキーマバージョン確認

#### 4-2. メール属性投入
- CSVからmail/proxyAddresses一括投入
- **Primary SMTPは大文字`SMTP:`で明示**
- 投入前に**SMTP重複チェック**（横断で重複があれば停止）

#### 4-3. AD属性検証（テストドメインで再現テスト）
- テストドメインで**AD起点のアカウント作成**を試行
- スキーマ拡張後の属性が正しく同期されるか確認
- 「本番と同じフロー」での動作検証

**この時点での状態**:
- AD属性は整備済み
- まだ本番ドメインのEXOメールボックスは無い

---

### Phase 5: 本番ドメイン準備（箱の生成）

**目的**: 本番ドメインのEXOメールボックスを作成

#### 5-1. Accepted Domain設定
- 本番ドメインをEXOにAccepted Domain登録（Internal Relay）

#### 5-2. ライセンス付与
- 専用セキュリティグループ or 動的グループでライセンス付与
- **人手でバラ撒かない**（グループベースで制御）

```
ライセンス付与 → EXOがAD属性を読む → 正しいメールボックスを1つ作る
```

#### 5-3. メールボックス生成確認
- 対象ドメインの**全ユーザーに箱がある**ことを確認
- **余計な箱が1つもない**ことを確認
- 紛れ検出スクリプト再実行

#### 5-4. 本番ドメインでの送受信テスト（SMTP切替前）
- **まだDMZ SMTPの向き先は旧環境のまま**
- EXO側から外部への送信テスト
- EXO内部での送受信テスト

---

### Phase 6: SMTP切替（不可逆ポイント）

**目的**: 唯一の戻れない操作を実行

#### 6-1. 切替前最終確認
- [ ] EXOに本番ドメインの全メールボックスがある
- [ ] アドレスは整理済み（重複なし）
- [ ] 紛れメールボックスがゼロ
- [ ] テストドメインでの全テスト完了
- [ ] 本番ドメインでのEXO内テスト完了
- [ ] 送信セキュリティサービス設定完了（導入時）
- [ ] SPF/DKIM/DMARC設定完了

#### 6-2. DMZ SMTP分岐切替
- DMZ SMTPに「本番ドメインはEXO宛て」のルーティング追加
- **この瞬間からメールはEXOに流れる**

#### 6-3. 切替直後テスト
- 外部→本番ドメイン（EXO着）
- 本番ドメイン（EXO）→外部
- 内部システム→本番ドメイン（EXO着）

---

### Phase 7: 安定化・クリーンアップ

**目的**: 移行完了後の整理

#### 7-1. 救済ルート監視
- EXO→DMZ SMTP→旧環境ルートの利用状況確認
- 想定外のリレーがないかログ確認

#### 7-2. 旧環境ルート廃止
- 救済ルートが不要になったら廃止
- Outbound Connector削除 or 無効化

#### 7-3. Internal Relay → Authoritative変更
- 対象ドメインをAuthoritativeに変更
- 「EXOが唯一の配達先」状態に移行

#### 7-4. 旧環境の扱い
- クリアIMAPは参照用途のみへ（SMTPは完全切断済み）
- 一定期間後に廃止判断

---

## 棚卸し：見るべき情報

### A. ルーティング・制御系

| 対象 | 回収内容 |
|---|---|
| Postfix | postconf -n、transport/virtual/relay_domains、message_size_limit |
| DMZ SMTP | 同上（Postfixなら） |
| FireEye | ドメイン→配送先マッピング、受信ポリシー |
| DNS | MX/SPF/DKIM/DMARC（40ドメイン一括） |
| EXO | Accepted Domain、Inbound/Outbound Connector |

### B. 受信者オブジェクト実態系

| 対象 | 回収内容 |
|---|---|
| Courier IMAP | メールボックス実在一覧 |
| AD | mail、proxyAddresses、msExch系属性 |
| Entra | ユーザー×ライセンス一覧 |
| EXO | Mailbox/MailUser/Contact/Groupとそのメールアドレス |

---

## 紛れ検出の重要性

### 「紛れ」とは

EXO側に存在するが、ADの正規ユーザー/グループと整合していないオブジェクト

### なぜ危険か

Internal Relayは「EXOで既知の受信者は配達、未知はリレー」する仕様のため、**紛れがいるとオンプレ救済に流れない**

### 検出ロジック

```
Status判定:
- STRAY_EXO_ONLY: EXOにいるがADにいない → 最優先の地雷候補
- DUPLICATE_IN_AD: AD側で同じSMTPを複数保持 → 同期時にコケる
- MATCH_AD: 正常
```

### 対策

1. 棚卸しでEXO受信者とADを突合
2. STRAY_EXO_ONLYを特定
3. 削除/修正/残すの判断
4. クリーン完了後にInternal Relay設定

---

## 検証環境の確保

### 選択肢（優先順）

| 選択肢 | 概要 | コスト |
|---|---|---|
| 🥇 Azure検証環境 | Windows Server評価版でDC2台構築、スキーマ拡張を実体験 | 数千円〜1万円台 |
| 🥈 プロパー側検証環境 | 「スキーマ拡張を事前検証したい」は誰も反対しにくい | 交渉次第 |
| 🥉 Linux系ローカル検証 | Docker + Postfix + Dovecotでルーティング思想検証 | 無料 |

### ADバックアップ確認（必須ヒアリング項目）

- ADバックアップ方式
- システムステートの取得有無
- リストア手順の存在
- 最後にリストアテストした時期

---

## 切替当日の観測点

### 監視対象一覧

| # | 観測点 | 確認内容 | ツール/ログ |
|---|---|---|---|
| 1 | **EXO Message Trace** | メール到達・配信状況 | Exchange管理センター / PowerShell |
| 2 | **AWS DMZ SMTPログ** | EXOへの転送成功/失敗 | /var/log/maillog |
| 3 | **内部DMZ SMTPログ** | EXOからの受信、Courierへの転送 | /var/log/maillog |
| 4 | **FireEye転送ログ** | AWS DMZ SMTPへの転送状況 | FireEye管理画面 |
| 5 | **GuardianWall Cloudログ** | 外部送信の添付URL化 | GWC管理画面 |

### NDR発生時の切り分けフロー

```
NDR発生
    │
    ├─ 送信者はどこ？
    │     ├─ Outlook → EXO Message Traceで追跡
    │     └─ Thunderbird → AWS DMZ SMTPログで追跡
    │
    ├─ 宛先はどこ？
    │     ├─ 外部 → GWCログ確認
    │     ├─ 移行済みユーザー → EXO Message Trace
    │     └─ 未移行ユーザー → 内部DMZ SMTPログ → Courierログ
    │
    └─ どこで止まった？
          ├─ EXOで止まった → コネクタ設定、Accepted Domain確認
          ├─ DMZで止まった → transport設定、ファイアウォール確認
          └─ Courierで止まった → メールボックス存在確認
```

### 切替後チェックリスト

| # | チェック項目 | 確認方法 | OK |
|---|---|---|---|
| 1 | 外部→移行済みユーザー受信 | テストメール送信 | □ |
| 2 | 移行済みユーザー→外部送信 | テストメール送信（添付あり） | □ |
| 3 | 移行済み→未移行ユーザー送信 | テストメール送信 | □ |
| 4 | 未移行→移行済みユーザー送信 | テストメール送信 | □ |
| 5 | GALに全員表示 | Outlookで検索 | □ |
| 6 | NDR発生なし | EXO Message Trace確認 | □ |

---

## スクリプト一覧

スクリプトは `cli_tools/exo-migration-tools/` に配置。

### 棚卸し系（inventory/）

| スクリプト | 対象 | 言語 |
|---|---|---|
| collect_postfix.sh | Postfix設定・サイズ制限・ルーティング・TLS | Bash |
| collect_courier_imap.sh | Courier/Dovecot設定・メールボックス実在 | Bash |
| collect_smtp_dmz.sh | DMZ SMTP設定（MTA自動判定） | Bash |
| Collect-ADInventory.ps1 | ADユーザー・グループのメール属性・スキーマバージョン | PowerShell |
| Collect-EntraInventory.ps1 | Entraユーザー・ライセンス | PowerShell |
| Collect-EXOInventory.ps1 | EXO受信者・コネクタ・Accepted Domain・Transport Rules | PowerShell |
| Collect-DNSRecords.ps1 | 複数ドメインのMX/SPF/DKIM/DMARC一括取得 | PowerShell |

### 分析・検証系（analysis/）

| スクリプト | 目的 | 言語 |
|---|---|---|
| Detect-StrayRecipients.ps1 | 紛れ検出（EXO-AD突合） | PowerShell |
| Test-SmtpDuplicates.ps1 | AD投入前のSMTP重複チェック | PowerShell |

### 実行系（execution/）

| スクリプト | 目的 | 言語 |
|---|---|---|
| Invoke-ExchangeSchemaPrep.ps1 | ADスキーマ拡張（権限チェック・レプリケーション含む） | PowerShell |
| Set-ADMailAddressesFromCsv.ps1 | CSVからmail/proxyAddresses投入 | PowerShell |

---

## サイズ制限の整合

| システム | デフォルト | 備考 |
|---|---|---|
| Postfix | 10MB | message_size_limitで確認 |
| EXO | 送信35MB / 受信36MB | 必要に応じ1〜150MBに変更可 |

---

## フェーズ別チェックリスト

### Phase 1完了チェック（棚卸し）

- [ ] EXO棚卸しCSV取得（recipients.csv, mailboxes.csv, accepted_domains.csv, connectors.csv）
- [ ] Entra棚卸しCSV取得（users_license.csv, subscribed_skus.csv）
- [ ] AD棚卸しCSV取得（ad_users_mailattrs.csv, ad_groups_mailattrs.csv）
- [ ] Linux棚卸し取得（Postfix, DMZ SMTP, Courier IMAP）
- [ ] DNS棚卸し取得（40ドメイン分のMX/SPF/DKIM/DMARC）
- [ ] 紛れ検出レポート作成（STRAY_EXO_ONLY一覧）
- [ ] 現行ルーティング図作成

### Phase 2完了チェック（EXOクリーン）

- [ ] 紛れメールボックス削除完了
- [ ] 不要MailUser/Contact/Group削除完了
- [ ] 紛れ検出スクリプト再実行 → STRAY_EXO_ONLYがゼロ

### Phase 3完了チェック（テスト環境構築）

- [ ] テストドメインをAccepted Domain登録（Internal Relay）
- [ ] テストドメインDNS設定（MX/SPF/DKIM/DMARC）
- [ ] Inbound Connector作成・動作確認
- [ ] Outbound Connector作成・動作確認
- [ ] DMZ SMTPにテストドメイン向けルーティング追加
- [ ] テストアカウント作成・ライセンス付与
- [ ] 外→EXOテスト完了
- [ ] EXO→外テスト完了
- [ ] 内部→EXOテスト完了
- [ ] EXO→EXOテスト完了

### Phase 4完了チェック（AD準備）

- [ ] ADバックアップ取得済み
- [ ] Schema Master DCで実行することを確認
- [ ] Schema Admins + Enterprise Adminsに所属
- [ ] `/PrepareSchema`実行完了
- [ ] `/PrepareAD`実行完了
- [ ] `repadmin /syncall /AdeP`実行・レプリケーション確認
- [ ] スキーマバージョン確認
- [ ] SMTP重複チェック実行（重複ゼロ）
- [ ] mail/proxyAddresses投入完了（WhatIf→本番）
- [ ] テストドメインでAD起点アカウント作成テスト完了

### Phase 5完了チェック（本番ドメイン準備）

- [ ] 本番ドメインをAccepted Domain登録（Internal Relay）
- [ ] ライセンス付与用グループ作成
- [ ] ライセンス付与完了
- [ ] 全対象ユーザーにメールボックス存在確認
- [ ] 余計なメールボックスがゼロ確認
- [ ] 紛れ検出スクリプト再実行 → STRAY_EXO_ONLYがゼロ
- [ ] EXO内送受信テスト完了

### Phase 6完了チェック（SMTP切替）

- [ ] 送信セキュリティサービス設定完了（導入時）
- [ ] SPF/DKIM/DMARC本番設定完了
- [ ] DMZ SMTPに本番ドメイン向けルーティング追加
- [ ] 外→本番ドメインテスト完了
- [ ] 本番ドメイン→外テスト完了
- [ ] 内部システム→本番ドメインテスト完了

### Phase 7完了チェック（安定化）

- [ ] 救済ルート利用状況確認（想定外リレーなし）
- [ ] 救済ルート廃止完了
- [ ] Internal Relay → Authoritative変更完了
- [ ] 旧環境SMTPルート完全切断確認

---

## 関連リンク

- [[AIツールとClaudeの知識統合ワークフロー]]
- [[Cursorの機能体系]]
