#!/bin/bash
set -e

echo "=== Courier IMAP Container Starting ==="

# ディレクトリ作成
mkdir -p /var/run/courier/authdaemon
mkdir -p /var/log/supervisor
mkdir -p /var/mail/vhosts

# 権限設定
chown -R daemon:daemon /var/run/courier
chmod 755 /var/run/courier/authdaemon

# 自己署名証明書生成（存在しない場合）
if [ ! -f /etc/courier/imapd.pem ]; then
    echo "Generating self-signed certificate..."
    openssl req -x509 -newkey rsa:2048 -keyout /tmp/key.pem -out /tmp/cert.pem -days 365 -nodes \
        -subj "/C=JP/ST=Tokyo/L=Tokyo/O=EXO-Lab/OU=IT/CN=courier-imap.lab.local"
    cat /tmp/key.pem /tmp/cert.pem > /etc/courier/imapd.pem
    chmod 600 /etc/courier/imapd.pem
    rm /tmp/key.pem /tmp/cert.pem
fi

# userdb初期化（存在しない場合）
if [ ! -f /etc/courier/userdb ]; then
    echo "Initializing userdb..."
    touch /etc/courier/userdb
    chmod 600 /etc/courier/userdb
    
    # デフォルトテストユーザー作成
    /scripts/create_users.sh
fi

# userdb更新
makeuserdb || true

echo "=== Starting supervisord ==="
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
