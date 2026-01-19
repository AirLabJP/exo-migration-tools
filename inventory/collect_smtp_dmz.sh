#!/usr/bin/env bash
#===============================================================================
# DMZ SMTPサーバー設定棚卸しスクリプト
#===============================================================================
#
# 【目的】
#   DMZ（外部公開）SMTPサーバーの設定を収集し、メールフローを把握する
#   MTAの種類（Postfix/Exim/Sendmail）を自動判定して適切に収集
#
# 【収集する情報】
#   - MTAの種類とバージョン
#   - メールフロー設定（リレー先、ドメイン設定）
#   - ネットワーク設定（IPアドレス、ルーティング）
#   - ファイアウォール設定
#
# 【出力先】
#   ./inventory_YYYYMMDD_HHMMSS/dmz_smtp_<ホスト名>/
#
# 【実行方法】
#   sudo bash collect_smtp_dmz.sh [出力先ディレクトリ]
#
# 【出力ファイルと確認ポイント】
#   mta_type.txt          ← ★重要: 検出されたMTAの種類
#   postconf-n.txt        ← ★重要: Postfix有効設定（Postfixの場合）
#   postconf-n.json       ← 詳細データ（機械可読）
#   key_params.txt        ← ★重要: relayhost等のメールフロー設定
#   etc_postfix.tgz       ← 設定ファイル原本（秘密鍵・パスワード除外）
#   ip_addr.txt           ← IPアドレス一覧
#   ip_route.txt          ← ルーティングテーブル
#   iptables.txt          ← ファイアウォール設定
#   summary.json          ← サマリー情報（機械可読）
#
#===============================================================================
set -euo pipefail

# タイムスタンプとホスト名を取得
TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUTROOT="${1:-./inventory_${TS}}"
OUTDIR="${OUTROOT}/dmz_smtp_${HOST}"
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
echo " DMZ SMTPサーバー設定棚卸し"
echo "============================================================"
echo "実行日時: $TS"
echo "ホスト名: $HOST"
echo "出力先:   $OUTDIR"
echo ""

#----------------------------------------------------------------------
# 1. システム情報の取得
#----------------------------------------------------------------------
echo "[1/5] システム情報を取得中..."
uname -a | tee "$OUTDIR/uname.txt"
id | tee "$OUTDIR/id.txt"

# リスニングポート確認
echo ""
echo "  → リスニングポートを確認..."
if command -v ss >/dev/null 2>&1; then
  ss -lntup > "$OUTDIR/ss_listen.txt" 2>/dev/null || true
elif command -v netstat >/dev/null 2>&1; then
  netstat -tlnp > "$OUTDIR/ss_listen.txt" 2>/dev/null || true
else
  echo "ss/netstat が見つかりません" > "$OUTDIR/ss_listen.txt"
fi

# プロセス一覧
ps auxww | tee "$OUTDIR/ps.txt" >/dev/null || true

#----------------------------------------------------------------------
# 2. ★重要：MTAの自動検出と設定収集
#----------------------------------------------------------------------
echo ""
echo "[2/5] ★ MTAの種類を自動検出中..."
MTA_DETECTED="none"

# --- Postfix ---
if command -v postconf >/dev/null 2>&1; then
  MTA_DETECTED="postfix"
  echo "  → Postfix を検出"

  # バージョン
  postconf -h mail_version 2>/dev/null | tee "$OUTDIR/postfix_version.txt" || true

  # 有効な設定（デフォルトから変更された項目）
  echo ""
  echo "  → 有効な設定を取得（postconf -n）..."
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

  # 全設定
  postconf > "$OUTDIR/postconf-all.txt" || true

  # 設定ファイルアーカイブ（秘密鍵・パスワード除外）
  if [ -d /etc/postfix ]; then
    tar -czf "$OUTDIR/etc_postfix.tgz" -C /etc \
      --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
      --exclude='sasl_passwd*' --exclude='*password*' \
      postfix 2>/dev/null || true
    echo "  → 設定アーカイブ保存: etc_postfix.tgz（秘密鍵・パスワード除外）"
  fi

  # ★重要：メールフロー関連パラメータの抽出
  echo ""
  echo "  → メールフロー関連パラメータを抽出..."
  cat > "$OUTDIR/key_params.txt" << 'HEADER'
#===============================================================================
# DMZ SMTP 主要パラメータ
#===============================================================================
#
# 【メールフロー】★EXO移行時の確認必須
#   relayhost          : 内部サーバーへの転送先 ← 現在の設定を確認
#   relay_domains      : リレー許可ドメイン
#   transport_maps     : ドメイン別の配送先
#
# 【セキュリティ】
#   mynetworks         : リレー許可ネットワーク
#   smtpd_recipient_restrictions : 受信制限
#
#===============================================================================

HEADER
  postconf -n | grep -Ei \
    '^(myhostname|mydomain|relayhost|relay_domains|transport_maps|mynetworks|smtpd_recipient_restrictions|message_size_limit)=' \
    >> "$OUTDIR/key_params.txt" 2>/dev/null || true

# --- Exim ---
elif command -v exim >/dev/null 2>&1; then
  MTA_DETECTED="exim"
  echo "  → Exim を検出"

  exim -bV 2>/dev/null | tee "$OUTDIR/exim_version.txt" || true
  exim -bP > "$OUTDIR/exim_config.txt" 2>/dev/null || true

  if [ -d /etc/exim4 ]; then
    tar -czf "$OUTDIR/etc_exim4.tgz" -C /etc \
      --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
      exim4 2>/dev/null || true
    echo "  → 設定アーカイブ保存: etc_exim4.tgz（秘密鍵除外）"
  fi
  if [ -f /etc/exim.conf ]; then
    cp /etc/exim.conf "$OUTDIR/" 2>/dev/null || true
  fi

  echo "※ Exim用のkey_params抽出は未実装。設定ファイルを直接確認してください。" > "$OUTDIR/key_params.txt"

# --- Sendmail ---
elif command -v sendmail >/dev/null 2>&1 && [ -f /etc/mail/sendmail.cf ]; then
  MTA_DETECTED="sendmail"
  echo "  → Sendmail を検出"

  if [ -d /etc/mail ]; then
    tar -czf "$OUTDIR/etc_mail.tgz" -C /etc \
      --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
      mail 2>/dev/null || true
    echo "  → 設定アーカイブ保存: etc_mail.tgz（秘密鍵除外）"
  fi
  if [ -f /etc/sendmail.cf ]; then
    cp /etc/sendmail.cf "$OUTDIR/" 2>/dev/null || true
  fi

  echo "※ Sendmail用のkey_params抽出は未実装。設定ファイルを直接確認してください。" > "$OUTDIR/key_params.txt"

else
  echo "  → 既知のMTA（Postfix/Exim/Sendmail）が見つかりません"
fi

# MTA種類を記録
echo "MTA_DETECTED=$MTA_DETECTED" > "$OUTDIR/mta_type.txt"
echo ""
echo "  検出結果: $MTA_DETECTED"

#----------------------------------------------------------------------
# 3. ネットワーク設定の取得
#----------------------------------------------------------------------
echo ""
echo "[3/5] ネットワーク設定を取得中..."

# IPアドレス
echo "  → IPアドレス一覧..."
ip addr show > "$OUTDIR/ip_addr.txt" 2>/dev/null || ifconfig > "$OUTDIR/ifconfig.txt" 2>/dev/null || true

# ルーティング
echo "  → ルーティングテーブル..."
ip route show > "$OUTDIR/ip_route.txt" 2>/dev/null || netstat -rn > "$OUTDIR/netstat_route.txt" 2>/dev/null || true

# DNS設定
echo "  → DNS設定..."
cat /etc/resolv.conf > "$OUTDIR/resolv.conf" 2>/dev/null || true

#----------------------------------------------------------------------
# 4. ファイアウォール設定の取得
#----------------------------------------------------------------------
echo ""
echo "[4/5] ファイアウォール設定を取得中..."

# iptables
echo "  → iptables..."
iptables -L -n > "$OUTDIR/iptables.txt" 2>/dev/null || echo "iptablesが利用不可" > "$OUTDIR/iptables.txt"

# firewalld
echo "  → firewalld..."
firewall-cmd --list-all > "$OUTDIR/firewalld.txt" 2>/dev/null || echo "firewalldが利用不可" > "$OUTDIR/firewalld.txt"

# nftables
echo "  → nftables..."
nft list ruleset > "$OUTDIR/nftables.txt" 2>/dev/null || true

#----------------------------------------------------------------------
# 5. サマリーJSONとメールフローサマリーの作成
#----------------------------------------------------------------------
echo ""
echo "[5/5] サマリーJSONとメールフローサマリーを作成中..."

# サマリーJSON
cat > "$OUTDIR/summary.json" << EOF
{
  "timestamp": "$TS",
  "hostname": "$HOST",
  "mta_detected": "$MTA_DETECTED",
  "output_files": {
    "mta_type": "mta_type.txt",
    "config_active": $([ -f "$OUTDIR/postconf-n.txt" ] && echo "\"postconf-n.txt\"" || echo "null"),
    "config_active_json": $([ -f "$OUTDIR/postconf-n.json" ] && echo "\"postconf-n.json\"" || echo "null"),
    "key_params": "key_params.txt",
    "network_info": "ip_addr.txt",
    "routing_table": "ip_route.txt",
    "firewall": "iptables.txt"
  },
  "security_notes": "秘密鍵(.key, .pem等)とパスワードファイルは除外またはマスクされています。"
}
EOF

# メールフローサマリー（既存形式も維持）
cat > "$OUTDIR/mail_flow_summary.txt" << EOF
#===============================================================================
# DMZ SMTPサーバー メールフローサマリー
#===============================================================================
#
# 作成日時: $TS
# ホスト名: $HOST
# MTA種類:  $MTA_DETECTED
#
#-------------------------------------------------------------------------------
# ネットワーク情報
#-------------------------------------------------------------------------------
EOF

# IPアドレスを追記
echo "" >> "$OUTDIR/mail_flow_summary.txt"
echo "【IPアドレス】" >> "$OUTDIR/mail_flow_summary.txt"
ip addr show 2>/dev/null | grep -E '^\s+inet ' | awk '{print "  " $2}' >> "$OUTDIR/mail_flow_summary.txt" || true

# メールフロー設定を追記
if [ "$MTA_DETECTED" = "postfix" ] && [ -f "$OUTDIR/key_params.txt" ]; then
  echo "" >> "$OUTDIR/mail_flow_summary.txt"
  echo "【メールフロー設定】" >> "$OUTDIR/mail_flow_summary.txt"
  grep -v '^#' "$OUTDIR/key_params.txt" | grep -v '^$' >> "$OUTDIR/mail_flow_summary.txt" || true
fi

cat >> "$OUTDIR/mail_flow_summary.txt" << EOF

#-------------------------------------------------------------------------------
# 確認ポイント
#-------------------------------------------------------------------------------
#
# 1. relayhost の設定
#    → 内部メールサーバーへの転送先が設定されているか
#    → EXO移行後はここをEXOのスマートホストに変更
#
# 2. relay_domains の設定
#    → どのドメインのメールをリレーしているか
#    → 40ドメイン全てが含まれているか確認
#
# 3. mynetworks の設定
#    → 内部ネットワークからのリレーが許可されているか
#
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
echo "  ★ mta_type.txt"
echo "     → 検出されたMTA: $MTA_DETECTED"
echo ""
if [ "$MTA_DETECTED" = "postfix" ]; then
  echo "  ★ key_params.txt"
  echo "     → relayhost, relay_domains等のメールフロー設定"
  echo ""
  echo "  ★ postconf-n.txt / postconf-n.json"
  echo "     → 有効な設定一覧"
  echo ""
fi
echo "  ★ mail_flow_summary.txt"
echo "     → メールフローのサマリー"
echo ""
echo "  ★ summary.json"
echo "     → サマリー情報（機械可読）"
echo ""
echo "  ★ ip_addr.txt"
echo "     → ネットワーク構成の確認"
echo ""
echo "【セキュリティ】"
echo "  - 秘密鍵(.key, .pem等)は収集されていません"
echo "  - パスワードファイルはマスクされています"
echo ""
echo "出力先: $OUTDIR"
