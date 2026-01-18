#!/bin/bash
set -e

# transport mapをハッシュ化
postmap /etc/postfix/transport

# rsyslog起動（ログ用）
rsyslogd

# Postfix起動
postfix start-fg
