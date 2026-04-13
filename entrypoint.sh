#!/bin/bash
set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Check required environment variables
if [ -z "$DDNS_HOSTNAME" ]; then
    log "ERROR: DDNS_HOSTNAME environment variable is required"
    exit 1
fi

if [ ! -f "/config/config.ovpn" ]; then
    log "ERROR: /config/config.ovpn not found"
    log "Please mount your OpenVPN config file to /config/config.ovpn"
    exit 1
fi

# Get current DDNS resolved IP
get_ddns_ip() {
    dig +short "$DDNS_HOSTNAME" | head -1
}

# Start OpenVPN with current DDNS IP
start_openvpn() {
    log "Starting OpenVPN..."
    
    CURRENT_IP=$(get_ddns_ip)
    if [ -z "$CURRENT_IP" ]; then
        log "ERROR: Failed to resolve DDNS hostname: $DDNS_HOSTNAME"
        return 1
    fi
    
    log "DDNS $DDNS_HOSTNAME resolved to: $CURRENT_IP"
    
    # Copy config and update remote IP
    cp /config/config.ovpn /tmp/openvpn-config.ovpn
    
    # Extract remote info from original config
    REMOTE_INFO=$(grep "^remote" /config/config.ovpn | head -1)
    REMOTE_PORT=$(echo $REMOTE_INFO | awk '{print $3}')
    REMOTE_PROTO=$(echo $REMOTE_INFO | awk '{print $4}')
    
    # Update remote line with current IP
    sed -i "s/^remote .*/remote $CURRENT_IP ${REMOTE_PORT:-1194} ${REMOTE_PROTO:-udp}/" /tmp/openvpn-config.ovpn
    
    # Start OpenVPN
    openvpn --config /tmp/openvpn-config.ovpn \
        --daemon \
        --log-append /var/log/openvpn.log \
        --status /var/run/openvpn.status 10 \
        --cd /config
    
    log "OpenVPN started with IP: $CURRENT_IP"
}

# Stop OpenVPN
stop_openvpn() {
    log "Stopping OpenVPN..."
    pkill openvpn || true
    sleep 2
}

# Extract remote info from config for logging
REMOTE_INFO=$(grep "^remote" /config/config.ovpn | head -1)
REMOTE_HOST=$(echo $REMOTE_INFO | awk '{print $2}')
REMOTE_PORT=$(echo $REMOTE_INFO | awk '{print $3}')
REMOTE_PROTO=$(echo $REMOTE_INFO | awk '{print $4}')

log "Original remote: $REMOTE_HOST:$REMOTE_PORT ($REMOTE_PROTO)"
log "Will use DDNS: $DDNS_HOSTNAME"

# Initial OpenVPN start
start_openvpn

# Start SOCKS5 proxy
log "Starting Dante SOCKS5 proxy..."
sockd -D -f /etc/danted.conf &

# Start DDNS monitor
log "Starting DDNS monitor..."
/ddns-monitor.sh &

# Use supervisord to keep running
log "Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisord.conf -n
