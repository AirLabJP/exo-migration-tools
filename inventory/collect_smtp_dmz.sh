#!/usr/bin/env bash
#===============================================================================
# DMZ SMTPサーバー設定棚卸しスクリプト（強化版）
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
#   - ファイアウォール設定（詳細）
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
#   postconf-M.txt        ← master.cfサービス定義
#   postconf-P.txt        ← master.cfパラメータオーバーライド
#   key_params.txt        ← ★重要: relayhost等のメールフロー設定
#   map_files/            ← マップファイル（パスワードマスク済み）
#   etc_postfix.tgz       ← 設定ファイル原本（秘密鍵・パスワード除外）
#   systemctl_status.txt  ← サービス状態
#   journalctl_tail.txt   ← サービスログ
#   smtp_ports_summary.txt← ★重要: SMTPポート稼働状況（25/587/465）
#   queue_summary.txt     ← キュー状況
#   ip_addr.txt           ← IPアドレス一覧
#   ip_route.txt          ← ルーティングテーブル
#   iptables.txt          ← iptables -L -n
#   iptables-save.txt     ← ★重要: iptables-save（完全ルール）
#   nftables.txt          ← nft list ruleset
#   firewalld.txt         ← firewall-cmd --list-all
#   firewalld-zones.txt   ← ★重要: firewall-cmd --list-all-zones
#   summary.json          ← サマリー情報（機械可読）
#
#===============================================================================
set -euo pipefail
umask 027
export LC_ALL=C

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
  # 一時ファイルの削除
  rm -f "$OUTDIR"/.tmp.* 2>/dev/null || true
}

# trap設定（EXIT, ERR, INT, TERM時に後片付けを実行）
trap cleanup EXIT ERR INT TERM

# 実行ログを記録開始
exec > >(tee -a "$OUTDIR/run.log") 2>&1

echo "============================================================"
echo " DMZ SMTPサーバー設定棚卸し（強化版）"
echo "============================================================"
echo "実行日時: $TS"
echo "ホスト名: $HOST"
echo "出力先:   $OUTDIR"
echo ""

#----------------------------------------------------------------------
# 1. システム情報の取得
#----------------------------------------------------------------------
echo "[1/7] システム情報を取得中..."
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
echo "[2/7] ★ MTAの種類を自動検出中..."
MTA_DETECTED="none"
CONFIG_DIR=""
MAIL_VERSION=""
MAP_COUNT=0

# --- Postfix ---
if command -v postconf >/dev/null 2>&1; then
  MTA_DETECTED="postfix"
  echo "  → Postfix を検出"

  # バージョン
  MAIL_VERSION=$(postconf -h mail_version 2>/dev/null || echo "unknown")
  echo "$MAIL_VERSION" | tee "$OUTDIR/postfix_version.txt"

  # config_directory動的取得
  CONFIG_DIR=$(postconf -h config_directory 2>/dev/null || echo "/etc/postfix")
  echo "  → 設定ディレクトリ: $CONFIG_DIR"

  # 有効な設定（デフォルトから変更された項目）
  echo ""
  echo "  → 有効な設定を取得（postconf -n）..."
  postconf -n > "$OUTDIR/postconf-n.txt" || true

  # JSON形式でも出力（改善版：=を含む値に対応）
  echo "  → JSON形式で出力中..."
  {
    echo "{"
    echo "  \"timestamp\": \"$TS\","
    echo "  \"hostname\": \"$HOST\","
    echo "  \"mail_version\": \"$MAIL_VERSION\","
    echo "  \"config_directory\": \"$CONFIG_DIR\","
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
      key_esc=$(echo "$key" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | xargs)
      value_esc=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
      echo -n "    \"$key_esc\": \"$value_esc\""
    done < "$OUTDIR/postconf-n.txt"
    echo ""
    echo "  }"
    echo "}"
  } > "$OUTDIR/postconf-n.json"

  # 全設定
  postconf > "$OUTDIR/postconf-all.txt" || true

  # master.cf関連の設定（postconf -M/-P）
  echo ""
  echo "  → master.cf設定を取得..."
  if postconf -M > "$OUTDIR/postconf-M.txt" 2>/dev/null; then
    echo "    ✓ postconf -M（サービス定義）"
  fi
  if postconf -P > "$OUTDIR/postconf-P.txt" 2>/dev/null; then
    echo "    ✓ postconf -P（パラメータオーバーライド）"
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

  # マップファイルの参照抽出と実体コピー（機密名マスク）
  echo ""
  echo "  → マップファイルを検出してコピー中..."
  mkdir -p "$OUTDIR/map_files"
  > "$OUTDIR/map_files_list.txt"

  # 設定内で参照されているマップファイルを検索
  if [ -d "$CONFIG_DIR" ]; then
    # hash:, lmdb:, btree: などのマップ参照を検出
    mapfiles=$(grep -RInh -E '(hash|lmdb|btree|regexp|pcre|cidr):[^ ,]+' "$CONFIG_DIR" 2>/dev/null | \
      grep -oE '(hash|lmdb|btree|regexp|pcre|cidr):[^ ,]+' | \
      sed 's/^[^:]*://; s/[,;].*$//' | sort -u || true)

    for mapref in $mapfiles; do
      # 絶対パスでない場合は $CONFIG_DIR を前置
      if [[ "$mapref" != /* ]]; then
        candidate="$CONFIG_DIR/$mapref"
      else
        candidate="$mapref"
      fi

      # ファイルが存在するか確認（.db等の拡張子は除く）
      if [ -f "$candidate" ]; then
        MAP_COUNT=$((MAP_COUNT+1))
        basename_map=$(basename "$candidate")
        echo "$candidate" >> "$OUTDIR/map_files_list.txt"

        # パスワードを含むファイルはマスクしてコピー
        if [[ "$candidate" == *sasl_passwd* ]] || [[ "$candidate" == *password* ]]; then
          echo "    ✓ マスク保存: $candidate → map_files/${basename_map}.masked"
          sed -E 's/^([^:]+):(.*)$/\1:***MASKED***/' "$candidate" > "$OUTDIR/map_files/${basename_map}.masked" 2>/dev/null || true
        else
          echo "    ✓ コピー: $candidate → map_files/${basename_map}"
          cp -a "$candidate" "$OUTDIR/map_files/" 2>/dev/null || true
        fi
      fi
    done
  fi

  if [ "$MAP_COUNT" -eq 0 ]; then
    echo "    → マップファイルは見つかりませんでした"
  else
    echo "    → 検出数: $MAP_COUNT"
  fi

  # 設定ファイルアーカイブ（秘密鍵・パスワード・DB除外）
  if [ -d "$CONFIG_DIR" ]; then
    echo ""
    echo "  → 設定ファイルをアーカイブ中..."
    tar -czf "$OUTDIR/etc_postfix.tgz" -C "$(dirname "$CONFIG_DIR")" \
      --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
      --exclude='*.csr' --exclude='*.crt.key' \
      --exclude='sasl_passwd*' --exclude='*password*' \
      --exclude='*.db' --exclude='*.dir' --exclude='*.pag' \
      "$(basename "$CONFIG_DIR")" 2>/dev/null || true
    echo "    ✓ 保存完了: etc_postfix.tgz（秘密鍵・パスワード・DB除外）"
  fi

# --- Exim ---
elif command -v exim >/dev/null 2>&1; then
  MTA_DETECTED="exim"
  echo "  → Exim を検出"

  MAIL_VERSION=$(exim -bV 2>/dev/null | head -1 || echo "unknown")
  echo "$MAIL_VERSION" | tee "$OUTDIR/exim_version.txt"
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

  MAIL_VERSION=$(sendmail -d0.1 < /dev/null 2>&1 | head -1 || echo "unknown")
  echo "$MAIL_VERSION" | tee "$OUTDIR/sendmail_version.txt"

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
# 3. systemctl/journalctl取得
#----------------------------------------------------------------------
echo ""
echo "[3/7] systemctl/journalctlを取得中..."

if [ "$MTA_DETECTED" = "postfix" ]; then
  echo "  → Postfixサービス状態..."
  if systemctl list-unit-files 2>/dev/null | grep -q "^postfix.service"; then
    systemctl status postfix --no-pager --full > "$OUTDIR/systemctl_status.txt" 2>/dev/null || true
  else
    echo "postfix.service が見つかりません（systemd未使用の可能性）" > "$OUTDIR/systemctl_status.txt"
  fi

  echo "  → Postfixログ（最新500行）..."
  if systemctl list-unit-files 2>/dev/null | grep -q "^postfix.service"; then
    journalctl -u postfix -n 500 --no-pager --full > "$OUTDIR/journalctl_tail.txt" 2>/dev/null || true
  else
    echo "journalctl情報なし（systemd未使用）" > "$OUTDIR/journalctl_tail.txt"
  fi
elif [ "$MTA_DETECTED" = "exim" ]; then
  echo "  → Eximサービス状態..."
  for svc in exim exim4; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
      systemctl status "$svc" --no-pager --full > "$OUTDIR/systemctl_status.txt" 2>/dev/null || true
      journalctl -u "$svc" -n 500 --no-pager --full > "$OUTDIR/journalctl_tail.txt" 2>/dev/null || true
      break
    fi
  done
elif [ "$MTA_DETECTED" = "sendmail" ]; then
  echo "  → Sendmailサービス状態..."
  if systemctl list-unit-files 2>/dev/null | grep -q "^sendmail.service"; then
    systemctl status sendmail --no-pager --full > "$OUTDIR/systemctl_status.txt" 2>/dev/null || true
    journalctl -u sendmail -n 500 --no-pager --full > "$OUTDIR/journalctl_tail.txt" 2>/dev/null || true
  fi
fi

if [ ! -s "$OUTDIR/systemctl_status.txt" ]; then
  echo "systemctl情報なし（systemd未使用またはサービス未登録）" > "$OUTDIR/systemctl_status.txt"
fi

if [ ! -s "$OUTDIR/journalctl_tail.txt" ]; then
  echo "journalctl情報なし（systemd未使用またはサービス未登録）" > "$OUTDIR/journalctl_tail.txt"
fi

#----------------------------------------------------------------------
# 4. ★重要：SMTPポート（25/587/465）稼働状況とキュー
#----------------------------------------------------------------------
echo ""
echo "[4/7] ★ SMTPポート稼働状況とキュー状況を確認中..."

# ポート稼働状況
{
  echo "#==============================================================================="
  echo "# SMTPポート稼働状況"
  echo "#==============================================================================="
  echo "#"
  echo "# ポート: 25 (SMTP), 587 (Submission), 465 (SMTPS)"
  echo "#"
  echo ""

  for port in 25 587 465; do
    proto=""
    case "$port" in
      25) proto="SMTP" ;;
      587) proto="Submission (STARTTLS)" ;;
      465) proto="SMTPS (TLS Wrapper)" ;;
    esac

    if grep -qE "[:.]${port}\s" "$OUTDIR/ss_listen.txt" 2>/dev/null; then
      echo "  → ✓ ポート $port ($proto) : リスン中"
      grep -E "[:.]${port}\s" "$OUTDIR/ss_listen.txt" | head -3 | sed 's/^/      /'
    else
      echo "  → ✗ ポート $port ($proto) : リスンしていません"
    fi
    echo ""
  done
} > "$OUTDIR/smtp_ports_summary.txt"

cat "$OUTDIR/smtp_ports_summary.txt"

# キュー状況（Postfixのみ）
echo ""
echo "  → キュー状況を確認..."
if [ "$MTA_DETECTED" = "postfix" ] && command -v postqueue >/dev/null 2>&1; then
  {
    echo "#==============================================================================="
    echo "# キュー状況"
    echo "#==============================================================================="
    echo ""
    postqueue -p 2>/dev/null || echo "キュー情報取得失敗"
  } > "$OUTDIR/queue_summary.txt"

  # キュー件数を抽出
  QUEUE_COUNT=$(postqueue -p 2>/dev/null | tail -1 | grep -oE '[0-9]+ (Request|Requests)' | grep -oE '[0-9]+' || echo 0)
  echo "  → キュー件数: $QUEUE_COUNT"
else
  echo "# キュー情報なし（Postfix以外またはコマンド利用不可）" > "$OUTDIR/queue_summary.txt"
  QUEUE_COUNT=0
fi

#----------------------------------------------------------------------
# 5. ネットワーク設定の取得
#----------------------------------------------------------------------
echo ""
echo "[5/7] ネットワーク設定を取得中..."

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
# 6. ★重要：ファイアウォール設定の取得（強化版）
#----------------------------------------------------------------------
echo ""
echo "[6/7] ★ ファイアウォール設定を取得中（強化版）..."

# iptables -L -n（従来形式）
echo "  → iptables -L -n..."
iptables -L -n > "$OUTDIR/iptables.txt" 2>/dev/null || echo "iptablesが利用不可" > "$OUTDIR/iptables.txt"

# iptables-save（完全ルール）
echo "  → iptables-save（完全ルール）..."
iptables-save > "$OUTDIR/iptables-save.txt" 2>/dev/null || echo "iptables-saveが利用不可" > "$OUTDIR/iptables-save.txt"

# ip6tables（IPv6）
echo "  → ip6tables..."
ip6tables -L -n > "$OUTDIR/ip6tables.txt" 2>/dev/null || true
ip6tables-save > "$OUTDIR/ip6tables-save.txt" 2>/dev/null || true

# nftables
echo "  → nftables..."
nft list ruleset > "$OUTDIR/nftables.txt" 2>/dev/null || echo "nftablesが利用不可" > "$OUTDIR/nftables.txt"

# firewalld --list-all（従来形式）
echo "  → firewalld --list-all..."
firewall-cmd --list-all > "$OUTDIR/firewalld.txt" 2>/dev/null || echo "firewalldが利用不可" > "$OUTDIR/firewalld.txt"

# firewalld --list-all-zones（全ゾーン）
echo "  → firewalld --list-all-zones（全ゾーン）..."
firewall-cmd --list-all-zones > "$OUTDIR/firewalld-zones.txt" 2>/dev/null || echo "firewalldが利用不可" > "$OUTDIR/firewalld-zones.txt"

#----------------------------------------------------------------------
# 7. サマリーJSONとメールフローサマリーの作成
#----------------------------------------------------------------------
echo ""
echo "[7/7] サマリーJSONとメールフローサマリーを作成中..."

# ポート状態を変数化
SMTP_25="false"
SMTP_587="false"
SMTP_465="false"

grep -qE "[:.]25\s" "$OUTDIR/ss_listen.txt" 2>/dev/null && SMTP_25="true"
grep -qE "[:.]587\s" "$OUTDIR/ss_listen.txt" 2>/dev/null && SMTP_587="true"
grep -qE "[:.]465\s" "$OUTDIR/ss_listen.txt" 2>/dev/null && SMTP_465="true"

# サマリーJSON
cat > "$OUTDIR/summary.json" << EOF
{
  "timestamp": "$TS",
  "hostname": "$HOST",
  "mta_detected": "$MTA_DETECTED",
  "mail_version": "$MAIL_VERSION",
  "config_directory": "$CONFIG_DIR",
  "smtp_ports": {
    "port_25_smtp": $SMTP_25,
    "port_587_submission": $SMTP_587,
    "port_465_smtps": $SMTP_465
  },
  "queue_count": ${QUEUE_COUNT:-0},
  "map_files_detected": $MAP_COUNT,
  "output_files": {
    "mta_type": "mta_type.txt",
    "config_active": $([ -f "$OUTDIR/postconf-n.txt" ] && echo "\"postconf-n.txt\"" || echo "null"),
    "config_active_json": $([ -f "$OUTDIR/postconf-n.json" ] && echo "\"postconf-n.json\"" || echo "null"),
    "config_master_services": $([ -f "$OUTDIR/postconf-M.txt" ] && echo "\"postconf-M.txt\"" || echo "null"),
    "config_master_params": $([ -f "$OUTDIR/postconf-P.txt" ] && echo "\"postconf-P.txt\"" || echo "null"),
    "key_params": "key_params.txt",
    "map_files_list": $([ -f "$OUTDIR/map_files_list.txt" ] && echo "\"map_files_list.txt\"" || echo "null"),
    "smtp_ports_summary": "smtp_ports_summary.txt",
    "queue_summary": "queue_summary.txt",
    "network_info": "ip_addr.txt",
    "routing_table": "ip_route.txt",
    "firewall_iptables": "iptables.txt",
    "firewall_iptables_save": "iptables-save.txt",
    "firewall_nftables": "nftables.txt",
    "firewall_firewalld": "firewalld.txt",
    "firewall_firewalld_zones": "firewalld-zones.txt",
    "systemctl_status": "systemctl_status.txt",
    "journalctl_tail": "journalctl_tail.txt"
  },
  "security_notes": "秘密鍵(.key, .pem等)、パスワードファイル、DBファイル(.db等)は除外またはマスクされています。"
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
# バージョン: $MAIL_VERSION
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

# SMTPポート状況を追記
echo "" >> "$OUTDIR/mail_flow_summary.txt"
echo "【SMTPポート】" >> "$OUTDIR/mail_flow_summary.txt"
echo "  ポート 25 (SMTP):        $([ "$SMTP_25" = "true" ] && echo "✓ リスン中" || echo "✗ 停止")" >> "$OUTDIR/mail_flow_summary.txt"
echo "  ポート 587 (Submission): $([ "$SMTP_587" = "true" ] && echo "✓ リスン中" || echo "✗ 停止")" >> "$OUTDIR/mail_flow_summary.txt"
echo "  ポート 465 (SMTPS):      $([ "$SMTP_465" = "true" ] && echo "✓ リスン中" || echo "✗ 停止")" >> "$OUTDIR/mail_flow_summary.txt"

# キュー状況を追記
if [ "$MTA_DETECTED" = "postfix" ]; then
  echo "" >> "$OUTDIR/mail_flow_summary.txt"
  echo "【キュー】" >> "$OUTDIR/mail_flow_summary.txt"
  echo "  キュー件数: ${QUEUE_COUNT:-0}" >> "$OUTDIR/mail_flow_summary.txt"
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
# 4. ファイアウォール設定
#    → ポート 25/587/465 が外部/内部から適切に許可されているか
#    → iptables-save.txt または firewalld-zones.txt で詳細確認
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
  echo "  ★ postconf-M.txt / postconf-P.txt"
  echo "     → master.cfサービス定義とパラメータ"
  echo ""
  if [ "$MAP_COUNT" -gt 0 ]; then
    echo "  ★ map_files/"
    echo "     → マップファイル（パスワードマスク済み）"
    echo "     → 検出数: $MAP_COUNT"
    echo ""
  fi
fi
echo "  ★ smtp_ports_summary.txt"
echo "     → SMTPポート稼働状況（25/587/465）"
echo ""
if [ "$MTA_DETECTED" = "postfix" ]; then
  echo "  ★ queue_summary.txt"
  echo "     → キュー状況（件数: ${QUEUE_COUNT:-0}）"
  echo ""
fi
echo "  ★ mail_flow_summary.txt"
echo "     → メールフローのサマリー"
echo ""
echo "  ★ iptables-save.txt / firewalld-zones.txt"
echo "     → ファイアウォール完全ルール（最重要）"
echo ""
echo "  ★ systemctl_status.txt / journalctl_tail.txt"
echo "     → サービス状態とログ"
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
echo "  - DBファイル(.db等)は除外されています"
echo ""
echo "出力先: $OUTDIR"
