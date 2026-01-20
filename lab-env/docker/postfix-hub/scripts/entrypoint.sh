#!/bin/bash
set -e

echo "=== Postfix Hub Container Starting ==="

# ディレクトリ作成
mkdir -p /var/log/supervisor
mkdir -p /var/spool/postfix

# transportマップ更新
postmap /etc/postfix/transport
postmap /etc/postfix/virtual

# Postfix設定チェック
echo "Checking Postfix configuration..."
postfix check || true

# エイリアスDB更新
newaliases 2>/dev/null || true

echo "=== Starting supervisord ==="
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
