#!/usr/bin/env bash
#===============================================================================
# Postfix設定棚卸しスクリプト
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
#
# 【出力先】
#   ./inventory_YYYYMMDD_HHMMSS/postfix_<ホスト名>/
#
# 【実行方法】
#   sudo bash collect_postfix.sh [出力先ディレクトリ]
#
# 【出力ファイルと確認ポイント】
#   postconf-n.txt      ← ★重要: 有効な設定一覧（デフォルトから変更された項目のみ）
#   postconf-n.json     ← 詳細データ（機械可読）
#   key_params.txt      ← ★重要: メールフロー・サイズ制限の主要パラメータ抜粋
#   size_limits.txt     ← サイズ制限設定（EXOとの整合確認用）
#   tls_cert_paths.txt  ← TLS証明書のパス（移行時の参考）
#   etc_postfix.tgz     ← /etc/postfix配下の設定ファイル原本（秘密鍵・パスワード除外）
#   maps/               ← transport, virtual等のマップファイル（パスワード除外）
#   summary.json        ← サマリー情報（機械可読）
#
#===============================================================================
set -euo pipefail

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
echo " Postfix 設定棚卸し"
echo "============================================================"
echo "実行日時: $TS"
echo "ホスト名: $HOST"
echo "出力先:   $OUTDIR"
echo ""

#----------------------------------------------------------------------
# 1. システム情報の取得
#----------------------------------------------------------------------
echo "[1/9] システム情報を取得中..."
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
echo "[2/9] Postfixバージョン・状態を確認中..."

# postconfコマンドの存在確認
if ! command -v postconf >/dev/null 2>&1; then
  echo "エラー: postconfコマンドが見つかりません。Postfixがインストールされていますか？"
  exit 1
fi

postconf -h mail_version 2>/dev/null | tee "$OUTDIR/postfix_version.txt" || true
postfix status 2>&1 | tee "$OUTDIR/postfix_status.txt" || true
postqueue -p 2>&1 | head -n 200 | tee "$OUTDIR/postqueue_head.txt" >/dev/null || true

#----------------------------------------------------------------------
# 3. 有効な設定の取得（★重要：メールフロー確認の主要ソース）
#----------------------------------------------------------------------
echo ""
echo "[3/9] ★ 有効な設定を取得中（postconf -n）..."
echo "  → このファイル(postconf-n.txt)でメールフローの設定が確認できます"
postconf -n > "$OUTDIR/postconf-n.txt" || true

# JSON形式でも出力
echo "  → JSON形式で出力中..."
{
  echo "{"
  echo "  \"timestamp\": \"$TS\","
  echo "  \"hostname\": \"$HOST\","
  echo "  \"postfix_config\": {"
  first=true
  while IFS='=' read -r key value; do
    [ -z "$key" ] && continue
    if [ "$first" = true ]; then
      first=false
    else
      echo ","
    fi
    # JSON文字列エスケープ
    key_esc=$(echo "$key" | sed 's/\\/\\\\/g; s/"/\\"/g' | xargs)
    value_esc=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g' | xargs)
    echo -n "    \"$key_esc\": \"$value_esc\""
  done < "$OUTDIR/postconf-n.txt"
  echo ""
  echo "  }"
  echo "}"
} > "$OUTDIR/postconf-n.json"

#----------------------------------------------------------------------
# 4. 全設定の取得（検索・grep用）
#----------------------------------------------------------------------
echo ""
echo "[4/9] 全設定を取得中（postconf）..."
postconf > "$OUTDIR/postconf-all.txt" || true

#----------------------------------------------------------------------
# 5. ★重要：メールフロー・サイズ制限の主要パラメータ抽出
#----------------------------------------------------------------------
echo ""
echo "[5/9] ★ 主要パラメータを抽出中..."
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
# 6. 設定ファイル原本のアーカイブ（秘密鍵・パスワード除外）
#----------------------------------------------------------------------
echo ""
echo "[6/9] /etc/postfix配下を圧縮アーカイブ中..."
echo "  → 秘密鍵(.key, .pem等)とパスワードファイルは除外します"
if [ -d /etc/postfix ]; then
  # 秘密鍵とパスワードファイルを除外してアーカイブ
  tar -czf "$OUTDIR/etc_postfix.tgz" -C /etc \
    --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
    --exclude='sasl_passwd*' --exclude='*password*' \
    postfix 2>/dev/null || true
  echo "  → 保存完了: $OUTDIR/etc_postfix.tgz（秘密鍵・パスワード除外）"
else
  echo "  → /etc/postfix が見つかりません"
fi

#----------------------------------------------------------------------
# 7. マップファイルのコピー（パスワードをマスク）
#----------------------------------------------------------------------
echo ""
echo "[7/9] マップファイルをコピー中..."
echo "  → transport, virtual等のファイルでドメイン別の配送設定を確認できます"
echo "  → パスワードを含むファイルはマスクします"
MAPS_DIR="$OUTDIR/maps"
mkdir -p "$MAPS_DIR"

# よく使われるマップファイルの候補
CANDIDATES=(
  /etc/postfix/transport
  /etc/postfix/virtual
  /etc/postfix/access
  /etc/postfix/recipient_access
  /etc/postfix/sender_access
  /etc/postfix/relay_recipients
  /etc/postfix/aliases
  /etc/aliases
  /etc/postfix/sasl_passwd
)

for f in "${CANDIDATES[@]}"; do
  if [ -f "$f" ]; then
    # sasl_passwd などパスワードを含むファイルはマスク
    if [[ "$f" == *sasl_passwd* ]] || [[ "$f" == *password* ]]; then
      sed -E 's/^([^:]+):(.*)$/\1:***MASKED***/' "$f" > "$MAPS_DIR/$(basename $f).masked" 2>/dev/null || true
      echo "  → マスク済み: $f → $(basename $f).masked"
    else
      cp -a "$f" "$MAPS_DIR/"
      echo "  → コピー: $f"
    fi
  fi
done

# 設定内で参照されているマップファイルを検索
echo ""
echo "  → 設定で参照されているマップファイルを検索..."
grep -RIn --color=never -E '(_maps|check_.*_access|hash:|lmdb:|btree:|regexp:|pcre:|texthash:|cidr:)' /etc/postfix \
  > "$OUTDIR/map_references_grep.txt" 2>/dev/null || true

#----------------------------------------------------------------------
# 8. サイズ制限・TLS設定の抽出
#----------------------------------------------------------------------
echo ""
echo "[8/9] サイズ制限・TLS設定を抽出中..."

# サイズ制限
postconf | grep -Ei 'message_size_limit|mailbox_size_limit|header_size_limit|body_checks' \
  > "$OUTDIR/size_limits.txt" 2>/dev/null || true

# TLS証明書パス
postconf | grep -Ei 'smtpd_tls_cert_file|smtpd_tls_key_file|smtp_tls_cert_file|smtp_tls_key_file|smtpd_tls_CAfile|smtp_tls_CAfile' \
  > "$OUTDIR/tls_cert_paths.txt" 2>/dev/null || true

#----------------------------------------------------------------------
# ログの取得（最新500行のみ、メール本文は含まない）
#----------------------------------------------------------------------
echo ""
echo "  → メールログの末尾を取得..."
for lf in /var/log/maillog /var/log/mail.log; do
  if [ -f "$lf" ]; then
    tail -n 500 "$lf" > "$OUTDIR/mail_log_tail_500.txt"
    echo "  → 取得: $lf (最新500行)"
    break
  fi
done

#----------------------------------------------------------------------
# 9. サマリーJSONの作成
#----------------------------------------------------------------------
echo ""
echo "[9/9] サマリーJSONを作成中..."

# 主要パラメータを抽出
MAIL_VERSION=$(postconf -h mail_version 2>/dev/null || echo "unknown")
MESSAGE_SIZE_LIMIT=$(postconf -h message_size_limit 2>/dev/null || echo "unknown")
RELAYHOST=$(postconf -h relayhost 2>/dev/null || echo "")

cat > "$OUTDIR/summary.json" << EOF
{
  "timestamp": "$TS",
  "hostname": "$HOST",
  "postfix_version": "$MAIL_VERSION",
  "key_settings": {
    "message_size_limit": "$MESSAGE_SIZE_LIMIT",
    "relayhost": "$RELAYHOST"
  },
  "output_files": {
    "config_active": "postconf-n.txt",
    "config_active_json": "postconf-n.json",
    "config_all": "postconf-all.txt",
    "key_params": "key_params.txt",
    "size_limits": "size_limits.txt",
    "config_archive": "etc_postfix.tgz",
    "maps_directory": "maps/"
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
echo "  ★ key_params.txt"
echo "     → メールフロー・サイズ制限の主要パラメータ"
echo ""
echo "  ★ maps/transport"
echo "     → ドメイン別の配送先定義（EXO移行時に書き換え対象）"
echo ""
echo "  ★ size_limits.txt"
echo "     → サイズ制限（EXOとの整合確認用）"
echo ""
echo "  ★ summary.json"
echo "     → サマリー情報（機械可読）"
echo ""
echo "【セキュリティ】"
echo "  - 秘密鍵(.key, .pem等)は収集されていません"
echo "  - パスワードファイル(sasl_passwd等)はマスクされています"
echo ""
echo "出力先: $OUTDIR"
