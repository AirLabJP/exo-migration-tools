#!/bin/bash
# 個別ユーザー追加スクリプト
# 使用法: ./add_user.sh email password [uid] [gid]

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <email> <password> [uid] [gid]"
    echo "Example: $0 newuser@test.example.co.jp password123"
    exit 1
fi

EMAIL="$1"
PASSWORD="$2"
UID_NUM="${3:-$(( $(grep -c '' /etc/courier/userdb 2>/dev/null || echo 0) + 2001 ))}"
GID_NUM="${4:-$UID_NUM}"

MAIL_BASE="/var/mail/vhosts"

# メールアドレスからドメインとユーザー名を抽出
USERNAME="${EMAIL%@*}"
DOMAIN="${EMAIL#*@}"

echo "Adding user: $EMAIL (UID: $UID_NUM, GID: $GID_NUM)"

# ユーザーディレクトリ作成
USER_HOME="$MAIL_BASE/$DOMAIN/$USERNAME"
mkdir -p "$USER_HOME"

# Maildir作成
maildirmake "$USER_HOME/Maildir" 2>/dev/null || mkdir -p "$USER_HOME/Maildir"/{cur,new,tmp}

# 権限設定
chown -R "$UID_NUM:$GID_NUM" "$USER_HOME"
chmod 700 "$USER_HOME"
chmod 700 "$USER_HOME/Maildir"

# パスワードハッシュ生成
ENCRYPTED_PW=$(echo "$PASSWORD" | userdbpw -md5 2>/dev/null || echo "{MD5}$(echo -n "$PASSWORD" | openssl md5 -binary | base64)")

# userdbエントリ追加
cat >> /etc/courier/userdb << EOF
${EMAIL}	uid=${UID_NUM}|gid=${GID_NUM}|home=${USER_HOME}|shell=/bin/false|systempw=${ENCRYPTED_PW}|mail=${USER_HOME}/Maildir
EOF

# userdb更新
makeuserdb

echo "User $EMAIL added successfully."
