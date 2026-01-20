#!/bin/bash
set -e

echo "=== DMZ AWS Postfix Container Starting ==="

# ディレクトリ作成
mkdir -p /var/log/supervisor
mkdir -p /var/spool/postfix

# transportマップ更新
postmap /etc/postfix/transport

# Postfix設定チェック
echo "Checking Postfix configuration..."
postfix check || true

echo "=== Starting supervisord ==="
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
