#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$repo_root/scripts/vpn-ddns-lib.sh"

poll_seconds="${DDNS_POLL_SECONDS:-60}"
cooldown_seconds="${DDNS_COOLDOWN_SECONDS:-15}"

vpn_type="${VPN_TYPE:-$(detect_vpn_type)}"
if [[ "$vpn_type" == "wireguard" ]]; then
  rendered_config="${WIREGUARD_RENDERED_CONFIG:-${STATE_DIR:-./state}/wireguard/wg0.conf}"
else
  rendered_config="${OPENVPN_RENDERED_CONFIG:-${STATE_DIR:-./state}/openvpn/current.ovpn}"
fi

gluetun_container_name="${GLUETUN_CONTAINER_NAME:-ddns-openvpn-proxy}"
vproxy_container_name="${VPROXY_CONTAINER_NAME:-ddns-vpn-proxy-vproxy}"
health_timeout_seconds="${GLUETUN_HEALTH_TIMEOUT_SECONDS:-120}"

source_config="$(vpn_detect_source_config)"

remote_host="${DDNS_HOSTNAME:-$(vpn_get_remote_host "$source_config")}"

container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null
}

wait_container_healthy() {
  local container="$1" deadline status
  deadline=$((SECONDS + health_timeout_seconds))
  while (( SECONDS < deadline )); do
    status="$(container_health "$container" || true)"
    if [[ "$status" == "healthy" || "$status" == "running" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

restart_vpn_stack() {
  docker restart "$gluetun_container_name" >/dev/null
  log "Restarted Gluetun container $gluetun_container_name"
  if ! wait_container_healthy "$gluetun_container_name"; then
    log "Gluetun did not become healthy within ${health_timeout_seconds}s; keeping state unchanged"
    return 1
  fi

  docker restart "$vproxy_container_name" >/dev/null
  log "Restarted vproxy container $vproxy_container_name"
  if ! wait_container_healthy "$vproxy_container_name"; then
    log "vproxy did not become healthy within ${health_timeout_seconds}s; keeping state unchanged"
    return 1
  fi
}

run_iteration() {
  local addresses current_ip last_ip
  last_ip="$(read_last_ip || true)"

  if ! addresses="$(resolve_ipv4s "$remote_host")" || [[ -z "$addresses" ]]; then
    log "DNS lookup failed for $remote_host; preserving the active profile and tunnel"
    return 0
  fi

  if [[ -n "$last_ip" ]] && grep -Fxq "$last_ip" <<<"$addresses"; then
    current_ip="$last_ip"
  else
    current_ip="$(head -1 <<<"$addresses")"
  fi

  if ! is_ipv4 "$current_ip"; then
    log "DNS returned no valid IPv4 address for $remote_host; preserving the active profile and tunnel"
    return 0
  fi

  if [[ "$current_ip" == "$last_ip" && -f "$rendered_config" ]]; then
    log "IP unchanged for $remote_host ($current_ip)"
    return 0
  fi

  vpn_render_config "$source_config" "$rendered_config" "$current_ip" "$remote_host"
  log "Detected IP update for $remote_host: ${last_ip:-<none>} -> $current_ip"
  if restart_vpn_stack; then
    write_last_ip "$current_ip"
    return 0
  fi
  return 1
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
