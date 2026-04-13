# OpenVPN + SOCKS5 Proxy with DDNS Auto-Reconnect
FROM alpine:3.19

# Install required packages
RUN apk add --no-cache \
    openvpn \
    dante-server \
    bind-tools \
    jq \
    curl \
    bash \
    supervisor

# Create necessary directories
RUN mkdir -p /var/log/supervisor /etc/openvpn /config

# Copy configuration files and scripts
COPY danted.conf /etc/danted.conf
COPY supervisord.conf /etc/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
COPY ddns-monitor.sh /ddns-monitor.sh

# Set permissions
RUN chmod +x /entrypoint.sh /ddns-monitor.sh

# Expose SOCKS5 port
EXPOSE 1080

# Use supervisord to manage processes
ENTRYPOINT ["/entrypoint.sh"]
