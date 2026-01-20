# DMZ Postfix AWS（外部受口）
# 顧客環境のAWS DMZ SMTPを再現
# FireEyeからのメール受信、およびEXO移行後のルーティング変更対象

FROM debian:bookworm-slim

LABEL maintainer="EXO Migration Lab"
LABEL description="AWS DMZ SMTP relay for EXO migration testing"

# 必要なパッケージをインストール
RUN apt-get update && apt-get install -y --no-install-recommends \
    postfix \
    postfix-pcre \
    rsyslog \
    supervisor \
    ca-certificates \
    bash \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# 設定ディレクトリ
RUN mkdir -p /etc/postfix /var/log/supervisor /var/spool/postfix

# Postfix設定
COPY main.cf /etc/postfix/main.cf
COPY master.cf /etc/postfix/master.cf
COPY transport /etc/postfix/transport
COPY transport.bak /etc/postfix/transport.bak

# 初期化スクリプト
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# supervisord設定
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# ポート公開
EXPOSE 25

# ヘルスチェック
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD nc -z localhost 25 || exit 1

# 起動
CMD ["/scripts/entrypoint.sh"]
