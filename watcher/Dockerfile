FROM alpine:3.20

RUN apk add --no-cache bash bind-tools curl docker-cli python3

WORKDIR /app

COPY scripts/vpn-ddns-lib.sh /app/scripts/vpn-ddns-lib.sh
COPY scripts/render-vpn-config.sh /app/scripts/render-vpn-config.sh
COPY scripts/ddns-init.sh /app/scripts/ddns-init.sh
COPY scripts/watch-ddns-and-restart.sh /app/scripts/watch-ddns-and-restart.sh

ENTRYPOINT ["/app/scripts/watch-ddns-and-restart.sh"]
