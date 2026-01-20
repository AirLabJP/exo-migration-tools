#!/bin/bash
set -e
echo "=== DMZ Internal Postfix Starting ==="
mkdir -p /var/log/supervisor /var/spool/postfix
postmap /etc/postfix/transport
postfix check || true
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
