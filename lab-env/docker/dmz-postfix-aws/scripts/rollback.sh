#!/bin/bash
# 切り戻しスクリプト
echo "Rolling back transport to original routing..."
cp /etc/postfix/transport.bak /etc/postfix/transport
postmap /etc/postfix/transport
postfix reload
echo "Done. Original routing restored."
