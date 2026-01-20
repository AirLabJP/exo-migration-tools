# DMZ Postfix Internal（内部DMZ・EXOフォールバック用）
# EXOから未移行ユーザーへのフォールバック経路

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    postfix postfix-pcre rsyslog supervisor ca-certificates bash netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/postfix /var/log/supervisor /var/spool/postfix

COPY main.cf /etc/postfix/main.cf
COPY master.cf /etc/postfix/master.cf
COPY transport /etc/postfix/transport
COPY header_checks /etc/postfix/header_checks
COPY scripts/ /scripts/
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

RUN chmod +x /scripts/*.sh

EXPOSE 25

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD nc -z localhost 25 || exit 1

CMD ["/scripts/entrypoint.sh"]
