#!/bin/bash
#===============================================================================
# DMZ SMTP ルーティング復元スクリプト
#===============================================================================
#
# 【目的】
#   Set-DmzSmtpRouting.sh で変更したルーティング設定を元に戻します。
#
# 【使用方法】
#   # バックアップファイルを指定して復元
#   sudo bash Restore-DmzSmtpRouting.sh /etc/postfix/transport.backup.YYYYMMDD_HHMMSS
#
#   # 最新のバックアップを自動検出して復元
#   sudo bash Restore-DmzSmtpRouting.sh --latest
#
# 【注意】
#   - root権限で実行
#   - 復元前に現在の設定がバックアップされます
#   - postmap と postfix reload が自動実行されます
#
#===============================================================================

set -e

TRANSPORT_FILE="/etc/postfix/transport"
TS=$(date +%Y%m%d_%H%M%S)
OUTDIR="/tmp/dmz_smtp_routing_restore_$TS"

# 使用方法
usage() {
  cat <<EOF
使用方法: $0 <バックアップファイル|--latest>

引数:
  <バックアップファイル>  復元に使用するバックアップファイルのパス
                          例: /etc/postfix/transport.backup.20260117_120000

  --latest               /etc/postfix/transport.backup.* から最新のものを自動選択

オプション:
  -t FILE     transport ファイルのパス（デフォルト: /etc/postfix/transport）
  -n          ドライラン（実際には復元しない）
  -h          このヘルプを表示

例:
  # 特定のバックアップから復元
  sudo bash $0 /etc/postfix/transport.backup.20260117_120000

  # 最新のバックアップから復元
  sudo bash $0 --latest

  # ドライラン
  sudo bash $0 --latest -n

EOF
  exit 1
}

# 引数解析
BACKUP_FILE=""
DRY_RUN=false

# 最初の引数がバックアップファイルまたは --latest
if [ $# -eq 0 ]; then
  usage
fi

case "$1" in
  --latest)
    # 最新のバックアップを検索
    BACKUP_FILE=$(ls -t /etc/postfix/transport.backup.* 2>/dev/null | head -1)
    if [ -z "$BACKUP_FILE" ]; then
      echo "エラー: バックアップファイルが見つかりません: /etc/postfix/transport.backup.*"
      exit 1
    fi
    shift
    ;;
  -h|--help)
    usage
    ;;
  -*)
    echo "エラー: 不明なオプション: $1"
    usage
    ;;
  *)
    BACKUP_FILE="$1"
    shift
    ;;
esac

# 残りのオプションを解析
while getopts "t:nh" opt; do
  case $opt in
    t) TRANSPORT_FILE="$OPTARG" ;;
    n) DRY_RUN=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

# 出力ディレクトリ作成
mkdir -p "$OUTDIR"
exec > >(tee -a "$OUTDIR/run.log") 2>&1

echo "============================================================"
echo " DMZ SMTP ルーティング復元"
echo "============================================================"
echo "実行日時: $(date)"
echo "ホスト名: $(hostname)"
echo "出力先:   $OUTDIR"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "【ドライランモード】実際の復元は行いません"
  echo ""
fi

#----------------------------------------------------------------------
# バックアップファイルの確認
#----------------------------------------------------------------------
echo "[1/4] バックアップファイルを確認..."
echo "      → バックアップ: $BACKUP_FILE"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "エラー: バックアップファイルが見つかりません: $BACKUP_FILE"
  exit 1
fi

# バックアップの内容を表示
echo ""
echo "【バックアップファイルの内容（先頭20行）】"
head -20 "$BACKUP_FILE" | sed 's/^/  /'
TOTAL_LINES=$(wc -l < "$BACKUP_FILE")
if [ "$TOTAL_LINES" -gt 20 ]; then
  echo "  ... (残り $((TOTAL_LINES - 20)) 行)"
fi

#----------------------------------------------------------------------
# 現在の設定をバックアップ
#----------------------------------------------------------------------
echo ""
echo "[2/4] 現在の設定をバックアップ..."

BACKUP_CURRENT="${TRANSPORT_FILE}.before_restore.${TS}"

if [ -f "$TRANSPORT_FILE" ]; then
  cp "$TRANSPORT_FILE" "$BACKUP_CURRENT"
  echo "      → 保存: $BACKUP_CURRENT"
  cp "$TRANSPORT_FILE" "$OUTDIR/transport_before_restore.txt"
else
  echo "      → 現在のtransportファイルが存在しません"
  touch "$OUTDIR/transport_before_restore.txt"
fi

#----------------------------------------------------------------------
# 復元実行
#----------------------------------------------------------------------
echo ""
echo "[3/4] ★ 設定を復元..."

if [ "$DRY_RUN" = true ]; then
  echo "      → ドライランのため、実際の復元はスキップ"
  echo "      → 復元後の状態: $BACKUP_FILE の内容と同じになります"
else
  cp "$BACKUP_FILE" "$TRANSPORT_FILE"
  echo "      → 復元完了: $BACKUP_FILE → $TRANSPORT_FILE"
  
  # 復元後の内容を保存
  cp "$TRANSPORT_FILE" "$OUTDIR/transport_after_restore.txt"
fi

#----------------------------------------------------------------------
# Postfix設定を反映
#----------------------------------------------------------------------
echo ""
echo "[4/4] Postfix設定を反映..."

if [ "$DRY_RUN" = true ]; then
  echo "      → ドライランのため、postmap/reload はスキップ"
else
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
  echo "  実際の復元は行われていません。"
  echo "  問題がなければ -n オプションなしで再実行してください:"
  echo ""
  echo "  sudo bash $0 $BACKUP_FILE"
else
  echo "【復元完了】"
  echo "  復元元:     $BACKUP_FILE"
  echo "  復元前保存: $BACKUP_CURRENT"
  echo ""
  echo "【再度ロールバックが必要な場合】"
  echo "  sudo bash $0 $BACKUP_CURRENT"
fi

echo ""
echo "【確認コマンド】"
echo "  # ルーティング設定確認"
echo "  cat $TRANSPORT_FILE"
echo ""
echo "  # テストメール送信後のログ確認"
echo "  tail -f /var/log/maillog | grep -E 'postfix|smtp'"
echo ""
echo "【次のステップ】"
echo "  1. EXO側のAccepted Domainを Authoritative に戻す"
echo "  2. EXOコネクタを削除する（必要な場合）"
echo "  3. テストメールで動作確認"
echo ""
echo "出力先: $OUTDIR"
