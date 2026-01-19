#!/usr/bin/env bash
#===============================================================================
# Postfix設定棚卸しスクリプト（強化版）
#===============================================================================
#
# 【目的】
#   Postfixメールサーバーの設定情報を収集し、EXO移行計画に必要な情報を取得する
#
# 【収集する情報】
#   - メールフロー設定（relayhost, transport_maps等）
#   - サイズ制限（message_size_limit等）
#   - TLS/暗号化設定
#   - 仮想ドメイン・エイリアス設定
#   - master.cf/main.cf構成（postconf -M/-P）
#   - postmulti対応
#   - systemctl/journalctl ログ
#   - SMTPポート（25/587/465）リスン状態とキュー件数
#
# 【出力先】
#   ./inventory_YYYYMMDD_HHMMSS/postfix_<ホスト名>/
#
# 【実行方法】
#   sudo bash collect_postfix.sh [出力先ディレクトリ]
#
# 【出力ファイルと確認ポイント】
#   postconf-n.txt      ← ★重要: 有効な設定一覧（デフォルトから変更された項目のみ）
#   postconf-n.json     ← 詳細データ（機械可読、=を含む値にも対応）
#   postconf-M.txt      ← master.cfサービス定義
#   postconf-P.txt      ← master.cfパラメータ上書き
#   key_params.txt      ← ★重要: メールフロー・サイズ制限の主要パラメータ抜粋
#   smtp_ports.txt      ← SMTPポート（25/587/465）リスン状態
#   queue_count.txt     ← キュー件数
#   systemctl_status.txt← systemctl status postfix
#   journalctl_tail.txt ← journalctl -u postfix（最新500行）
#   etc_postfix.tgz     ← /etc/postfix配下の設定ファイル原本（秘密鍵・パスワード除外）
#   maps/               ← transport, virtual等のマップファイル（パスワード除外）
#   summary.json        ← サマリー情報（機械可読）
#
#===============================================================================
set -euo pipefail
umask 027
export LC_ALL=C

# タイムスタンプとホスト名を取得
TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUTROOT="${1:-./inventory_${TS}}"
OUTDIR="${OUTROOT}/postfix_${HOST}"
mkdir -p "$OUTDIR"

# 後片付け関数
cleanup() {
  echo ""
  echo "後片付け実行中..."
  # 一時ファイルの削除（必要に応じて）
}

# trap設定（EXIT, ERR, INT, TERM時に後片付けを実行）
trap cleanup EXIT ERR INT TERM

# 実行ログを記録開始
exec > >(tee -a "$OUTDIR/run.log") 2>&1

echo "============================================================"
echo " Postfix 設定棚卸し（強化版）"
echo "============================================================"
echo "実行日時: $TS"
echo "ホスト名: $HOST"
echo "出力先:   $OUTDIR"
echo ""

#----------------------------------------------------------------------
# 1. システム情報の取得
#----------------------------------------------------------------------
echo "[1/14] システム情報を取得中..."
uname -a | tee "$OUTDIR/uname.txt"
id | tee "$OUTDIR/id.txt"
date -Is | tee "$OUTDIR/date.txt"
ps auxww | head -n 200 | tee "$OUTDIR/ps_head.txt" >/dev/null || true

# リスニングポート確認（ssがなければnetstatにフォールバック）
echo ""
echo "  → リスニングポートを確認..."
if command -v ss >/dev/null 2>&1; then
  ss -lntup > "$OUTDIR/ss_listen.txt" 2>/dev/null || true
elif command -v netstat >/dev/null 2>&1; then
  netstat -tlnp > "$OUTDIR/ss_listen.txt" 2>/dev/null || true
else
  echo "ss/netstat が見つかりません" > "$OUTDIR/ss_listen.txt"
fi

#----------------------------------------------------------------------
# 2. Postfixバージョン・状態確認
#----------------------------------------------------------------------
echo ""
echo "[2/14] Postfixバージョン・状態を確認中..."

# postconfコマンドの存在確認
if ! command -v postconf >/dev/null 2>&1; then
  echo "エラー: postconfコマンドが見つかりません。Postfixがインストールされていますか？"
  exit 1
fi

MAIL_VERSION=$(postconf -h mail_version 2>/dev/null || echo "unknown")
echo "$MAIL_VERSION" | tee "$OUTDIR/postfix_version.txt"
postfix status 2>&1 | tee "$OUTDIR/postfix_status.txt" || true

#----------------------------------------------------------------------
# 3. config_directory動的取得
#----------------------------------------------------------------------
echo ""
echo "[3/14] config_directory動的取得中..."
CONFIG_DIR=$(postconf -h config_directory 2>/dev/null || echo "/etc/postfix")
echo "  → config_directory: $CONFIG_DIR"
echo "$CONFIG_DIR" > "$OUTDIR/config_directory.txt"

#----------------------------------------------------------------------
# 4. postmulti対応（マルチインスタンス検出）
#----------------------------------------------------------------------
echo ""
echo "[4/14] postmulti対応（マルチインスタンス検出）..."
if command -v postmulti >/dev/null 2>&1; then
  postmulti -l > "$OUTDIR/postmulti_list.txt" 2>/dev/null || echo "postmulti対応なし" > "$OUTDIR/postmulti_list.txt"
  MULTI_COUNT=$(grep -c '^[^#]' "$OUTDIR/postmulti_list.txt" 2>/dev/null || echo 0)
  echo "  → マルチインスタンス数: $MULTI_COUNT"
else
  echo "postmulti未サポート" > "$OUTDIR/postmulti_list.txt"
  MULTI_COUNT=0
fi

#----------------------------------------------------------------------
# 5. postconf -M/-P（master.cf定義）
#----------------------------------------------------------------------
echo ""
echo "[5/14] ★ master.cf定義を取得中（postconf -M/-P）..."
postconf -M > "$OUTDIR/postconf-M.txt" 2>/dev/null || echo "postconf -M 未サポート" > "$OUTDIR/postconf-M.txt"
postconf -P > "$OUTDIR/postconf-P.txt" 2>/dev/null || echo "postconf -P 未サポート" > "$OUTDIR/postconf-P.txt"

#----------------------------------------------------------------------
# 6. 有効な設定の取得（postconf -n）改善版JSON化
#----------------------------------------------------------------------
echo ""
echo "[6/14] ★ 有効な設定を取得中（postconf -n）..."
echo "  → このファイル(postconf-n.txt)でメールフローの設定が確認できます"
postconf -n > "$OUTDIR/postconf-n.txt" || true

# JSON形式でも出力（=を含む値に対応）
echo "  → JSON形式で出力中（=を含む値に対応）..."
{
  echo "{"
  echo "  \"timestamp\": \"$TS\","
  echo "  \"hostname\": \"$HOST\","
  echo "  \"postfix_config\": {"
  first=true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # 最初の=で分割（値に=が含まれていても正しく処理）
    key="${line%%=*}"
    value="${line#*=}"

    if [ "$first" = true ]; then
      first=false
    else
      echo ","
    fi

    # JSON文字列エスケープ
    key_esc=$(echo "$key" | sed 's/\\/\\\\/g; s/"/\\"/g' | xargs)
    value_esc=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g')
    echo -n "    \"$key_esc\": \"$value_esc\""
  done < "$OUTDIR/postconf-n.txt"
  echo ""
  echo "  }"
  echo "}"
} > "$OUTDIR/postconf-n.json"

#----------------------------------------------------------------------
# 7. 全設定の取得（検索・grep用）
#----------------------------------------------------------------------
echo ""
echo "[7/14] 全設定を取得中（postconf）..."
postconf > "$OUTDIR/postconf-all.txt" || true

#----------------------------------------------------------------------
# 8. ★重要：メールフロー・サイズ制限の主要パラメータ抽出
#----------------------------------------------------------------------
echo ""
echo "[8/14] ★ 主要パラメータを抽出中..."
echo "  → key_params.txt でメールフローとサイズ制限を確認できます"

# 抽出対象パラメータ（日本語コメント付きで出力）
cat > "$OUTDIR/key_params.txt" << 'HEADER'
#===============================================================================
# Postfix 主要パラメータ一覧
#===============================================================================
#
# 【メールフロー関連】★EXO移行時の確認必須
#   relayhost              : 外部へのメール転送先（空欄=直接配送）
#   relay_domains          : リレーを許可するドメイン
#   transport_maps         : ドメイン別の配送先定義 ← ★移行時に書き換え
#   mydestination          : ローカル配送するドメイン
#   virtual_alias_maps     : 仮想エイリアス定義
#   virtual_mailbox_maps   : 仮想メールボックス定義
#
# 【サイズ制限】★EXOとの整合確認
#   message_size_limit     : 1通のメール最大サイズ（EXO: 送信35MB/受信36MB）
#   mailbox_size_limit     : メールボックス最大サイズ
#
# 【TLS/セキュリティ】
#   smtpd_tls_*           : 受信時のTLS設定
#   smtp_tls_*            : 送信時のTLS設定
#
#===============================================================================

HEADER

# パラメータを抽出して追記
postconf -n | grep -Ei \
'^(myhostname|mydomain|myorigin|mydestination|relayhost|relay_domains|transport_maps|virtual_alias_maps|virtual_mailbox_maps|sender_dependent_relayhost_maps|smtp_tls|smtpd_tls|smtpd_recipient_restrictions|smtpd_sender_restrictions|message_size_limit|mailbox_size_limit|header_size_limit|body_checks|header_checks|content_filter|milter|smtpd_milters|non_smtpd_milters|smtp_tls_policy_maps)=' \
>> "$OUTDIR/key_params.txt" 2>/dev/null || true

#----------------------------------------------------------------------
# 9. 設定ファイル原本のアーカイブ（秘密鍵・パスワード除外）
#----------------------------------------------------------------------
echo ""
echo "[9/14] $CONFIG_DIR 配下を圧縮アーカイブ中..."
echo "  → 秘密鍵(.key, .pem等)とパスワードファイルは除外します"
if [ -d "$CONFIG_DIR" ]; then
  # 秘密鍵とパスワードファイル、.db/.dirファイルを除外してアーカイブ
  tar -czf "$OUTDIR/etc_postfix.tgz" -C "$(dirname "$CONFIG_DIR")" \
    --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
    --exclude='*.csr' --exclude='*.crt.key' \
    --exclude='sasl_passwd*' --exclude='*password*' \
    --exclude='*.db' --exclude='*.dir' --exclude='*.pag' \
    "$(basename "$CONFIG_DIR")" 2>/dev/null || true
  echo "  → 保存完了: $OUTDIR/etc_postfix.tgz（秘密鍵・パスワード・DBファイル除外）"
else
  echo "  → $CONFIG_DIR が見つかりません"
fi

#----------------------------------------------------------------------
# 10. マップファイルの参照抽出と実体コピー（機密名マスク）
#----------------------------------------------------------------------
echo ""
echo "[10/14] マップファイルの参照抽出と実体コピー..."
echo "  → 設定で参照されているマップファイルを自動検出します"
MAPS_DIR="$OUTDIR/maps"
mkdir -p "$MAPS_DIR"

# 設定内で参照されているマップファイルを検索
grep -RIn --color=never -E '(_maps|check_.*_access|hash:|lmdb:|btree:|regexp:|pcre:|texthash:|cidr:)' "$CONFIG_DIR" \
  > "$OUTDIR/map_references_grep.txt" 2>/dev/null || true

# マップファイルパスを抽出
> "$OUTDIR/map_files_detected.txt"
while IFS= read -r line; do
  # hash:/path/to/file や lmdb:/path 形式を抽出
  echo "$line" | grep -oE '(hash|lmdb|btree|regexp|pcre|texthash|cidr):[^ ,]+' | \
    sed 's/^[^:]*://; s/[,;].*$//' >> "$OUTDIR/map_files_detected.txt" || true
done < "$OUTDIR/map_references_grep.txt"

# ユニーク化
sort -u "$OUTDIR/map_files_detected.txt" -o "$OUTDIR/map_files_detected.txt"

# 検出されたマップファイルをコピー（パスワード含むものはマスク）
echo "  → 検出されたマップファイルをコピー中..."
MAP_COUNT=0
while IFS= read -r mapfile; do
  [ -z "$mapfile" ] && continue

  # .dbや.dirを除いた実体ファイルを探す
  for candidate in "$mapfile" "${mapfile%.db}" "${mapfile%.dir}"; do
    if [ -f "$candidate" ]; then
      MAP_COUNT=$((MAP_COUNT+1))

      # パスワードを含むファイルはマスク
      if [[ "$candidate" == *sasl_passwd* ]] || [[ "$candidate" == *password* ]]; then
        sed -E 's/^([^:]+):(.*)$/\1:***MASKED***/' "$candidate" > "$MAPS_DIR/$(basename "$candidate").masked" 2>/dev/null || true
        echo "    ✓ マスク済み: $candidate → $(basename "$candidate").masked"
      else
        cp -a "$candidate" "$MAPS_DIR/" 2>/dev/null || true
        echo "    ✓ コピー: $candidate"
      fi
      break
    fi
  done
done < "$OUTDIR/map_files_detected.txt"

echo "  → マップファイル検出数: $MAP_COUNT"

#----------------------------------------------------------------------
# 11. systemctl/journal取得
#----------------------------------------------------------------------
echo ""
echo "[11/14] systemctl/journalctl取得中..."

# systemctl status
if command -v systemctl >/dev/null 2>&1; then
  systemctl status postfix --no-pager --full > "$OUTDIR/systemctl_status.txt" 2>&1 || echo "systemctl status取得失敗" > "$OUTDIR/systemctl_status.txt"
  echo "  → systemctl status postfix 取得完了"
else
  echo "systemctl未サポート" > "$OUTDIR/systemctl_status.txt"
fi

# journalctl（最新500行）
if command -v journalctl >/dev/null 2>&1; then
  journalctl -u postfix -n 500 --no-pager --full > "$OUTDIR/journalctl_tail.txt" 2>/dev/null || echo "journalctl取得失敗" > "$OUTDIR/journalctl_tail.txt"
  echo "  → journalctl -u postfix（最新500行）取得完了"
else
  echo "journalctl未サポート" > "$OUTDIR/journalctl_tail.txt"

  # フォールバック：従来のログファイル
  for lf in /var/log/maillog /var/log/mail.log; do
    if [ -f "$lf" ]; then
      tail -n 500 "$lf" > "$OUTDIR/mail_log_tail_500.txt"
      echo "  → フォールバック: $lf（最新500行）取得完了"
      break
    fi
  done
fi

#----------------------------------------------------------------------
# 12. SMTPポート（25/587/465）リスン状態とキュー件数
#----------------------------------------------------------------------
echo ""
echo "[12/14] SMTPポート（25/587/465）リスン状態とキュー件数を取得中..."

# ポートリスン状態
{
  echo "# SMTPポート リスン状態"
  echo "# 作成日時: $TS"
  echo ""

  for port in 25 587 465; do
    echo "【ポート :$port】"
    if grep -q ":$port " "$OUTDIR/ss_listen.txt" 2>/dev/null; then
      grep ":$port " "$OUTDIR/ss_listen.txt"
      echo "  → ✓ リスン中"
    else
      echo "  → × リスンしていません"
    fi
    echo ""
  done
} > "$OUTDIR/smtp_ports.txt"

echo "  → SMTPポート状態: $OUTDIR/smtp_ports.txt"

# キュー件数
{
  echo "# Postfixキュー件数"
  echo "# 作成日時: $TS"
  echo ""

  if command -v postqueue >/dev/null 2>&1; then
    postqueue -p 2>&1 | head -n 500 | tee "$OUTDIR/postqueue_head.txt" >/dev/null || true

    # キュー件数を抽出
    QUEUE_COUNT=$(postqueue -p 2>/dev/null | tail -1 | grep -oE '[0-9]+ Requests?' | grep -oE '[0-9]+' || echo 0)
    echo "キュー件数: $QUEUE_COUNT"
    echo ""
    echo "詳細: postqueue_head.txt を参照"
  else
    echo "postqueue コマンドが見つかりません"
    QUEUE_COUNT=0
  fi
} > "$OUTDIR/queue_count.txt"

echo "  → キュー件数: $QUEUE_COUNT"

#----------------------------------------------------------------------
# 13. サイズ制限・TLS設定の抽出
#----------------------------------------------------------------------
echo ""
echo "[13/14] サイズ制限・TLS設定を抽出中..."

# サイズ制限
postconf | grep -Ei 'message_size_limit|mailbox_size_limit|header_size_limit|body_checks' \
  > "$OUTDIR/size_limits.txt" 2>/dev/null || true

# TLS証明書パス
postconf | grep -Ei 'smtpd_tls_cert_file|smtpd_tls_key_file|smtp_tls_cert_file|smtp_tls_key_file|smtpd_tls_CAfile|smtp_tls_CAfile' \
  > "$OUTDIR/tls_cert_paths.txt" 2>/dev/null || true

#----------------------------------------------------------------------
# 14. サマリーJSONの作成
#----------------------------------------------------------------------
echo ""
echo "[14/14] サマリーJSONを作成中..."

# 主要パラメータを抽出
MESSAGE_SIZE_LIMIT=$(postconf -h message_size_limit 2>/dev/null || echo "unknown")
RELAYHOST=$(postconf -h relayhost 2>/dev/null || echo "")
SMTP_25=$(grep -q ":25 " "$OUTDIR/ss_listen.txt" 2>/dev/null && echo "listening" || echo "not listening")
SMTP_587=$(grep -q ":587 " "$OUTDIR/ss_listen.txt" 2>/dev/null && echo "listening" || echo "not listening")
SMTP_465=$(grep -q ":465 " "$OUTDIR/ss_listen.txt" 2>/dev/null && echo "listening" || echo "not listening")

cat > "$OUTDIR/summary.json" << EOF
{
  "timestamp": "$TS",
  "hostname": "$HOST",
  "postfix_version": "$MAIL_VERSION",
  "config_directory": "$CONFIG_DIR",
  "multi_instance_count": $MULTI_COUNT,
  "key_settings": {
    "message_size_limit": "$MESSAGE_SIZE_LIMIT",
    "relayhost": "$RELAYHOST"
  },
  "smtp_ports": {
    "port_25": "$SMTP_25",
    "port_587": "$SMTP_587",
    "port_465": "$SMTP_465"
  },
  "queue_count": $QUEUE_COUNT,
  "map_files_detected": $MAP_COUNT,
  "output_files": {
    "config_active": "postconf-n.txt",
    "config_active_json": "postconf-n.json",
    "config_all": "postconf-all.txt",
    "master_services": "postconf-M.txt",
    "master_params": "postconf-P.txt",
    "key_params": "key_params.txt",
    "size_limits": "size_limits.txt",
    "smtp_ports": "smtp_ports.txt",
    "queue_count": "queue_count.txt",
    "systemctl_status": "systemctl_status.txt",
    "journalctl_tail": "journalctl_tail.txt",
    "config_archive": "etc_postfix.tgz",
    "maps_directory": "maps/",
    "map_references": "map_references_grep.txt",
    "map_files_detected": "map_files_detected.txt"
  },
  "security_notes": "秘密鍵(.key, .pem等)とパスワードファイル(sasl_passwd等)は除外またはマスクされています。"
}
EOF

#----------------------------------------------------------------------
# 完了メッセージ
#----------------------------------------------------------------------
echo ""
echo "============================================================"
echo " 完了"
echo "============================================================"
echo ""
echo "【確認すべきファイル】"
echo ""
echo "  ★ postconf-n.txt / postconf-n.json"
echo "     → 有効な設定一覧（relayhost, transport_maps等を確認）"
echo ""
echo "  ★ postconf-M.txt / postconf-P.txt"
echo "     → master.cfサービス定義とパラメータ上書き"
echo ""
echo "  ★ key_params.txt"
echo "     → メールフロー・サイズ制限の主要パラメータ"
echo ""
echo "  ★ smtp_ports.txt"
echo "     → SMTPポート（25/587/465）リスン状態"
echo ""
echo "  ★ queue_count.txt"
echo "     → キュー件数: $QUEUE_COUNT"
echo ""
echo "  ★ maps/"
echo "     → 検出されたマップファイル: $MAP_COUNT 件"
echo ""
echo "  ★ systemctl_status.txt / journalctl_tail.txt"
echo "     → サービス状態とログ"
echo ""
echo "  ★ summary.json"
echo "     → サマリー情報（機械可読）"
echo ""
echo "【セキュリティ】"
echo "  - 秘密鍵(.key, .pem等)は収集されていません"
echo "  - パスワードファイル(sasl_passwd等)はマスクされています"
echo "  - .db/.dir/.pagファイルは除外されています"
echo ""
echo "【マルチインスタンス】"
echo "  - 検出数: $MULTI_COUNT"
echo ""
echo "出力先: $OUTDIR"
