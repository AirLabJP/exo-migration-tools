#!/usr/bin/env bash
#===============================================================================
# Courier IMAP / Dovecot 設定棚卸しスクリプト
#===============================================================================
#
# 【目的】
#   IMAPサーバー（Courier IMAP または Dovecot）の設定とユーザー情報を収集し、
#   EXO移行計画に必要な情報を取得する
#
# 【収集する情報】
#   - IMAPサーバー設定（認証方式、ポート等）
#   - メールボックス一覧（Maildir形式）
#   - ユーザー一覧（システムユーザー / 仮想ユーザー）
#
# 【出力先】
#   ./inventory_YYYYMMDD_HHMMSS/courier_imap_<ホスト名>/
#
# 【実行方法】
#   sudo bash collect_courier_imap.sh [出力先ディレクトリ]
#
# 【出力ファイルと確認ポイント】
#   etc_courier.tgz       ← Courier IMAP設定原本（秘密鍵を除く）
#   etc_dovecot.tgz       ← Dovecot設定原本（秘密鍵を除く）
#   maildir_candidates.txt ← ★重要: メールボックス一覧（Maildirパス）
#   maildir_candidates.json← 詳細データ（機械可読）
#   maildir_count.txt     ← メールボックス数
#   getent_passwd.txt     ← ★重要: システムユーザー一覧
#   getent_passwd.json    ← 詳細データ（機械可読）
#   getent_group.txt      ← グループ一覧
#   userdb / users        ← 仮想ユーザー定義（パスワードハッシュをマスク）
#   summary.json          ← サマリー情報（機械可読）
#
#===============================================================================
set -euo pipefail

# タイムスタンプとホスト名を取得
TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUTROOT="${1:-./inventory_${TS}}"
OUTDIR="${OUTROOT}/courier_imap_${HOST}"
mkdir -p "$OUTDIR"

# 後片付け関数
cleanup() {
  echo ""
  echo "後片付け実行中..."
  # 一時ファイルの削除（必要に応じて）
  # 現在は特に削除するものはないが、将来的に追加する場合に備えて関数を用意
}

# trap設定（EXIT, ERR, INT, TERM時に後片付けを実行）
trap cleanup EXIT ERR INT TERM

# 実行ログを記録開始
exec > >(tee -a "$OUTDIR/run.log") 2>&1

echo "============================================================"
echo " Courier IMAP / Dovecot 設定棚卸し"
echo "============================================================"
echo "実行日時: $TS"
echo "ホスト名: $HOST"
echo "出力先:   $OUTDIR"
echo ""

#----------------------------------------------------------------------
# 1. システム情報の取得
#----------------------------------------------------------------------
echo "[1/6] システム情報を取得中..."
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
echo "[2/6] メール関連プロセスを確認中..."
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
# 3. 設定ファイルのアーカイブ（秘密鍵を除外）
#----------------------------------------------------------------------
echo ""
echo "[3/6] 設定ファイルをアーカイブ中..."
echo "  → 秘密鍵(.key, .pem等)は除外します"

# Courier IMAP設定
if [ -d /etc/courier ]; then
  # 秘密鍵を除外してアーカイブ
  tar -czf "$OUTDIR/etc_courier.tgz" -C /etc \
    --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
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
    dovecot 2>/dev/null || true
  echo "  → 保存完了: $OUTDIR/etc_dovecot.tgz (Dovecot, 秘密鍵除外)"
else
  echo "  → /etc/dovecot が見つかりません（Dovecot未使用の可能性）"
fi

#----------------------------------------------------------------------
# 4. ★重要：メールボックス（Maildir）の検索
#----------------------------------------------------------------------
echo ""
echo "[4/6] ★ メールボックス（Maildir）を検索中..."
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
COUNT=0
> "$OUTDIR/maildir_candidates.txt"

echo ""
echo "  Maildirを検索中（最大${N}件）..."
for base in "${CANDIDATES[@]}"; do
  [ -d "$base" ] || continue
  while IFS= read -r p; do
    echo "$p" >> "$OUTDIR/maildir_candidates.txt"
    COUNT=$((COUNT+1))
    [ "$COUNT" -ge "$N" ] && break 2
  done < <(find "$base" -maxdepth 6 -type d -name Maildir 2>/dev/null)
done

echo "Maildir検出数: $COUNT" | tee "$OUTDIR/maildir_count.txt"

# JSON出力（機械可読）
echo "  → JSON形式で出力中..."
{
  echo "{"
  echo "  \"timestamp\": \"$TS\","
  echo "  \"hostname\": \"$HOST\","
  echo "  \"maildir_count\": $COUNT,"
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
  echo "  ]"
  echo "}"
} > "$OUTDIR/maildir_candidates.json"

# 検出されたMaildirの例を表示
if [ "$COUNT" -gt 0 ]; then
  echo ""
  echo "  検出されたMaildirの例（最大10件）:"
  head -10 "$OUTDIR/maildir_candidates.txt" | while read -r p; do
    echo "    $p"
  done
fi

#----------------------------------------------------------------------
# 5. ★重要：ユーザー一覧の取得
#----------------------------------------------------------------------
echo ""
echo "[5/6] ★ ユーザー一覧を取得中..."

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
# 6. サマリーJSONの作成
#----------------------------------------------------------------------
echo ""
echo "[6/6] サマリーJSONを作成中..."

cat > "$OUTDIR/summary.json" << EOF
{
  "timestamp": "$TS",
  "hostname": "$HOST",
  "detected_servers": {
    "courier": $( [ "$DETECTED_COURIER" = true ] && echo "true" || echo "false" ),
    "dovecot": $( [ "$DETECTED_DOVECOT" = true ] && echo "true" || echo "false" )
  },
  "maildir_count": $COUNT,
  "system_users_total": $(wc -l < "$OUTDIR/getent_passwd.txt"),
  "system_users_regular": ${USER_COUNT:-0},
  "output_files": {
    "maildir_list_csv": "maildir_candidates.txt",
    "maildir_list_json": "maildir_candidates.json",
    "system_users_csv": "getent_passwd.txt",
    "system_users_json": "getent_passwd.json",
    "config_archives": [
      $([ -f "$OUTDIR/etc_courier.tgz" ] && echo "\"etc_courier.tgz\"" || echo "null"),
      $([ -f "$OUTDIR/etc_dovecot.tgz" ] && echo "\"etc_dovecot.tgz\"" || echo "null")
    ]
  },
  "security_notes": "秘密鍵(.key, .pem等)は除外されています。仮想ユーザーのパスワードハッシュはマスクされています。"
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
# Maildir一覧（検出数: $COUNT）
#-------------------------------------------------------------------------------
EOF

head -100 "$OUTDIR/maildir_candidates.txt" >> "$OUTDIR/user_summary.txt"

if [ "$COUNT" -gt 100 ]; then
  echo "... 以下省略（全${COUNT}件は maildir_candidates.txt を参照）" >> "$OUTDIR/user_summary.txt"
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
echo "  ★ user_summary.txt"
echo "     → ユーザー一覧のサマリー（システムユーザー + Maildir）"
echo ""
echo "  ★ maildir_candidates.txt / maildir_candidates.json"
echo "     → メールボックス（Maildir）の完全一覧"
echo "     → 検出数: $COUNT"
echo ""
echo "  ★ getent_passwd.txt / getent_passwd.json"
echo "     → システムユーザーの完全一覧"
echo ""
echo "  ★ etc_courier.tgz / etc_dovecot.tgz"
echo "     → IMAPサーバー設定の原本（秘密鍵を除く）"
echo ""
echo "  ★ summary.json"
echo "     → サマリー情報（機械可読）"
echo ""
echo "【セキュリティ】"
echo "  - 秘密鍵(.key, .pem等)は収集されていません"
echo "  - 仮想ユーザーのパスワードハッシュはマスクされています"
echo ""
echo "出力先: $OUTDIR"
