#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/openvpn-ddns-lib.sh
source "$repo_root/scripts/openvpn-ddns-lib.sh"

source_config="${1:-}"
output_config="${2:-${OPENVPN_RENDERED_CONFIG:-${STATE_DIR:-./state}/openvpn/current.ovpn}}"

if [[ -n "$source_config" && ! -f "$source_config" ]]; then
  source_config=""
fi

if [[ -z "$source_config" ]]; then
  source_config="$(detect_source_config)"
fi

remote_host="${DDNS_HOSTNAME:-$(get_remote_host "$source_config")}"
resolved_ip="$(resolve_ipv4 "$remote_host")"

render_openvpn_config "$source_config" "$output_config" "$resolved_ip" "$remote_host"
write_last_ip "$resolved_ip"

log "Rendered $output_config from $source_config using $remote_host -> $resolved_ip"
