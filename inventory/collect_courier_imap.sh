#!/usr/bin/env bash
#===============================================================================
# Courier IMAP / Dovecot 設定棚卸しスクリプト（強化版）
#===============================================================================
#
# 【目的】
#   IMAPサーバー（Courier IMAP または Dovecot）の設定とユーザー情報を収集し、
#   EXO移行計画に必要な情報を取得する
#
# 【収集する情報】
#   - IMAPサーバー設定（認証方式、ポート等）
#   - メールボックス一覧（Maildir / mbox形式）
#   - ユーザー一覧（システムユーザー / 仮想ユーザー）
#   - ユーザーとメールボックスの突合
#
# 【出力先】
#   ./inventory_YYYYMMDD_HHMMSS/courier_imap_<ホスト名>/
#
# 【実行方法】
#   sudo bash collect_courier_imap.sh [出力先ディレクトリ] [-t N]
#
#   オプション:
#     -t N : Maildirサイズ上位N件を計算（時間がかかる場合あり）
#
# 【出力ファイルと確認ポイント】
#   etc_courier.tgz           ← Courier IMAP設定原本（秘密鍵を除く）
#   etc_dovecot.tgz           ← Dovecot設定原本（秘密鍵を除く）
#   doveconf-n.txt            ← Dovecot有効設定
#   doveconf-a.txt            ← Dovecot全設定
#   courier_*.conf            ← Courier主要設定ファイル（コピー）
#   authdaemonrc_keys.txt     ← authdaemonrc重要設定抽出
#   sql_ldap_configs.txt      ← SQL/LDAP設定（マスク済み）
#   maildir_candidates.txt    ← ★重要: Maildir一覧
#   mbox_candidates.txt       ← ★重要: mbox一覧
#   mailbox_user_match.csv    ← ★重要: ユーザー×メールボックス対応表
#   getent_passwd.txt         ← ★重要: システムユーザー一覧
#   getent_passwd.json        ← 詳細データ（機械可読）
#   getent_group.txt          ← グループ一覧
#   userdb / users            ← 仮想ユーザー定義（パスワードハッシュをマスク）
#   systemctl_status.txt      ← サービス状態
#   journalctl_tail.txt       ← サービスログ
#   imap_ports_summary.txt    ← ★重要: IMAP/POP3ポート稼働状況
#   maildir_size_top.txt      ← Maildirサイズ上位N件（-t指定時）
#   summary.json              ← サマリー情報（機械可読）
#
#===============================================================================
set -euo pipefail
umask 027
export LC_ALL=C

# パラメータ解析
TOPN=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t)
      shift
      TOPN="${1:-0}"
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

# タイムスタンプとホスト名を取得
TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUTROOT="${ARGS[0]:-./inventory_${TS}}"
OUTDIR="${OUTROOT}/courier_imap_${HOST}"
mkdir -p "$OUTDIR"

# 後片付け関数
cleanup() {
  echo ""
  echo "後片付け実行中..."
  # 一時ファイルの削除（必要に応じて）
  rm -f "$OUTDIR"/.tmp.* 2>/dev/null || true
}

# trap設定（EXIT, ERR, INT, TERM時に後片付けを実行）
trap cleanup EXIT ERR INT TERM

# 実行ログを記録開始
exec > >(tee -a "$OUTDIR/run.log") 2>&1

echo "============================================================"
echo " Courier IMAP / Dovecot 設定棚卸し（強化版）"
echo "============================================================"
echo "実行日時: $TS"
echo "ホスト名: $HOST"
echo "出力先:   $OUTDIR"
if [ "$TOPN" -gt 0 ]; then
  echo "オプション: Maildirサイズ上位 ${TOPN} 件を計算"
fi
echo ""

#----------------------------------------------------------------------
# 1. システム情報の取得
#----------------------------------------------------------------------
echo "[1/11] システム情報を取得中..."
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

#----------------------------------------------------------------------
# 2. メール関連プロセスの確認
#----------------------------------------------------------------------
echo ""
echo "[2/11] メール関連プロセスを確認中..."
echo "  → courier, dovecot, imap, pop3 を検索"
ps auxww | grep -Ei 'courier|imap|pop3|authdaemon|dovecot' | tee "$OUTDIR/ps_mail.txt" >/dev/null || true

# 検出されたサーバーを表示
DETECTED_COURIER=false
DETECTED_DOVECOT=false
if grep -qi 'courier' "$OUTDIR/ps_mail.txt" 2>/dev/null; then
  echo "  → Courier IMAP を検出"
  DETECTED_COURIER=true
fi
if grep -qi 'dovecot' "$OUTDIR/ps_mail.txt" 2>/dev/null; then
  echo "  → Dovecot を検出"
  DETECTED_DOVECOT=true
fi

#----------------------------------------------------------------------
# 3. ★Dovecot設定の取得（doveconf -n/-a）
#----------------------------------------------------------------------
echo ""
echo "[3/11] ★ Dovecot設定を取得中（doveconf）..."

if command -v doveconf >/dev/null 2>&1; then
  echo "  → doveconf -n（有効な設定のみ）"
  doveconf -n > "$OUTDIR/doveconf-n.txt" 2>/dev/null || echo "doveconf -n 取得失敗" > "$OUTDIR/doveconf-n.txt"

  echo "  → doveconf -a（全設定）"
  doveconf -a > "$OUTDIR/doveconf-a.txt" 2>/dev/null || echo "doveconf -a 取得失敗" > "$OUTDIR/doveconf-a.txt"

  # SQL/LDAP設定の検出とマスク保存
  echo ""
  echo "  → SQL/LDAP設定を検出してマスク保存中..."
  > "$OUTDIR/sql_ldap_configs.txt"

  # SQL設定ファイル検出
  for sqlconf in /etc/dovecot/dovecot-sql.conf.ext /etc/dovecot/dovecot-sql.conf; do
    if [ -f "$sqlconf" ]; then
      echo "    ✓ 発見: $sqlconf"
      echo "#===============================================================================" >> "$OUTDIR/sql_ldap_configs.txt"
      echo "# $sqlconf" >> "$OUTDIR/sql_ldap_configs.txt"
      echo "#===============================================================================" >> "$OUTDIR/sql_ldap_configs.txt"
      # パスワードをマスク（connect=, password=行）
      sed -E 's/(password|connect)(\s*=\s*).*/\1\2***MASKED***/i' "$sqlconf" >> "$OUTDIR/sql_ldap_configs.txt" 2>/dev/null || true
      echo "" >> "$OUTDIR/sql_ldap_configs.txt"
    fi
  done

  # LDAP設定ファイル検出
  for ldapconf in /etc/dovecot/dovecot-ldap.conf.ext /etc/dovecot/dovecot-ldap.conf; do
    if [ -f "$ldapconf" ]; then
      echo "    ✓ 発見: $ldapconf"
      echo "#===============================================================================" >> "$OUTDIR/sql_ldap_configs.txt"
      echo "# $ldapconf" >> "$OUTDIR/sql_ldap_configs.txt"
      echo "#===============================================================================" >> "$OUTDIR/sql_ldap_configs.txt"
      # パスワードをマスク（dn_password=, bind_password=行）
      sed -E 's/(password|dn_password|bind_password)(\s*=\s*).*/\1\2***MASKED***/i' "$ldapconf" >> "$OUTDIR/sql_ldap_configs.txt" 2>/dev/null || true
      echo "" >> "$OUTDIR/sql_ldap_configs.txt"
    fi
  done

  if [ ! -s "$OUTDIR/sql_ldap_configs.txt" ]; then
    echo "  → SQL/LDAP設定ファイルは見つかりませんでした" > "$OUTDIR/sql_ldap_configs.txt"
  fi
else
  echo "  → doveconf コマンドが見つかりません（Dovecot未使用の可能性）"
fi

#----------------------------------------------------------------------
# 4. ★Courier主要設定ファイルのコピーとauthdaemonrc抽出
#----------------------------------------------------------------------
echo ""
echo "[4/11] ★ Courier主要設定ファイルをコピー中..."

if [ -d /etc/courier ]; then
  # 主要設定ファイルのコピー
  for conf in imapd imapd-ssl pop3d pop3d-ssl authdaemonrc; do
    if [ -f "/etc/courier/$conf" ]; then
      echo "  → コピー: /etc/courier/$conf"
      cp -a "/etc/courier/$conf" "$OUTDIR/courier_${conf}.conf" 2>/dev/null || true
    fi
  done

  # authdaemonrc重要設定の抽出
  echo ""
  echo "  → authdaemonrc重要設定を抽出中..."
  if [ -f /etc/courier/authdaemonrc ]; then
    {
      echo "#==============================================================================="
      echo "# authdaemonrc 重要設定抽出"
      echo "#==============================================================================="
      echo ""
      grep -E '^(authmodulelist|authmodulelistorig|daemons|DEBUG_LOGIN|DEFAULTOPTIONS)=' /etc/courier/authdaemonrc 2>/dev/null || echo "# 抽出失敗または設定なし"
    } > "$OUTDIR/authdaemonrc_keys.txt"
  else
    echo "# authdaemonrcが見つかりません" > "$OUTDIR/authdaemonrc_keys.txt"
  fi

  # Courier SQL/LDAP設定の検出とマスク
  echo ""
  echo "  → Courier SQL/LDAP設定を検出中..."
  for authconf in /etc/courier/authmysqlrc /etc/courier/authpgsqlrc /etc/courier/authldaprc; do
    if [ -f "$authconf" ]; then
      echo "    ✓ 発見: $authconf"
      echo "#===============================================================================" >> "$OUTDIR/sql_ldap_configs.txt"
      echo "# $authconf" >> "$OUTDIR/sql_ldap_configs.txt"
      echo "#===============================================================================" >> "$OUTDIR/sql_ldap_configs.txt"
      # パスワードをマスク
      sed -E 's/(MYSQL_PASSWORD|PGSQL_PASSWORD|LDAP_BINDPW)(\s+).*/\1\2***MASKED***/i' "$authconf" >> "$OUTDIR/sql_ldap_configs.txt" 2>/dev/null || true
      echo "" >> "$OUTDIR/sql_ldap_configs.txt"
    fi
  done
else
  echo "  → /etc/courier が見つかりません（Courier未使用の可能性）"
fi

#----------------------------------------------------------------------
# 5. 設定ファイルのアーカイブ（秘密鍵を除外）
#----------------------------------------------------------------------
echo ""
echo "[5/11] 設定ファイルをアーカイブ中..."
echo "  → 秘密鍵(.key, .pem等)は除外します"

# Courier IMAP設定
if [ -d /etc/courier ]; then
  # 秘密鍵を除外してアーカイブ
  tar -czf "$OUTDIR/etc_courier.tgz" -C /etc \
    --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
    --exclude='*.csr' --exclude='*.crt.key' \
    courier 2>/dev/null || true
  echo "  → 保存完了: $OUTDIR/etc_courier.tgz (Courier IMAP, 秘密鍵除外)"
else
  echo "  → /etc/courier が見つかりません（Courier未使用の可能性）"
fi

# Dovecot設定（Courier IMAPの代替として使われている場合）
if [ -d /etc/dovecot ]; then
  # 秘密鍵を除外してアーカイブ
  tar -czf "$OUTDIR/etc_dovecot.tgz" -C /etc \
    --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
    --exclude='*.csr' --exclude='*.crt.key' \
    dovecot 2>/dev/null || true
  echo "  → 保存完了: $OUTDIR/etc_dovecot.tgz (Dovecot, 秘密鍵除外)"
else
  echo "  → /etc/dovecot が見つかりません（Dovecot未使用の可能性）"
fi

#----------------------------------------------------------------------
# 6. ★重要：メールボックス（Maildir + mbox）の検索
#----------------------------------------------------------------------
echo ""
echo "[6/11] ★ メールボックス（Maildir + mbox）を検索中..."
echo "  → このリストが実際のメールボックス一覧になります"
echo "  → EXO移行対象ユーザーの特定に使用"

# 検索対象ディレクトリ（環境によって異なる）
CANDIDATES=(/home /var/mail /var/spool/mail /var/vmail /mail)
> "$OUTDIR/maildir_roots.txt"

echo ""
echo "  検索対象ディレクトリ:"
for base in "${CANDIDATES[@]}"; do
  if [ -d "$base" ]; then
    echo "$base" >> "$OUTDIR/maildir_roots.txt"
    echo "    ✓ $base"
  else
    echo "    - $base (存在しない)"
  fi
done

# Maildirを検索（最大20万件まで）
N=200000
MAILDIR_COUNT=0
> "$OUTDIR/maildir_candidates.txt"

echo ""
echo "  Maildirを検索中（最大${N}件）..."
for base in "${CANDIDATES[@]}"; do
  [ -d "$base" ] || continue
  while IFS= read -r p; do
    echo "$p" >> "$OUTDIR/maildir_candidates.txt"
    MAILDIR_COUNT=$((MAILDIR_COUNT+1))
    [ "$MAILDIR_COUNT" -ge "$N" ] && break 2
  done < <(find "$base" -maxdepth 6 -type d -name Maildir 2>/dev/null)
done

echo "Maildir検出数: $MAILDIR_COUNT" | tee "$OUTDIR/maildir_count.txt"

# mboxを検索（最大20万件まで）
MBOX_COUNT=0
> "$OUTDIR/mbox_candidates.txt"

echo ""
echo "  mboxを検索中（最大${N}件）..."
for base in "${CANDIDATES[@]}"; do
  [ -d "$base" ] || continue
  while IFS= read -r p; do
    # mboxファイルの特徴: 通常のファイルで、先頭が "From " で始まる
    if [ -f "$p" ] && head -1 "$p" 2>/dev/null | grep -q '^From '; then
      echo "$p" >> "$OUTDIR/mbox_candidates.txt"
      MBOX_COUNT=$((MBOX_COUNT+1))
      [ "$MBOX_COUNT" -ge "$N" ] && break 2
    fi
  done < <(find "$base" -maxdepth 6 -type f \( -name mbox -o -name mail -o -name inbox \) 2>/dev/null)
done

# /var/mail, /var/spool/mail 直下のファイルもmboxの可能性
for maildir in /var/mail /var/spool/mail; do
  if [ -d "$maildir" ]; then
    while IFS= read -r p; do
      if [ -f "$p" ] && head -1 "$p" 2>/dev/null | grep -q '^From '; then
        echo "$p" >> "$OUTDIR/mbox_candidates.txt"
        MBOX_COUNT=$((MBOX_COUNT+1))
        [ "$MBOX_COUNT" -ge "$N" ] && break 2
      fi
    done < <(find "$maildir" -maxdepth 1 -type f 2>/dev/null)
  fi
done

echo "mbox検出数: $MBOX_COUNT" | tee "$OUTDIR/mbox_count.txt"

# JSON出力（機械可読）
echo "  → JSON形式で出力中..."
{
  echo "{"
  echo "  \"timestamp\": \"$TS\","
  echo "  \"hostname\": \"$HOST\","
  echo "  \"maildir_count\": $MAILDIR_COUNT,"
  echo "  \"mbox_count\": $MBOX_COUNT,"
  echo "  \"maildir_paths\": ["
  first=true
  while IFS= read -r p; do
    if [ "$first" = true ]; then
      first=false
    else
      echo ","
    fi
    # JSON文字列エスケープ（簡易版）
    p_escaped=$(echo "$p" | sed 's/\\/\\\\/g; s/"/\\"/g')
    echo -n "    \"$p_escaped\""
  done < "$OUTDIR/maildir_candidates.txt"
  echo ""
  echo "  ],"
  echo "  \"mbox_paths\": ["
  first=true
  while IFS= read -r p; do
    if [ "$first" = true ]; then
      first=false
    else
      echo ","
    fi
    p_escaped=$(echo "$p" | sed 's/\\/\\\\/g; s/"/\\"/g')
    echo -n "    \"$p_escaped\""
  done < "$OUTDIR/mbox_candidates.txt"
  echo ""
  echo "  ]"
  echo "}"
} > "$OUTDIR/mailbox_candidates.json"

# 検出されたMaildir/mboxの例を表示
if [ "$MAILDIR_COUNT" -gt 0 ]; then
  echo ""
  echo "  検出されたMaildirの例（最大10件）:"
  head -10 "$OUTDIR/maildir_candidates.txt" | while read -r p; do
    echo "    $p"
  done
fi

if [ "$MBOX_COUNT" -gt 0 ]; then
  echo ""
  echo "  検出されたmboxの例（最大10件）:"
  head -10 "$OUTDIR/mbox_candidates.txt" | while read -r p; do
    echo "    $p"
  done
fi

#----------------------------------------------------------------------
# 7. ★重要：ユーザー一覧の取得
#----------------------------------------------------------------------
echo ""
echo "[7/11] ★ ユーザー一覧を取得中..."

# システムユーザー
echo "  → システムユーザー一覧を取得..."
getent passwd > "$OUTDIR/getent_passwd.txt" 2>/dev/null || true
getent group > "$OUTDIR/getent_group.txt" 2>/dev/null || true

# JSON出力（機械可読）
echo "  → システムユーザーをJSON形式で出力中..."
{
  echo "{"
  echo "  \"users\": ["
  first=true
  while IFS=: read -r username password uid gid gecos home shell; do
    if [ "$first" = true ]; then
      first=false
    else
      echo ","
    fi
    # JSON文字列エスケープ
    username_esc=$(echo "$username" | sed 's/\\/\\\\/g; s/"/\\"/g')
    gecos_esc=$(echo "$gecos" | sed 's/\\/\\\\/g; s/"/\\"/g')
    home_esc=$(echo "$home" | sed 's/\\/\\\\/g; s/"/\\"/g')
    shell_esc=$(echo "$shell" | sed 's/\\/\\\\/g; s/"/\\"/g')
    echo -n "    {\"username\": \"$username_esc\", \"uid\": $uid, \"gid\": $gid, \"gecos\": \"$gecos_esc\", \"home\": \"$home_esc\", \"shell\": \"$shell_esc\"}"
  done < "$OUTDIR/getent_passwd.txt"
  echo ""
  echo "  ]"
  echo "}"
} > "$OUTDIR/getent_passwd.json"

# メールユーザーの抽出（UID 1000以上の一般ユーザー）
echo ""
echo "  一般ユーザー（UID >= 1000）:"
awk -F: '$3 >= 1000 && $3 < 65534 { print "    " $1 " (UID:" $3 ", Home:" $6 ")" }' "$OUTDIR/getent_passwd.txt" | head -20
USER_COUNT=$(awk -F: '$3 >= 1000 && $3 < 65534 { count++ } END { print count }' "$OUTDIR/getent_passwd.txt")
echo "  → 一般ユーザー数: ${USER_COUNT:-0}"

# 仮想ユーザー定義ファイル（パスワードハッシュをマスク）
echo ""
echo "  → 仮想ユーザー定義ファイルを検索..."
for vf in /etc/courier/userdb /etc/dovecot/users /etc/postfix/vmailbox; do
  if [ -f "$vf" ]; then
    # パスワードハッシュをマスクしてコピー
    # 形式: username:passwordhash:... → username:***MASKED***:...
    echo "    ✓ 発見: $vf"
    if [[ "$vf" == */userdb ]] || [[ "$vf" == */users ]]; then
      sed -E 's/^([^:]+):([^:]+):/\1:***MASKED***:/' "$vf" > "$OUTDIR/$(basename $vf).masked" 2>/dev/null || cp -a "$vf" "$OUTDIR/" 2>/dev/null || true
      echo "      → パスワードハッシュをマスクして保存: $(basename $vf).masked"
    else
      cp -a "$vf" "$OUTDIR/" 2>/dev/null || true
      echo "      → コピー: $vf"
    fi
    # ユーザー数をカウント
    VU_COUNT=$(grep -c '^[^#]' "$vf" 2>/dev/null || echo 0)
    echo "      → 仮想ユーザー数: $VU_COUNT"
  fi
done

#----------------------------------------------------------------------
# 8. ★重要：ユーザーとメールボックスの突合CSV
#----------------------------------------------------------------------
echo ""
echo "[8/11] ★ ユーザー×メールボックス対応表を作成中..."

{
  echo "username,uid,home,mailbox_type,mailbox_path"

  # システムユーザーとメールボックスを突合
  while IFS=: read -r username password uid gid gecos home shell; do
    # UID 1000以上の一般ユーザーのみ対象
    if [ "$uid" -lt 1000 ] || [ "$uid" -ge 65534 ]; then
      continue
    fi

    matched=false

    # Maildirの突合
    if [ -f "$OUTDIR/maildir_candidates.txt" ]; then
      while IFS= read -r maildir_path; do
        # ホームディレクトリ配下のMaildirか
        if [[ "$maildir_path" == "$home"* ]]; then
          echo "$username,$uid,$home,Maildir,$maildir_path"
          matched=true
        fi
      done < "$OUTDIR/maildir_candidates.txt"
    fi

    # mboxの突合
    if [ -f "$OUTDIR/mbox_candidates.txt" ]; then
      while IFS= read -r mbox_path; do
        # ホームディレクトリ配下のmboxか、または /var/mail/username
        if [[ "$mbox_path" == "$home"* ]] || [[ "$mbox_path" == "/var/mail/$username" ]] || [[ "$mbox_path" == "/var/spool/mail/$username" ]]; then
          echo "$username,$uid,$home,mbox,$mbox_path"
          matched=true
        fi
      done < "$OUTDIR/mbox_candidates.txt"
    fi

    # メールボックスが見つからなかった場合
    if [ "$matched" = false ]; then
      echo "$username,$uid,$home,none,none"
    fi
  done < "$OUTDIR/getent_passwd.txt"
} > "$OUTDIR/mailbox_user_match.csv"

MATCHED_COUNT=$(grep -c -v '^username,' "$OUTDIR/mailbox_user_match.csv" 2>/dev/null || echo 0)
echo "  → 突合レコード数: $MATCHED_COUNT"

# 突合結果の例を表示
echo ""
echo "  突合結果の例（最大10件）:"
head -11 "$OUTDIR/mailbox_user_match.csv" | tail -10

#----------------------------------------------------------------------
# 9. systemctl/journalctl取得
#----------------------------------------------------------------------
echo ""
echo "[9/11] systemctl/journalctlを取得中..."

# Courier IMAP
if [ "$DETECTED_COURIER" = true ]; then
  echo "  → Courierサービス状態..."
  for svc in courier-imap courier-pop courier-authdaemon; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
      systemctl status "$svc" --no-pager --full >> "$OUTDIR/systemctl_status.txt" 2>/dev/null || true
      echo "---" >> "$OUTDIR/systemctl_status.txt"
    fi
  done

  echo "  → Courierログ（最新500行）..."
  for svc in courier-imap courier-pop courier-authdaemon; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
      journalctl -u "$svc" -n 500 --no-pager --full >> "$OUTDIR/journalctl_tail.txt" 2>/dev/null || true
      echo "---" >> "$OUTDIR/journalctl_tail.txt"
    fi
  done
fi

# Dovecot
if [ "$DETECTED_DOVECOT" = true ]; then
  echo "  → Dovecotサービス状態..."
  if systemctl list-unit-files | grep -q "^dovecot.service"; then
    systemctl status dovecot --no-pager --full >> "$OUTDIR/systemctl_status.txt" 2>/dev/null || true
    echo "---" >> "$OUTDIR/systemctl_status.txt"
  fi

  echo "  → Dovecotログ（最新500行）..."
  if systemctl list-unit-files | grep -q "^dovecot.service"; then
    journalctl -u dovecot -n 500 --no-pager --full >> "$OUTDIR/journalctl_tail.txt" 2>/dev/null || true
    echo "---" >> "$OUTDIR/journalctl_tail.txt"
  fi
fi

if [ ! -s "$OUTDIR/systemctl_status.txt" ]; then
  echo "systemctl情報なし（systemd未使用またはサービス未登録）" > "$OUTDIR/systemctl_status.txt"
fi

if [ ! -s "$OUTDIR/journalctl_tail.txt" ]; then
  echo "journalctl情報なし（systemd未使用またはサービス未登録）" > "$OUTDIR/journalctl_tail.txt"
fi

#----------------------------------------------------------------------
# 10. ★重要：IMAP/POP3ポート（143/993/110/995）稼働状況
#----------------------------------------------------------------------
echo ""
echo "[10/11] ★ IMAP/POP3ポート稼働状況を確認中..."

{
  echo "#==============================================================================="
  echo "# IMAP/POP3ポート稼働状況"
  echo "#==============================================================================="
  echo "#"
  echo "# ポート: 143 (IMAP), 993 (IMAPS), 110 (POP3), 995 (POP3S)"
  echo "#"
  echo ""

  for port in 143 993 110 995; do
    proto=""
    case "$port" in
      143) proto="IMAP" ;;
      993) proto="IMAPS (TLS)" ;;
      110) proto="POP3" ;;
      995) proto="POP3S (TLS)" ;;
    esac

    if grep -qE "[:.]${port}\s" "$OUTDIR/ss_listen.txt" 2>/dev/null; then
      echo "  → ✓ ポート $port ($proto) : リスン中"
      grep -E "[:.]${port}\s" "$OUTDIR/ss_listen.txt" | head -3 | sed 's/^/      /'
    else
      echo "  → ✗ ポート $port ($proto) : リスンしていません"
    fi
    echo ""
  done
} > "$OUTDIR/imap_ports_summary.txt"

cat "$OUTDIR/imap_ports_summary.txt"

#----------------------------------------------------------------------
# 11. 任意：Maildirサイズ上位N件
#----------------------------------------------------------------------
echo ""
echo "[11/11] Maildirサイズ計算..."

if [ "$TOPN" -gt 0 ] && [ "$MAILDIR_COUNT" -gt 0 ]; then
  echo "  → Maildirサイズ上位 ${TOPN} 件を計算中（時間がかかる場合があります）..."

  {
    echo "#==============================================================================="
    echo "# Maildirサイズ上位 ${TOPN} 件"
    echo "#==============================================================================="
    echo "#"
    echo "# 書式: サイズ（MB）  パス"
    echo "#"
    echo ""

    while IFS= read -r maildir_path; do
      # サイズ計算（MB単位）
      size_kb=$(du -sk "$maildir_path" 2>/dev/null | awk '{print $1}')
      if [ -n "$size_kb" ] && [ "$size_kb" -gt 0 ]; then
        size_mb=$((size_kb / 1024))
        echo "$size_mb $maildir_path"
      fi
    done < "$OUTDIR/maildir_candidates.txt" | sort -rn | head -"$TOPN" | while read -r size path; do
      printf "%10s MB  %s\n" "$size" "$path"
    done
  } > "$OUTDIR/maildir_size_top.txt"

  echo "  → 保存完了: maildir_size_top.txt"
  echo ""
  echo "  上位${TOPN}件:"
  cat "$OUTDIR/maildir_size_top.txt" | tail -$((TOPN + 5))
else
  echo "  → スキップ（-t オプション未指定）"
  echo "# Maildirサイズ計算はスキップされました（-t オプション未指定）" > "$OUTDIR/maildir_size_top.txt"
fi

#----------------------------------------------------------------------
# サマリーJSONの作成
#----------------------------------------------------------------------
echo ""
echo "サマリーJSONを作成中..."

# ポート状態を変数化
IMAP_143="false"
IMAPS_993="false"
POP3_110="false"
POP3S_995="false"

grep -qE "[:.]143\s" "$OUTDIR/ss_listen.txt" 2>/dev/null && IMAP_143="true"
grep -qE "[:.]993\s" "$OUTDIR/ss_listen.txt" 2>/dev/null && IMAPS_993="true"
grep -qE "[:.]110\s" "$OUTDIR/ss_listen.txt" 2>/dev/null && POP3_110="true"
grep -qE "[:.]995\s" "$OUTDIR/ss_listen.txt" 2>/dev/null && POP3S_995="true"

cat > "$OUTDIR/summary.json" << EOF
{
  "timestamp": "$TS",
  "hostname": "$HOST",
  "detected_servers": {
    "courier": $( [ "$DETECTED_COURIER" = true ] && echo "true" || echo "false" ),
    "dovecot": $( [ "$DETECTED_DOVECOT" = true ] && echo "true" || echo "false" )
  },
  "maildir_count": $MAILDIR_COUNT,
  "mbox_count": $MBOX_COUNT,
  "system_users_total": $(wc -l < "$OUTDIR/getent_passwd.txt" 2>/dev/null || echo 0),
  "system_users_regular": ${USER_COUNT:-0},
  "mailbox_user_matches": $MATCHED_COUNT,
  "imap_ports": {
    "port_143_imap": $IMAP_143,
    "port_993_imaps": $IMAPS_993,
    "port_110_pop3": $POP3_110,
    "port_995_pop3s": $POP3S_995
  },
  "maildir_size_top_n": $TOPN,
  "output_files": {
    "maildir_list": "maildir_candidates.txt",
    "mbox_list": "mbox_candidates.txt",
    "mailbox_json": "mailbox_candidates.json",
    "mailbox_user_match": "mailbox_user_match.csv",
    "system_users_csv": "getent_passwd.txt",
    "system_users_json": "getent_passwd.json",
    "doveconf_active": $([ -f "$OUTDIR/doveconf-n.txt" ] && echo "\"doveconf-n.txt\"" || echo "null"),
    "doveconf_all": $([ -f "$OUTDIR/doveconf-a.txt" ] && echo "\"doveconf-a.txt\"" || echo "null"),
    "sql_ldap_configs": $([ -s "$OUTDIR/sql_ldap_configs.txt" ] && echo "\"sql_ldap_configs.txt\"" || echo "null"),
    "authdaemonrc_keys": $([ -f "$OUTDIR/authdaemonrc_keys.txt" ] && echo "\"authdaemonrc_keys.txt\"" || echo "null"),
    "imap_ports_summary": "imap_ports_summary.txt",
    "maildir_size_top": $([ "$TOPN" -gt 0 ] && echo "\"maildir_size_top.txt\"" || echo "null"),
    "config_archives": [
      $([ -f "$OUTDIR/etc_courier.tgz" ] && echo "\"etc_courier.tgz\"" || echo "null"),
      $([ -f "$OUTDIR/etc_dovecot.tgz" ] && echo "\"etc_dovecot.tgz\"" || echo "null")
    ]
  },
  "security_notes": "秘密鍵(.key, .pem等)は除外されています。SQL/LDAP設定のパスワードはマスクされています。仮想ユーザーのパスワードハッシュはマスクされています。"
}
EOF

#----------------------------------------------------------------------
# ユーザー一覧サマリーの作成（既存のテキスト形式も維持）
#----------------------------------------------------------------------
cat > "$OUTDIR/user_summary.txt" << EOF
#===============================================================================
# ユーザー一覧サマリー
#===============================================================================
#
# 作成日時: $TS
# ホスト名: $HOST
#
#-------------------------------------------------------------------------------
# システムユーザー（UID >= 1000）
#-------------------------------------------------------------------------------
EOF

awk -F: '$3 >= 1000 && $3 < 65534 { printf "%-20s UID:%-6s %s\n", $1, $3, $6 }' "$OUTDIR/getent_passwd.txt" >> "$OUTDIR/user_summary.txt"

cat >> "$OUTDIR/user_summary.txt" << EOF

#-------------------------------------------------------------------------------
# Maildir一覧（検出数: $MAILDIR_COUNT）
#-------------------------------------------------------------------------------
EOF

head -100 "$OUTDIR/maildir_candidates.txt" >> "$OUTDIR/user_summary.txt" 2>/dev/null || true

if [ "$MAILDIR_COUNT" -gt 100 ]; then
  echo "... 以下省略（全${MAILDIR_COUNT}件は maildir_candidates.txt を参照）" >> "$OUTDIR/user_summary.txt"
fi

cat >> "$OUTDIR/user_summary.txt" << EOF

#-------------------------------------------------------------------------------
# mbox一覧（検出数: $MBOX_COUNT）
#-------------------------------------------------------------------------------
EOF

head -100 "$OUTDIR/mbox_candidates.txt" >> "$OUTDIR/user_summary.txt" 2>/dev/null || true

if [ "$MBOX_COUNT" -gt 100 ]; then
  echo "... 以下省略（全${MBOX_COUNT}件は mbox_candidates.txt を参照）" >> "$OUTDIR/user_summary.txt"
fi

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
echo "  ★ mailbox_user_match.csv"
echo "     → ユーザー×メールボックス対応表（★最重要）"
echo "     → 検出: $MATCHED_COUNT 件"
echo ""
echo "  ★ user_summary.txt"
echo "     → ユーザー一覧のサマリー（システムユーザー + Maildir + mbox）"
echo ""
echo "  ★ maildir_candidates.txt / mbox_candidates.txt"
echo "     → メールボックスの完全一覧"
echo "     → Maildir: $MAILDIR_COUNT 件, mbox: $MBOX_COUNT 件"
echo ""
echo "  ★ mailbox_candidates.json"
echo "     → メールボックス情報（機械可読）"
echo ""
echo "  ★ getent_passwd.txt / getent_passwd.json"
echo "     → システムユーザーの完全一覧"
echo ""
if [ "$DETECTED_DOVECOT" = true ]; then
  echo "  ★ doveconf-n.txt / doveconf-a.txt"
  echo "     → Dovecot設定（有効設定／全設定）"
  echo ""
fi
if [ "$DETECTED_COURIER" = true ]; then
  echo "  ★ courier_*.conf"
  echo "     → Courier主要設定ファイル"
  echo ""
  echo "  ★ authdaemonrc_keys.txt"
  echo "     → authdaemonrc重要設定抽出"
  echo ""
fi
if [ -s "$OUTDIR/sql_ldap_configs.txt" ]; then
  echo "  ★ sql_ldap_configs.txt"
  echo "     → SQL/LDAP設定（パスワードマスク済み）"
  echo ""
fi
echo "  ★ imap_ports_summary.txt"
echo "     → IMAP/POP3ポート稼働状況（143/993/110/995）"
echo ""
if [ "$TOPN" -gt 0 ]; then
  echo "  ★ maildir_size_top.txt"
  echo "     → Maildirサイズ上位 ${TOPN} 件"
  echo ""
fi
echo "  ★ etc_courier.tgz / etc_dovecot.tgz"
echo "     → IMAPサーバー設定の原本（秘密鍵を除く）"
echo ""
echo "  ★ systemctl_status.txt / journalctl_tail.txt"
echo "     → サービス状態とログ"
echo ""
echo "  ★ summary.json"
echo "     → サマリー情報（機械可読）"
echo ""
echo "【セキュリティ】"
echo "  - 秘密鍵(.key, .pem等)は収集されていません"
echo "  - SQL/LDAP設定のパスワードはマスクされています"
echo "  - 仮想ユーザーのパスワードハッシュはマスクされています"
echo ""
echo "出力先: $OUTDIR"
