#!/bin/bash
# テストユーザー作成スクリプト
# 顧客環境のユーザー構成を模擬

set -e

echo "=== Creating test users for Courier IMAP ==="

# ドメイン設定
DOMAINS="test.example.co.jp example.co.jp sub.example.co.jp"
MAIL_BASE="/var/mail/vhosts"

# ユーザー情報（ユーザー名:パスワード:UID:GID）
# UID/GIDは1000番台で統一
USERS=(
    "user1:password123:1001:1001"
    "user2:password123:1002:1002"
    "user3:password123:1003:1003"
    "admin:adminpass123:1010:1010"
    "pilot01:pilot123:1101:1101"
    "pilot02:pilot123:1102:1102"
    "pilot03:pilot123:1103:1103"
    "pilot04:pilot123:1104:1104"
    "pilot05:pilot123:1105:1105"
    "test-ml:mlpass123:1200:1200"
)

# userdb クリア
> /etc/courier/userdb

for domain in $DOMAINS; do
    echo "Processing domain: $domain"
    
    # ドメインディレクトリ作成
    mkdir -p "$MAIL_BASE/$domain"
    
    for user_info in "${USERS[@]}"; do
        IFS=':' read -r username password uid gid <<< "$user_info"
        
        # ユーザーディレクトリ作成
        user_home="$MAIL_BASE/$domain/$username"
        mkdir -p "$user_home"
        
        # Maildir作成
        maildirmake "$user_home/Maildir" 2>/dev/null || mkdir -p "$user_home/Maildir"/{cur,new,tmp}
        
        # 権限設定
        chown -R "$uid:$gid" "$user_home"
        chmod 700 "$user_home"
        chmod 700 "$user_home/Maildir"
        
        # userdb登録
        email="${username}@${domain}"
        echo "Adding user: $email"
        
        # パスワードハッシュ生成（userdbpw使用）
        # Courier userdb形式でエントリ追加
        encrypted_pw=$(echo "$password" | userdbpw -md5 2>/dev/null || echo "{MD5}$(echo -n "$password" | openssl md5 -binary | base64)")
        
        # userdbエントリ追加
        cat >> /etc/courier/userdb << EOF
${email}	uid=${uid}|gid=${gid}|home=${user_home}|shell=/bin/false|systempw=${encrypted_pw}|mail=${user_home}/Maildir
EOF
        
    done
done

# userdb更新
echo "Updating userdb..."
makeuserdb

# 権限設定
chmod 600 /etc/courier/userdb*

echo "=== User creation completed ==="
echo ""
echo "Created users:"
for domain in $DOMAINS; do
    for user_info in "${USERS[@]}"; do
        IFS=':' read -r username password uid gid <<< "$user_info"
        echo "  - ${username}@${domain}"
    done
done
