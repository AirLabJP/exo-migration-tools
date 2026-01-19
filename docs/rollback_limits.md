# Rollback（切り戻し）の限界

このドキュメントでは、**戻せるもの**と**戻せないもの**を明確にします。
移行作業の判断において、「どこまで進んだら戻れないか」を理解することが重要です。

---

## サマリー

| 操作 | 戻せる？ | 戻し方 | 注意点 |
|------|---------|--------|--------|
| EXOコネクタ作成 | ✅ 可能 | 削除 | |
| Accepted Domain変更 | ✅ 可能 | 元のタイプに戻す | |
| Transport Rule作成 | ✅ 可能 | 削除 | |
| Postfix transport変更 | ✅ 可能 | バックアップから復元 | |
| AD属性投入 | ⚠️ 一部可能 | 属性クリア | Entra同期済みの場合は影響あり |
| メールボックス作成 | ⚠️ 困難 | ソフトデリート→30日で完全削除 | ユーザーのメールが消える |
| ライセンス付与 | ⚠️ 困難 | ライセンス削除 | メールボックスが削除対象に |
| ユーザーへのメール配信 | ❌ 不可能 | N/A | 配送済みメールは戻せない |

---

## 詳細説明

### ✅ 完全に戻せるもの

#### 1. EXOコネクタ

```powershell
# 戻し方
.\rollback\Undo-EXOConnectors.ps1
```

- Inbound/Outbound Connectorは削除可能
- 削除後、すぐに元の状態に戻る
- **影響**: 削除するとメールフローが元の経路に戻る

#### 2. Accepted Domain Type

```powershell
# 戻し方
.\rollback\Restore-AcceptedDomainType.ps1 -DomainsFile domains.txt
```

- InternalRelay → Authoritative に戻せる
- 逆も可能
- **影響**: メールボックスがない宛先の挙動が変わる

#### 3. Transport Rule

```powershell
# 手動削除
Remove-TransportRule -Identity "Route-External-Via-GWC"
```

- 削除可能
- **影響**: メールルーティングが変わる

#### 4. Postfix / DMZ SMTP transport設定

```bash
# 戻し方
sudo bash rollback/Restore-DmzSmtpRouting.sh --latest
sudo bash rollback/Restore-PostfixRouting.sh --latest
```

- バックアップファイルから復元
- postmap/reloadで即時反映
- **影響**: メールの振り分け先が元に戻る

---

### ⚠️ 戻せるが影響があるもの

#### 5. AD属性（mail / proxyAddresses）

**戻し方**:
```powershell
# 属性をクリア
Set-ADUser -Identity $user -Clear mail,proxyAddresses
```

**注意点**:
- Entra ID Connect同期済みの場合、Entra側にも反映される
- EXOでメールボックスが作成されていた場合、プライマリアドレスの変更は複雑
- **推奨**: 戻す必要がある場合は、個別ユーザー単位で慎重に

#### 6. メールボックス作成（ライセンス付与による）

**戻し方**:
```powershell
# ライセンス削除
Set-MgUserLicense -UserId $userId -RemoveLicenses @($skuId) -AddLicenses @()

# または
Remove-Mailbox -Identity user@example.co.jp -Confirm:$false
```

**注意点**:
- ライセンス削除後、メールボックスは**ソフトデリート状態**になる
- **30日間は復元可能**、30日後に完全削除
- メールボックス内のメールは削除される
- ユーザーが受信したメールは**消える**

**副作用**:
| 状態 | 影響 |
|------|------|
| ソフトデリート中 | GALから消える、メール受信不可 |
| 完全削除後 | メールアドレスは別ユーザーに再割り当て可能 |

#### 7. ライセンス付与

**戻し方**:
```powershell
# グループから削除
.\execution\phase2-setup\Add-UsersToLicenseGroup.ps1 `
  -CsvPath users.csv `
  -GroupName "EXO-License-Pilot" `
  -RemoveMode
```

**注意点**:
- グループから削除すると、ライセンスが自動的に解除される
- ライセンス解除 → メールボックスがソフトデリート対象に
- **結果的にメールボックス削除と同じ影響**

---

### ❌ 戻せないもの

#### 8. 配送済みメール

**状況**:
- ルーティング変更後にEXOメールボックスに配送されたメール
- 未移行ユーザーに配送されたメール

**戻せない理由**:
- メールは「配送済み」という事実
- 送信者に再送依頼するしかない

**対策**:
- 切替前にテストを十分に行う
- 切替直後は監視を強化

#### 9. ユーザーへの影響（心理的・業務的）

**状況**:
- ユーザーがOutlookを使い始めた後のロールバック
- Thunderbirdに戻す必要が出た場合

**影響**:
- ユーザーの混乱
- 業務への影響
- 信頼性の低下

**対策**:
- ロールバックが必要になった場合の周知手順を事前に用意
- 最悪のケースを想定したコミュニケーション計画

---

## ロールバック判断のタイミング

### Phase別のロールバック容易度

| Phase | 作業内容 | ロールバック容易度 | 推奨判断ポイント |
|-------|---------|-------------------|-----------------|
| Phase 1 | 棚卸し・スキーマ拡張 | ◎ 容易 | スキーマ拡張前に全体確認 |
| Phase 2 | AD属性投入・コネクタ作成 | ○ 比較的容易 | ライセンス付与前に検証 |
| Phase 3 | ルーティング変更 | △ 影響あり | 切替後30分〜1時間で判断 |
| Phase 4 | 検証・安定稼働 | ✕ 困難 | ここで問題があれば個別対応 |

### 「引き返せるポイント」

```
Phase 1 ──→ Phase 2 ──→ [ライセンス付与] ──→ Phase 3 ──→ Phase 4
                              ↑
                        ★ ここが最後の「容易に戻れるポイント」
                        
ライセンス付与後は「戻せるが影響がある」ゾーン
ルーティング変更後は「事実上戻せない」ゾーン（配送済みメール）
```

---

## ロールバック発動の基準

### ロールバックを検討する状況

| 状況 | 判断 | 対応 |
|------|------|------|
| テストで問題発見（Phase 2） | **即座にロールバック** | コネクタ削除、属性クリア |
| 切替後にNDR多発（Phase 3） | **30分以内にロールバック** | transport復元、Accepted Domain復元 |
| 切替後に一部ユーザーで問題（Phase 4） | **個別対応** | 全体ロールバックは避ける |
| 切替後24時間以上経過 | **個別対応** | ロールバックより問題修正 |

### ロールバックを避けるべき状況

- すでにユーザーがメールを受信している
- 外部からのメールが配送されている
- 問題が限定的で、個別対応で解決可能

---

## ロールバック手順チェックリスト

### 緊急ロールバック（Phase 3切替後30分以内）

```
□ 1. AWS DMZ SMTP transport復元
     sudo bash rollback/Restore-DmzSmtpRouting.sh --latest

□ 2. Accepted Domain復元
     .\rollback\Restore-AcceptedDomainType.ps1 -DomainsFile domains.txt

□ 3. メールフロー確認
     テストメール送信、Message Trace確認

□ 4. 関係者への連絡
     切り戻し完了の報告
```

### 通常ロールバック（Phase 2まで）

```
□ 1. EXOコネクタ削除
     .\rollback\Undo-EXOConnectors.ps1

□ 2. Accepted Domain復元（変更していた場合）
     .\rollback\Restore-AcceptedDomainType.ps1 -DomainsFile domains.txt

□ 3. AD属性クリア（必要な場合）
     # 個別ユーザーごとに判断

□ 4. ライセンスグループからの削除（付与していた場合）
     .\execution\phase2-setup\Add-UsersToLicenseGroup.ps1 -RemoveMode
```

---

## まとめ

**原則**:
1. **ライセンス付与前**は比較的容易に戻せる
2. **ライセンス付与後**はメールボックスに影響が出る
3. **ルーティング変更後**は配送済みメールは戻せない
4. **全体ロールバックより個別対応**を優先する

**推奨**:
- 各フェーズ完了後に「ここまでは戻れる」を確認
- テストを十分に行ってから次フェーズへ
- ロールバック手順を事前にリハーサル
