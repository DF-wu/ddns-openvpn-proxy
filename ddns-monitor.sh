#!/bin/bash

DDNS_HOSTNAME="${DDNS_HOSTNAME}"
CHECK_INTERVAL="${DDNS_CHECK_INTERVAL:-60}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DDNS] $*"
}

get_ddns_ip() {
    dig +short "$DDNS_HOSTNAME" | head -1
}

get_current_remote_ip() {
    if [ -f /var/run/openvpn.status ]; then
        grep -E "^tcp|udp" /var/run/openvpn.status 2>/dev/null | head -1 | awk '{print $2}' || echo ""
    else
        echo ""
    fi
}

CURRENT_DDNS_IP=$(get_ddns_ip)
log "DDNS Monitor started"
log "Hostname: $DDNS_HOSTNAME"
log "Current DDNS IP: $CURRENT_DDNS_IP"
log "Check interval: ${CHECK_INTERVAL}s"

while true; do
    sleep "$CHECK_INTERVAL"
    
    NEW_DDNS_IP=$(get_ddns_ip)
    
    if [ -z "$NEW_DDNS_IP" ]; then
        log "WARNING: Failed to resolve DDNS hostname"
        continue
    fi
    
    if [ "$NEW_DDNS_IP" != "$CURRENT_DDNS_IP" ]; then
        log "DDNS IP changed! Old: $CURRENT_DDNS_IP, New: $NEW_DDNS_IP"
        log "Restarting OpenVPN with new IP..."
        
        pkill openvpn || true
        sleep 2
        
        /entrypoint.sh restart-vpn &
        
        CURRENT_DDNS_IP="$NEW_DDNS_IP"
        log "OpenVPN restart triggered"
    fi
done
