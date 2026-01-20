# Courier IMAP サーバー
# 顧客環境の Courier IMAP を再現

FROM debian:bookworm-slim

LABEL maintainer="EXO Migration Lab"
LABEL description="Courier IMAP server for EXO migration testing"

# 必要なパッケージをインストール
RUN apt-get update && apt-get install -y --no-install-recommends \
    courier-imap \
    courier-imap-ssl \
    courier-authdaemon \
    courier-authlib \
    courier-authlib-userdb \
    maildrop \
    procmail \
    rsyslog \
    supervisor \
    openssl \
    ca-certificates \
    bash \
    && rm -rf /var/lib/apt/lists/*

# 設定ディレクトリ
RUN mkdir -p /etc/courier /var/run/courier/authdaemon /var/log/supervisor

# Courier IMAP設定
COPY imapd /etc/courier/imapd
COPY imapd-ssl /etc/courier/imapd-ssl
COPY authdaemonrc /etc/courier/authdaemonrc

# 初期化・ユーザー管理スクリプト
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# supervisord設定
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# メールディレクトリ
RUN mkdir -p /var/mail/vhosts

# ポート公開
EXPOSE 143 993

# ヘルスチェック
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD nc -z localhost 143 || exit 1

# 起動
CMD ["/scripts/entrypoint.sh"]
