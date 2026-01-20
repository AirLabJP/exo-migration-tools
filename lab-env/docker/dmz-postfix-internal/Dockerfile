# DMZ Postfix Internal（内部DMZ）
# EXOからのフォールバック用
# Internal Relay時に未移行ユーザー宛をCourier IMAPへ転送

FROM debian:bookworm-slim

LABEL maintainer="EXO Migration Lab"
LABEL description="Internal DMZ SMTP for EXO fallback routing"

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
COPY header_checks /etc/postfix/header_checks

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
