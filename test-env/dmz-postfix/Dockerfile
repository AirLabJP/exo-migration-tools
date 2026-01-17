FROM alpine:3.19

RUN apk add --no-cache postfix postfix-pcre rsyslog bash

# 設定ファイルコピー
COPY main.cf /etc/postfix/main.cf
COPY transport /etc/postfix/transport
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 25

CMD ["/entrypoint.sh"]
