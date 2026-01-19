#!/bin/bash
#===============================================================================
# DMZ SMTP ルーティング設定変更スクリプト
#===============================================================================
#
# 【目的】
#   AWS DMZ SMTP（または内部DMZ SMTP）のルーティング設定を変更し、
#   移行対象ドメインのメールをExchange Onlineにルーティングします。
#
# 【変更内容】
#   /etc/postfix/transport に移行対象ドメインのルーティングを追加
#   例: example.co.jp  smtp:[tenant.mail.protection.outlook.com]
#
# 【用途に応じた使い分け】
#   - AWS DMZ SMTP: FireEyeから受信したメールをEXOに転送
#   - 内部DMZ SMTP: EXOのフォールバック用（Internal Relay経由）
#
# 【前提条件】
#   - root権限で実行
#   - 対象ドメイン一覧ファイル（domains.txt）を用意
#   - EXOテナントのMXホスト名を確認済み
#
# 【使用例】
#   # AWS DMZ SMTP: EXOへのルーティング追加（ドライラン）
#   sudo bash Set-DmzSmtpRouting.sh -d domains.txt -m tenant.mail.protection.outlook.com -n
#
#   # 本番実行
#   sudo bash Set-DmzSmtpRouting.sh -d domains.txt -m tenant.mail.protection.outlook.com
#
#   # 内部DMZ SMTP: 移行対象ドメインをEXOに転送（フォールバック経路から除外）
#   sudo bash Set-DmzSmtpRouting.sh -d domains.txt -m tenant.mail.protection.outlook.com
#
#   # ロールバック
#   sudo bash Set-DmzSmtpRouting.sh -r /etc/postfix/transport.backup.20260117_120000
#
#===============================================================================

set -e

# デフォルト値
DOMAINS_FILE=""
MX_HOST=""
DRY_RUN=false
ROLLBACK_FILE=""
TRANSPORT_FILE="/etc/postfix/transport"
REMOVE_FROM_COURIER=false
COURIER_HOST=""
TS=$(date +%Y%m%d_%H%M%S)
OUTDIR="/tmp/dmz_smtp_routing_change_$TS"

# 使用方法
usage() {
  cat <<EOF
使用方法: $0 [オプション]

オプション:
  -d FILE     対象ドメイン一覧ファイル（1行1ドメイン、#でコメント）
  -m HOST     EXOのMXホスト名（例: tenant.mail.protection.outlook.com）
  -n          ドライラン（実際には変更しない）
  -r FILE     ロールバック（指定したバックアップファイルから復元）
  -t FILE     transport ファイルのパス（デフォルト: /etc/postfix/transport）
  -c HOST     既存のCourier IMAP転送先ホスト（移行対象ドメインを除外する場合）
  -h          このヘルプを表示

例:
  # AWS DMZ: 移行対象ドメインをEXOにルーティング（ドライラン）
  sudo bash $0 -d domains.txt -m tenant.mail.protection.outlook.com -n

  # 本番実行
  sudo bash $0 -d domains.txt -m tenant.mail.protection.outlook.com

  # ロールバック
  sudo bash $0 -r /etc/postfix/transport.backup.20260117_120000

注意:
  - このスクリプトは AWS DMZ SMTP と 内部DMZ SMTP の両方で使用できます
  - 内部DMZ SMTP で使用する場合は、EXOのInternal Relay設定と連携します

EOF
  exit 1
}

# オプション解析
while getopts "d:m:nr:t:c:h" opt; do
  case $opt in
    d) DOMAINS_FILE="$OPTARG" ;;
    m) MX_HOST="$OPTARG" ;;
    n) DRY_RUN=true ;;
    r) ROLLBACK_FILE="$OPTARG" ;;
    t) TRANSPORT_FILE="$OPTARG" ;;
    c) COURIER_HOST="$OPTARG"; REMOVE_FROM_COURIER=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

# 出力ディレクトリ作成
mkdir -p "$OUTDIR"
exec > >(tee -a "$OUTDIR/run.log") 2>&1

echo "============================================================"
echo " DMZ SMTP ルーティング設定変更"
echo "============================================================"
echo "実行日時: $(date)"
echo "ホスト名: $(hostname)"
echo "出力先:   $OUTDIR"
echo ""

#----------------------------------------------------------------------
# ロールバックモード
#----------------------------------------------------------------------
if [ -n "$ROLLBACK_FILE" ]; then
  echo "【ロールバックモード】"
  echo "  バックアップファイル: $ROLLBACK_FILE"
  echo ""
  
  if [ ! -f "$ROLLBACK_FILE" ]; then
    echo "エラー: バックアップファイルが見つかりません: $ROLLBACK_FILE"
    exit 1
  fi
  
  # 現在のファイルをバックアップ
  BACKUP_CURRENT="${TRANSPORT_FILE}.before_rollback.${TS}"
  echo "[1/3] 現在の設定をバックアップ..."
  cp "$TRANSPORT_FILE" "$BACKUP_CURRENT"
  echo "      → 保存: $BACKUP_CURRENT"
  
  # 復元
  echo ""
  echo "[2/3] バックアップから復元..."
  cp "$ROLLBACK_FILE" "$TRANSPORT_FILE"
  echo "      → 復元完了: $TRANSPORT_FILE"
  
  # postmap と reload
  echo ""
  echo "[3/3] Postfix設定を反映..."
  postmap "$TRANSPORT_FILE"
  echo "      → postmap 実行完了"
  
  postfix reload
  echo "      → postfix reload 完了"
  
  echo ""
  echo "============================================================"
  echo " ロールバック完了"
  echo "============================================================"
  exit 0
fi

#----------------------------------------------------------------------
# 通常モード：パラメータチェック
#----------------------------------------------------------------------
if [ -z "$DOMAINS_FILE" ]; then
  echo "エラー: ドメイン一覧ファイルを指定してください（-d オプション）"
  echo ""
  usage
fi

if [ -z "$MX_HOST" ]; then
  echo "エラー: EXOのMXホスト名を指定してください（-m オプション）"
  echo ""
  usage
fi

if [ ! -f "$DOMAINS_FILE" ]; then
  echo "エラー: ドメインファイルが見つかりません: $DOMAINS_FILE"
  exit 1
fi

if [ "$DRY_RUN" = true ]; then
  echo "【ドライランモード】実際の変更は行いません"
  echo ""
fi

echo "パラメータ:"
echo "  ドメインファイル:   $DOMAINS_FILE"
echo "  MXホスト:           $MX_HOST"
echo "  transportファイル:  $TRANSPORT_FILE"
if [ "$REMOVE_FROM_COURIER" = true ]; then
  echo "  Courier転送先:      $COURIER_HOST（移行対象ドメインを除外）"
fi
echo ""

#----------------------------------------------------------------------
# ドメイン一覧読み込み
#----------------------------------------------------------------------
echo "[1/6] ドメイン一覧を読み込み..."
DOMAINS=()
while IFS= read -r line || [ -n "$line" ]; do
  line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -z "$line" ] || [[ "$line" == \#* ]]; then
    continue
  fi
  DOMAINS+=("$line")
done < "$DOMAINS_FILE"

echo "      → 対象ドメイン: ${#DOMAINS[@]} 件"
for d in "${DOMAINS[@]}"; do
  echo "        - $d"
done
echo ""

if [ ${#DOMAINS[@]} -eq 0 ]; then
  echo "エラー: 対象ドメインがありません"
  exit 1
fi

#----------------------------------------------------------------------
# 現在の設定を分析
#----------------------------------------------------------------------
echo "[2/6] 現在のtransport設定を分析..."

if [ -f "$TRANSPORT_FILE" ]; then
  echo "      → 現在のエントリ数: $(grep -v '^#' "$TRANSPORT_FILE" | grep -v '^$' | wc -l) 行"
  
  # 既存のルーティングを確認
  echo ""
  echo "      【現在のルーティング設定】"
  grep -v '^#' "$TRANSPORT_FILE" | grep -v '^$' | head -20 | sed 's/^/        /'
  TOTAL_LINES=$(grep -v '^#' "$TRANSPORT_FILE" | grep -v '^$' | wc -l)
  if [ "$TOTAL_LINES" -gt 20 ]; then
    echo "        ... (残り $((TOTAL_LINES - 20)) 行)"
  fi
else
  echo "      → transport ファイルが存在しません。新規作成します。"
fi

#----------------------------------------------------------------------
# 現在の設定をバックアップ
#----------------------------------------------------------------------
echo ""
echo "[3/6] 現在のtransport設定をバックアップ..."
BACKUP_FILE="${TRANSPORT_FILE}.backup.${TS}"

if [ -f "$TRANSPORT_FILE" ]; then
  cp "$TRANSPORT_FILE" "$BACKUP_FILE"
  echo "      → 保存: $BACKUP_FILE"
  cp "$TRANSPORT_FILE" "$OUTDIR/transport_before.txt"
else
  touch "$OUTDIR/transport_before.txt"
fi

#----------------------------------------------------------------------
# 新しいルーティングエントリを生成
#----------------------------------------------------------------------
echo ""
echo "[4/6] 新しいルーティングエントリを生成..."

# 追加するエントリを準備
{
  echo ""
  echo "# === EXO Migration Routing - DMZ SMTP (Added: $TS) ==="
  echo "# 以下のドメインはExchange Onlineにルーティングされます"
  echo "# MXホスト: $MX_HOST"
  echo "# 元ファイル: $DOMAINS_FILE"
  echo "# ロールバック: sudo bash Set-DmzSmtpRouting.sh -r $BACKUP_FILE"
  echo ""
  for d in "${DOMAINS[@]}"; do
    # MXホストを[]で囲む（DNSルックアップをスキップ）
    echo "$d    smtp:[$MX_HOST]"
  done
  echo ""
  echo "# === End of EXO Migration Routing - DMZ SMTP ==="
} > "$OUTDIR/routing_entries.txt"

echo "      → 生成されたエントリ:"
cat "$OUTDIR/routing_entries.txt" | sed 's/^/        /'
echo ""

#----------------------------------------------------------------------
# 既存の内部ドメインルーティングとの競合チェック
#----------------------------------------------------------------------
echo "[5/6] 既存ルーティングとの競合チェック..."

CONFLICTS=()
if [ -f "$TRANSPORT_FILE" ]; then
  for d in "${DOMAINS[@]}"; do
    # 既存エントリに同じドメインがあるかチェック
    EXISTING=$(grep -E "^${d}[[:space:]]" "$TRANSPORT_FILE" 2>/dev/null | head -1 || true)
    if [ -n "$EXISTING" ]; then
      CONFLICTS+=("$EXISTING")
    fi
  done
fi

if [ ${#CONFLICTS[@]} -gt 0 ]; then
  echo "      → 警告: ${#CONFLICTS[@]} 件の既存エントリと競合します"
  echo ""
  echo "      【競合するエントリ】"
  for c in "${CONFLICTS[@]}"; do
    echo "        $c"
  done
  echo ""
  echo "      → 新しいエントリで上書きされます（既存エントリは削除）"
fi

#----------------------------------------------------------------------
# 設定を適用
#----------------------------------------------------------------------
echo ""
echo "[6/6] 設定を適用..."

if [ "$DRY_RUN" = true ]; then
  echo "      → ドライランのため、実際の変更はスキップ"
  
  # 想定される最終状態を出力
  {
    if [ -f "$TRANSPORT_FILE" ]; then
      # 競合するエントリを除外してコピー
      while IFS= read -r line; do
        SKIP=false
        for d in "${DOMAINS[@]}"; do
          if [[ "$line" =~ ^${d}[[:space:]] ]]; then
            SKIP=true
            break
          fi
        done
        if [ "$SKIP" = false ]; then
          echo "$line"
        fi
      done < "$TRANSPORT_FILE"
    fi
    cat "$OUTDIR/routing_entries.txt"
  } > "$OUTDIR/transport_after_dryrun.txt"
  
  echo "      → 想定される最終状態: $OUTDIR/transport_after_dryrun.txt"
else
  # 既存のEXO関連エントリを削除（重複防止）
  if [ -f "$TRANSPORT_FILE" ]; then
    # EXO Migrationセクションを削除
    sed -i.tmp '/# === EXO Migration Routing - DMZ SMTP/,/# === End of EXO Migration Routing - DMZ SMTP ===/d' "$TRANSPORT_FILE" 2>/dev/null || true
    
    # 移行対象ドメインの既存エントリを削除
    for d in "${DOMAINS[@]}"; do
      sed -i.tmp "/^${d}[[:space:]]/d" "$TRANSPORT_FILE" 2>/dev/null || true
    done
    rm -f "${TRANSPORT_FILE}.tmp"
  fi
  
  # 新しいエントリを追加
  cat "$OUTDIR/routing_entries.txt" >> "$TRANSPORT_FILE"
  echo "      → エントリを追加完了: $TRANSPORT_FILE"
  
  # 最終状態を保存
  cp "$TRANSPORT_FILE" "$OUTDIR/transport_after.txt"
  
  # transport_maps が設定されているか確認
  TRANSPORT_MAPS=$(postconf -h transport_maps 2>/dev/null || true)
  if [ -z "$TRANSPORT_MAPS" ] || [[ "$TRANSPORT_MAPS" != *"hash:$TRANSPORT_FILE"* ]]; then
    echo "      → 警告: transport_maps に $TRANSPORT_FILE が設定されていません"
    echo "      → 以下のコマンドで設定してください:"
    echo "        postconf -e 'transport_maps = hash:$TRANSPORT_FILE'"
  fi
  
  # postmap実行
  postmap "$TRANSPORT_FILE"
  echo "      → postmap 実行完了"
  
  # postfix reload
  postfix reload
  echo "      → postfix reload 完了"
fi

#----------------------------------------------------------------------
# サマリー出力
#----------------------------------------------------------------------
echo ""
echo "============================================================"
echo " 完了"
echo "============================================================"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "【ドライラン結果】"
  echo "  実際の変更は行われていません。"
  echo "  問題がなければ -n オプションなしで再実行してください:"
  echo ""
  echo "  sudo bash $0 -d $DOMAINS_FILE -m $MX_HOST"
else
  echo "【変更完了】"
  echo "  バックアップ: $BACKUP_FILE"
  echo ""
  echo "【ロールバック方法】"
  echo "  問題が発生した場合は以下のコマンドで元に戻せます:"
  echo ""
  echo "  sudo bash $0 -r $BACKUP_FILE"
fi

echo ""
echo "【メールフロー変更後の確認】"
echo "  1. テストメールを送信（移行対象ドメイン宛）"
echo "  2. メールログを確認:"
echo "     tail -f /var/log/maillog | grep -E 'postfix|smtp'"
echo "  3. EXOのMessage Traceで受信を確認"
echo ""
echo "【注意事項】"
echo "  - この変更により、移行対象ドメイン宛のメールはEXOに転送されます"
echo "  - EXO側でAccepted DomainがInternal Relayに設定されていることを確認してください"
echo "  - 未移行ユーザー宛のメールはEXOから内部DMZ SMTPにフォールバックされます"
echo ""
echo "出力先: $OUTDIR"
