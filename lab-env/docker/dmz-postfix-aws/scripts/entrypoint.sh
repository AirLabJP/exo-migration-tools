#!/bin/bash
set -e
echo "=== DMZ AWS Postfix Starting ==="
mkdir -p /var/log/supervisor /var/spool/postfix
postmap /etc/postfix/transport
postfix check || true
newaliases 2>/dev/null || true
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
