#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/vpn-ddns-lib.sh
source "$repo_root/scripts/vpn-ddns-lib.sh"

source_config="$(vpn_detect_source_config)"
remote_host="${DDNS_HOSTNAME:-$(vpn_get_remote_host "$source_config")}"

vpn_type="${VPN_TYPE:-$(detect_vpn_type)}"
if [[ "$vpn_type" == "wireguard" ]]; then
  output_config="${WIREGUARD_RENDERED_CONFIG:-${STATE_DIR:-./state}/wireguard/wg0.conf}"
else
  output_config="${OPENVPN_RENDERED_CONFIG:-${STATE_DIR:-./state}/openvpn/current.ovpn}"
fi

retry_seconds="${DDNS_INIT_RETRY_SECONDS:-5}"
max_attempts="${DDNS_INIT_MAX_ATTEMPTS:-0}"
attempt=1

while true; do
  if resolved_ip="$(resolve_ipv4 "$remote_host" 2>&1)"; then
    vpn_render_config "$source_config" "$output_config" "$resolved_ip" "$remote_host"
    write_last_ip "$resolved_ip"
    log "Rendered $output_config from $source_config using $remote_host -> $resolved_ip"
    exit 0
  fi

  if [[ "$max_attempts" != "0" && "$attempt" -ge "$max_attempts" ]]; then
    log "Failed to resolve $remote_host after $attempt attempts: $resolved_ip"
    exit 1
  fi

  log "Resolve attempt $attempt for $remote_host failed: $resolved_ip"
  log "Retrying ddns-init in ${retry_seconds}s"
  attempt=$((attempt + 1))
  sleep "$retry_seconds"
done
