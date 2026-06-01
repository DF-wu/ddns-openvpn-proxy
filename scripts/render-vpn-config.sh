#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/vpn-ddns-lib.sh
source "$repo_root/scripts/vpn-ddns-lib.sh"

source_config="${1:-}"

vpn_type="${VPN_TYPE:-$(detect_vpn_type)}"
if [[ "$vpn_type" == "wireguard" ]]; then
  output_config="${2:-${WIREGUARD_RENDERED_CONFIG:-${STATE_DIR:-./state}/wireguard/wg0.conf}}"
else
  output_config="${2:-${OPENVPN_RENDERED_CONFIG:-${STATE_DIR:-./state}/openvpn/current.ovpn}}"
fi

if [[ -n "$source_config" && ! -f "$source_config" ]]; then
  source_config=""
fi

if [[ -z "$source_config" ]]; then
  source_config="$(vpn_detect_source_config)"
fi

remote_host="${DDNS_HOSTNAME:-$(vpn_get_remote_host "$source_config")}"
resolved_ip="$(resolve_ipv4 "$remote_host")"

vpn_render_config "$source_config" "$output_config" "$resolved_ip" "$remote_host"
write_last_ip "$resolved_ip"

log "Rendered $output_config from $source_config using $remote_host -> $resolved_ip"
