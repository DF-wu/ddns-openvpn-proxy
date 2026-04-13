#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/openvpn-ddns-lib.sh
source "$repo_root/scripts/openvpn-ddns-lib.sh"

poll_seconds="${DDNS_POLL_SECONDS:-60}"
cooldown_seconds="${DDNS_COOLDOWN_SECONDS:-15}"
rendered_config="${OPENVPN_RENDERED_CONFIG:-${STATE_DIR:-./state}/openvpn/current.ovpn}"
gluetun_container_name="${GLUETUN_CONTAINER_NAME:-ddns-openvpn-proxy}"

source_config="$(detect_source_config)"

remote_host="${DDNS_HOSTNAME:-$(get_remote_host "$source_config")}"

restart_gluetun() {
  docker restart "$gluetun_container_name" >/dev/null
  log "Restarted Gluetun container $gluetun_container_name"
}

run_iteration() {
  local current_ip last_ip
  current_ip="$(resolve_ipv4 "$remote_host")"
  last_ip="$(read_last_ip || true)"

  if [[ "$current_ip" == "$last_ip" && -f "$rendered_config" ]]; then
    log "IP unchanged for $remote_host ($current_ip)"
    return 0
  fi

  render_openvpn_config "$source_config" "$rendered_config" "$current_ip" "$remote_host"
  write_last_ip "$current_ip"
  log "Detected IP update for $remote_host: ${last_ip:-<none>} -> $current_ip"
  restart_gluetun
}

run_iteration

if [[ "${WATCH_ONCE:-0}" == "1" ]]; then
  exit 0
fi

while true; do
  sleep "$poll_seconds"
  run_iteration
  sleep "$cooldown_seconds"
done
