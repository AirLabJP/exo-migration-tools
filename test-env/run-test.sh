#!/bin/bash
# EXO移行スクリプト一括テスト
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY_DIR="$SCRIPT_DIR/../inventory"
RESULTS_DIR="$SCRIPT_DIR/results_$(date +%Y%m%d_%H%M%S)"

echo "=== EXO Migration Script Test ==="
echo "Results will be saved to: $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

# 1. コンテナ起動確認
echo ""
echo "## Checking containers..."
if ! docker ps | grep -q exo-test-mailserver; then
  echo "Starting containers..."
  docker-compose up -d
  sleep 10  # 起動待ち
fi

docker-compose ps

# 2. スクリプトをコンテナにコピー
echo ""
echo "## Copying scripts to containers..."
docker cp "$INVENTORY_DIR/collect_postfix.sh" exo-test-mailserver:/tmp/
docker cp "$INVENTORY_DIR/collect_courier_imap.sh" exo-test-mailserver:/tmp/
docker cp "$INVENTORY_DIR/collect_smtp_dmz.sh" exo-test-dmz:/tmp/

# 3. メインサーバーでスクリプト実行
echo ""
echo "## Running collect_postfix.sh on mailserver..."
docker exec exo-test-mailserver bash -c "chmod +x /tmp/*.sh && /tmp/collect_postfix.sh /tmp/inventory" || {
  echo "[WARNING] collect_postfix.sh had errors (may be expected in Docker)"
}

echo ""
echo "## Running collect_courier_imap.sh on mailserver..."
docker exec exo-test-mailserver bash -c "/tmp/collect_courier_imap.sh /tmp/inventory" || {
  echo "[WARNING] collect_courier_imap.sh had errors (may be expected in Docker)"
}

# 4. DMZでスクリプト実行
echo ""
echo "## Running collect_smtp_dmz.sh on dmz-smtp..."
docker exec exo-test-dmz bash -c "chmod +x /tmp/*.sh && /tmp/collect_smtp_dmz.sh /tmp/inventory" || {
  echo "[WARNING] collect_smtp_dmz.sh had errors (may be expected in Docker)"
}

# 5. 結果回収
echo ""
echo "## Collecting results..."
docker cp exo-test-mailserver:/tmp/inventory "$RESULTS_DIR/mailserver" 2>/dev/null || mkdir -p "$RESULTS_DIR/mailserver"
docker cp exo-test-dmz:/tmp/inventory "$RESULTS_DIR/dmz" 2>/dev/null || mkdir -p "$RESULTS_DIR/dmz"

# 6. 結果表示
echo ""
echo "=== Results ==="
echo ""
echo "## Mailserver results:"
find "$RESULTS_DIR/mailserver" -type f 2>/dev/null | head -20 || echo "(no files)"

echo ""
echo "## DMZ results:"
find "$RESULTS_DIR/dmz" -type f 2>/dev/null | head -20 || echo "(no files)"

# 7. キーファイルの内容確認
echo ""
echo "=== Key File Contents ==="

if [ -f "$RESULTS_DIR/mailserver"/postfix_*/postconf-n.txt ]; then
  echo ""
  echo "## postconf -n (mailserver):"
  head -30 "$RESULTS_DIR/mailserver"/postfix_*/postconf-n.txt
fi

if [ -f "$RESULTS_DIR/mailserver"/postfix_*/key_params.txt ]; then
  echo ""
  echo "## Key parameters:"
  cat "$RESULTS_DIR/mailserver"/postfix_*/key_params.txt
fi

if [ -f "$RESULTS_DIR/dmz"/dmz_smtp_*/mta_type.txt ]; then
  echo ""
  echo "## DMZ MTA type:"
  cat "$RESULTS_DIR/dmz"/dmz_smtp_*/mta_type.txt
fi

echo ""
echo "=== Test Complete ==="
echo "Full results: $RESULTS_DIR"
