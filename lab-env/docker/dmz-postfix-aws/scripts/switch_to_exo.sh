#!/bin/bash
# EXO移行用transport切替スクリプト
echo "Switching transport to EXO routing..."
cp /etc/postfix/transport.exo /etc/postfix/transport
postmap /etc/postfix/transport
postfix reload
echo "Done. EXO routing enabled for test.example.co.jp"
