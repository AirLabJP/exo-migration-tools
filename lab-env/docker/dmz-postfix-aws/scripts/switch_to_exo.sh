#!/bin/bash
# EXO移行用ルーティング切替スクリプト
# 指定ドメインをEXOへルーティング変更

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <domain> <exo_endpoint>"
    echo "Example: $0 test.example.co.jp tenant.mail.protection.outlook.com"
    exit 1
fi

DOMAIN="$1"
EXO_ENDPOINT="$2"
TRANSPORT_FILE="/etc/postfix/transport"
BACKUP_FILE="/etc/postfix/transport.$(date +%Y%m%d_%H%M%S).bak"

echo "=== EXO Routing Switch ==="
echo "Domain: $DOMAIN"
echo "EXO Endpoint: $EXO_ENDPOINT"

# バックアップ作成
echo "Creating backup: $BACKUP_FILE"
cp "$TRANSPORT_FILE" "$BACKUP_FILE"

# 既存エントリを更新
if grep -q "^${DOMAIN}" "$TRANSPORT_FILE"; then
    echo "Updating existing entry..."
    sed -i "s|^${DOMAIN}.*|${DOMAIN}    smtp:[${EXO_ENDPOINT}]:25|" "$TRANSPORT_FILE"
else
    echo "Adding new entry..."
    echo "${DOMAIN}    smtp:[${EXO_ENDPOINT}]:25" >> "$TRANSPORT_FILE"
fi

# postmap更新
echo "Updating postmap..."
postmap "$TRANSPORT_FILE"

# Postfixリロード
echo "Reloading Postfix..."
postfix reload

echo "=== Routing switch completed ==="
echo ""
echo "New transport configuration:"
grep "^${DOMAIN}" "$TRANSPORT_FILE"
echo ""
echo "To rollback, run:"
echo "  cp $BACKUP_FILE $TRANSPORT_FILE && postmap $TRANSPORT_FILE && postfix reload"
