#!/bin/sh
set -eu

# ddns-vpn: DDNS-to-runtime-profile adapter for VPN backends that require an
# IP-based endpoint (Gluetun, OpenConnect, sing-box).
#
# Deliberately POSIX shell so it runs unmodified from the stock docker:cli image
# without installing packages or building a project-specific image. Protocol
# knowledge lives in scripts/adapters/<VPN_TYPE>.sh; this file owns the
# protocol-agnostic lifecycle: validate -> resolve -> render -> restart -> commit.
#
# See docs/spec.md for the normative contract.

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# The libraries are linted as separate ShellCheck inputs (see Makefile).
# shellcheck disable=SC1091
. "$script_dir/lib/common.sh"
# shellcheck disable=SC1091
. "$script_dir/lib/resolve.sh"
# shellcheck disable=SC1091
. "$script_dir/lib/restart.sh"

# --- Configuration --------------------------------------------------------
# Canonical variables first; legacy GLUETUN_*/OPENVPN_* names remain accepted.

state_dir=${STATE_DIR:-/state}
vpn_type=${VPN_TYPE:-openvpn}
vpn_backend=${VPN_BACKEND:-}
source_config=${VPN_SOURCE_CONFIG:-${OPENVPN_SOURCE_CONFIG:-/source/client.ovpn}}
rendered_config=${VPN_RENDERED_CONFIG:-${OPENVPN_RENDERED_CONFIG:-$state_dir/runtime/vpn.conf}}
# shellcheck disable=SC2034 # consumed by adapters sourced below
rendered_env=${VPN_RENDERED_ENV:-$state_dir/runtime/vpn.env}
last_ip_file=$state_dir/ddns/last-ip
source_hash_file=$state_dir/ddns/source.sha256
heartbeat_file=$state_dir/ddns/watcher-heartbeat
poll_seconds=${DDNS_POLL_SECONDS:-60}
retry_seconds=${DDNS_INIT_RETRY_SECONDS:-5}
vpn_container=${VPN_CONTAINER_NAME:-${GLUETUN_CONTAINER_NAME:-ddns-openvpn-proxy}}
vpn_probe=${VPN_HEALTH_PROBE:-${GLUETUN_HEALTHCHECK_URL:-http://gluetun:9999}}
sidecar_container=${SIDECAR_CONTAINER_NAME:-${VPROXY_CONTAINER_NAME:-}}
sidecar_probe=${SIDECAR_HEALTH_PROBE:-tcp://gluetun:1080}
restart_timeout=${VPN_RESTART_TIMEOUT_SECONDS:-${GLUETUN_RESTART_TIMEOUT_SECONDS:-20}}
health_timeout=${VPN_HEALTH_TIMEOUT_SECONDS:-${GLUETUN_HEALTH_TIMEOUT_SECONDS:-120}}

# Set by adapter_validate.
endpoint_host=
# shellcheck disable=SC2034 # set by adapters, read by adapters
endpoint_port=
# Hostname actually monitored: DDNS_HOSTNAME overrides the profile endpoint.
ddns_hostname=

# --- Backend registry -----------------------------------------------------
# Backend facts the protocol-agnostic core needs. Adding a backend: extend
# these two tables, add a Compose stack file, and document it in docs/spec.md.

backend_known() {
  case $1 in
    gluetun|openconnect|singbox) return 0 ;;
    *) return 1 ;;
  esac
}

# 1 when the backend's proxy listeners can require credentials. Backends
# without authentication are pinned to loopback by validate_environment.
backend_supports_proxy_auth() {
  case $1 in
    gluetun|singbox) printf '1\n' ;;
    openconnect) printf '0\n' ;;
  esac
}

# --- Adapter loading ------------------------------------------------------

load_adapter() {
  case $vpn_type in
    openvpn|wireguard|openconnect|singbox) ;;
    *) die "VPN_TYPE must be openvpn, wireguard, openconnect, or singbox: $vpn_type" ;;
  esac

  adapter_file=$script_dir/adapters/$vpn_type.sh
  [ -r "$adapter_file" ] || die "adapter not found for VPN_TYPE=$vpn_type: $adapter_file"
  # shellcheck source=/dev/null
  . "$adapter_file"

  for required in adapter_backend adapter_display_name adapter_validate \
      adapter_fingerprint adapter_render; do
    type "$required" >/dev/null 2>&1 ||
      die "adapter $vpn_type does not implement $required"
  done

  adapter_backend_id=$(adapter_backend)
  backend_known "$adapter_backend_id" ||
    die "adapter $vpn_type declares unknown backend: $adapter_backend_id"

  if [ -n "$vpn_backend" ] && [ "$vpn_backend" != "$adapter_backend_id" ]; then
    die "VPN_TYPE=$vpn_type belongs to the $adapter_backend_id backend, but this stack is VPN_BACKEND=$vpn_backend; use the matching docker-compose file"
  fi
}

# --- Validation -----------------------------------------------------------

validate_environment() {
  validate_configured_pair OPENVPN \
    "${OPENVPN_USER_CONFIGURED:-0}" "${OPENVPN_PASSWORD_CONFIGURED:-0}"
  validate_configured_pair OPENCONNECT \
    "${OPENCONNECT_USER_CONFIGURED:-0}" "${OPENCONNECT_PASSWORD_CONFIGURED:-0}"
  validate_configured_pair HTTPPROXY \
    "${HTTPPROXY_USER_CONFIGURED:-0}" "${HTTPPROXY_PASSWORD_CONFIGURED:-0}"
  validate_configured_pair SOCKS5 \
    "${SOCKS5_USER_CONFIGURED:-0}" "${SOCKS5_PASSWORD_CONFIGURED:-0}"

  case ${HTTPPROXY_ENABLED:-on} in
    on|off) ;;
    *) die "HTTPPROXY must be on or off" ;;
  esac

  bind_address=${PROXY_BIND_ADDRESS:-127.0.0.1}
  if [ "$bind_address" != 127.0.0.1 ]; then
    [ "$(backend_supports_proxy_auth "$adapter_backend_id")" = 1 ] ||
      die "the $adapter_backend_id backend has no proxy authentication; PROXY_BIND_ADDRESS must stay 127.0.0.1"
    [ "${SOCKS5_USER_CONFIGURED:-0}" = 1 ] ||
      die "SOCKS5 credentials are required when PROXY_BIND_ADDRESS is not 127.0.0.1"
    if [ "${HTTPPROXY_ENABLED:-on}" = on ]; then
      [ "${HTTPPROXY_USER_CONFIGURED:-0}" = 1 ] ||
        die "HTTP proxy credentials are required when PROXY_BIND_ADDRESS is not 127.0.0.1"
    fi
  fi

  ddns_hostname=${DDNS_HOSTNAME:-$endpoint_host}
  validate_hostname "$ddns_hostname" || die "invalid DDNS hostname: $ddns_hostname"
  if is_ipv4 "$ddns_hostname"; then
    die "DDNS target must be a hostname, not an IPv4 address: $ddns_hostname"
  fi

  if [ -n "${DDNS_RESOLVER:-}" ]; then
    is_ipv4 "$DDNS_RESOLVER" || die "DDNS_RESOLVER must be an IPv4 address: $DDNS_RESOLVER"
  fi
  validate_override_ips

  if ! { is_uint "$poll_seconds" && [ "$poll_seconds" -ge 10 ]; }; then
    die "DDNS_POLL_SECONDS must be an integer of at least 10"
  fi
  if ! { is_uint "$retry_seconds" && [ "$retry_seconds" -ge 1 ]; }; then
    die "DDNS_INIT_RETRY_SECONDS must be a positive integer"
  fi
  if ! { is_uint "$restart_timeout" && [ "$restart_timeout" -ge 1 ]; }; then
    die "VPN_RESTART_TIMEOUT_SECONDS must be a positive integer"
  fi
  if ! { is_uint "$health_timeout" && [ "$health_timeout" -ge 1 ]; }; then
    die "VPN_HEALTH_TIMEOUT_SECONDS must be a positive integer"
  fi

  validate_container_name VPN_CONTAINER_NAME "$vpn_container"
  validate_probe VPN_HEALTH_PROBE "$vpn_probe"
  if [ -n "$sidecar_container" ]; then
    validate_container_name SIDECAR_CONTAINER_NAME "$sidecar_container"
    validate_probe SIDECAR_HEALTH_PROBE "$sidecar_probe"
    [ "$vpn_container" != "$sidecar_container" ] ||
      die "VPN_CONTAINER_NAME and SIDECAR_CONTAINER_NAME must be different"
  elif [ "$adapter_backend_id" = gluetun ]; then
    die "the gluetun backend requires SIDECAR_CONTAINER_NAME for the SOCKS5 sidecar"
  fi
}

validate_config() {
  load_adapter
  adapter_validate
  validate_environment
}

# --- Lifecycle ------------------------------------------------------------

render_config() {
  adapter_render "$1"
}

initialize() {
  validate_config
  log INFO "initializing vpn_type=$vpn_type backend=$adapter_backend_id hostname=$ddns_hostname profile=$source_config"

  while :; do
    previous_ip=$(read_state "$last_ip_file" || true)
    if selected_ip=$(resolve_and_select "$previous_ip"); then
      render_config "$selected_ip"
      write_state "$selected_ip" "$last_ip_file"
      write_state "$(adapter_fingerprint)" "$source_hash_file"
      log INFO "rendered profile vpn_type=$vpn_type hostname=$ddns_hostname ip=$selected_ip output=$rendered_config"
      return 0
    fi

    log WARN "DNS lookup failed hostname=$ddns_hostname retry_in=${retry_seconds}s"
    sleep "$retry_seconds"
  done
}

watch_once() {
  touch_heartbeat
  previous_ip=$(read_state "$last_ip_file" || true)
  previous_hash=$(read_state "$source_hash_file" || true)

  if ! selected_ip=$(resolve_and_select "$previous_ip"); then
    log WARN "DNS lookup failed hostname=$ddns_hostname; keeping current tunnel"
    return 0
  fi

  current_hash=$(adapter_fingerprint)
  if [ "$selected_ip" = "$previous_ip" ] &&
     [ "$current_hash" = "$previous_hash" ] &&
     [ -s "$rendered_config" ]; then
    return 0
  fi

  reason=profile-change
  [ "$selected_ip" = "$previous_ip" ] || reason=address-change
  render_config "$selected_ip"

  if restart_vpn_stack; then
    write_state "$selected_ip" "$last_ip_file"
    write_state "$current_hash" "$source_hash_file"
    log INFO "restarted VPN stack vpn_type=$vpn_type reason=$reason hostname=$ddns_hostname old_ip=${previous_ip:-none} new_ip=$selected_ip vpn=$vpn_container sidecar=${sidecar_container:-none}"
    return 0
  fi

  return 1
}

watch() {
  validate_config
  trap 'log INFO "watcher stopping"; exit 0' INT TERM
  log INFO "watching hostname=$ddns_hostname interval=${poll_seconds}s backend=$adapter_backend_id"

  while :; do
    watch_once || true
    [ "${WATCH_ONCE:-0}" = 1 ] && return 0
    sleep "$poll_seconds"
  done
}

healthcheck() {
  is_uint "$poll_seconds" || exit 1
  heartbeat=$(read_state "$heartbeat_file" || true)
  is_uint "$heartbeat" || exit 1
  now=$(date -u '+%s')
  maximum_age=$((poll_seconds * 3 + health_timeout + 30))
  age=$((now - heartbeat))
  [ "$age" -ge 0 ] && [ "$age" -le "$maximum_age" ]
}

usage() {
  cat <<'EOF'
Usage: ddns-vpn.sh COMMAND

Commands:
  validate     Validate the selected VPN profile and environment
  render IP    Render the backend runtime profile with IP (no DNS lookup)
  init         Resolve DDNS and render the initial runtime profile
  watch        Poll DDNS, render changes, and restart the VPN stack
  watch-once   Run one watcher iteration (diagnostics and tests)
  healthcheck  Check that the watcher loop is making progress

Exit codes: 0 success, 1 runtime failure, 64 configuration or usage error.
EOF
}

command=${1:-}
case $command in
  validate)
    validate_config
    log INFO "configuration valid vpn_type=$vpn_type backend=$adapter_backend_id hostname=$ddns_hostname profile=$source_config"
    ;;
  render)
    validate_config
    [ "$#" -eq 2 ] || die "render requires one IPv4 address"
    is_ipv4 "$2" || die "invalid render IPv4 address: $2"
    render_config "$2"
    ;;
  init)
    initialize
    ;;
  watch)
    watch
    ;;
  watch-once)
    validate_config
    watch_once
    ;;
  healthcheck)
    healthcheck
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
