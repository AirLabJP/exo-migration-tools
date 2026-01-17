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
#   etc_courier.tgz       ← Courier IMAP設定原本（存在する場合）
#   etc_dovecot.tgz       ← Dovecot設定原本（存在する場合）
#   maildir_candidates.txt ← ★重要: メールボックス一覧（Maildirパス）
#   maildir_count.txt     ← メールボックス数
#   getent_passwd.txt     ← ★重要: システムユーザー一覧
#   getent_group.txt      ← グループ一覧
#   userdb / users        ← 仮想ユーザー定義（存在する場合）
#
#===============================================================================
set -euo pipefail

# タイムスタンプとホスト名を取得
TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUTROOT="${1:-./inventory_${TS}}"
OUTDIR="${OUTROOT}/courier_imap_${HOST}"
mkdir -p "$OUTDIR"

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
if grep -qi 'courier' "$OUTDIR/ps_mail.txt" 2>/dev/null; then
  echo "  → Courier IMAP を検出"
fi
if grep -qi 'dovecot' "$OUTDIR/ps_mail.txt" 2>/dev/null; then
  echo "  → Dovecot を検出"
fi

#----------------------------------------------------------------------
# 3. 設定ファイルのアーカイブ
#----------------------------------------------------------------------
echo ""
echo "[3/6] 設定ファイルをアーカイブ中..."

# Courier IMAP設定
if [ -d /etc/courier ]; then
  tar -czf "$OUTDIR/etc_courier.tgz" -C /etc courier
  echo "  → 保存完了: $OUTDIR/etc_courier.tgz (Courier IMAP)"
else
  echo "  → /etc/courier が見つかりません（Courier未使用の可能性）"
fi

# Dovecot設定（Courier IMAPの代替として使われている場合）
if [ -d /etc/dovecot ]; then
  tar -czf "$OUTDIR/etc_dovecot.tgz" -C /etc dovecot
  echo "  → 保存完了: $OUTDIR/etc_dovecot.tgz (Dovecot)"
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

# メールユーザーの抽出（UID 1000以上の一般ユーザー）
echo ""
echo "  一般ユーザー（UID >= 1000）:"
awk -F: '$3 >= 1000 && $3 < 65534 { print "    " $1 " (UID:" $3 ", Home:" $6 ")" }' "$OUTDIR/getent_passwd.txt" | head -20
USER_COUNT=$(awk -F: '$3 >= 1000 && $3 < 65534 { count++ } END { print count }' "$OUTDIR/getent_passwd.txt")
echo "  → 一般ユーザー数: ${USER_COUNT:-0}"

# 仮想ユーザー定義ファイル
echo ""
echo "  → 仮想ユーザー定義ファイルを検索..."
for vf in /etc/courier/userdb /etc/dovecot/users /etc/postfix/vmailbox; do
  if [ -f "$vf" ]; then
    cp -a "$vf" "$OUTDIR/" 2>/dev/null || true
    echo "    ✓ コピー: $vf"
    # ユーザー数をカウント
    VU_COUNT=$(grep -c '^[^#]' "$vf" 2>/dev/null || echo 0)
    echo "      → 仮想ユーザー数: $VU_COUNT"
  fi
done

#----------------------------------------------------------------------
# 6. ユーザー一覧サマリーの作成
#----------------------------------------------------------------------
echo ""
echo "[6/6] ユーザー一覧サマリーを作成中..."

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
echo "  ★ maildir_candidates.txt"
echo "     → メールボックス（Maildir）の完全一覧"
echo "     → 検出数: $COUNT"
echo ""
echo "  ★ getent_passwd.txt"
echo "     → システムユーザーの完全一覧"
echo ""
echo "  ★ etc_courier.tgz / etc_dovecot.tgz"
echo "     → IMAPサーバー設定の原本"
echo ""
echo "出力先: $OUTDIR"
