#!/bin/bash
# ルーティング切り戻しスクリプト
# EXO移行を切り戻して既存経路に戻す

set -e

TRANSPORT_FILE="/etc/postfix/transport"
ORIGINAL_BACKUP="/etc/postfix/transport.bak"

echo "=== Routing Rollback ==="

if [ ! -f "$ORIGINAL_BACKUP" ]; then
    echo "Error: Original backup file not found: $ORIGINAL_BACKUP"
    exit 1
fi

# 現在の設定をバックアップ
CURRENT_BACKUP="/etc/postfix/transport.rollback_$(date +%Y%m%d_%H%M%S).bak"
echo "Backing up current config to: $CURRENT_BACKUP"
cp "$TRANSPORT_FILE" "$CURRENT_BACKUP"

# オリジナルを復元
echo "Restoring original configuration..."
cp "$ORIGINAL_BACKUP" "$TRANSPORT_FILE"

# postmap更新
echo "Updating postmap..."
postmap "$TRANSPORT_FILE"

# Postfixリロード
echo "Reloading Postfix..."
postfix reload

echo "=== Rollback completed ==="
echo ""
echo "Current transport configuration:"
cat "$TRANSPORT_FILE"
