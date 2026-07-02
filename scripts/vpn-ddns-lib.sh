#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# vpn-ddns-lib.sh — Multi-protocol DDNS VPN library
#
# Supports OpenVPN and WireGuard through a unified dispatch layer.
# Consumers can either:
#   1. Set VPN_TYPE (openvpn/wireguard) and use dispatch functions directly, or
#   2. Source openvpn-ddns-lib.sh (sets VPN_TYPE=openvpn) for backward compat.
#
# Dispatch functions:
#   vpn_detect_source_config   → detect_source_config / detect_wg_source_config
#   vpn_get_remote_host        → get_remote_host / get_wg_endpoint_host
#   vpn_render_config          → render_openvpn_config / render_wireguard_config
#
# Shared utilities (protocol-agnostic):
#   log, resolve_ipv4, write_last_ip, read_last_ip
# =============================================================================

# -----------------------------------------------------------------------------
# Shared utilities
# -----------------------------------------------------------------------------

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# -----------------------------------------------------------------------------
# VPN type detection
# -----------------------------------------------------------------------------

# Detect VPN type from explicit vars, config file extension, or source dirs.
# Priority: VPN_TYPE env var > config extension > auto-detect from source dirs.
# .ovpn → openvpn, .conf with [Interface] → wireguard.
# Returns: "openvpn" or "wireguard"
detect_vpn_type() {
  if [[ -n "${VPN_TYPE:-}" ]]; then
    printf '%s\n' "$VPN_TYPE"
    return 0
  fi

  local explicit_config
  for explicit_config in "${VPN_SOURCE_CONFIG:-}" "${OPENVPN_SOURCE_CONFIG:-}" "${WIREGUARD_SOURCE_CONFIG:-}"; do
    if [[ -z "$explicit_config" ]]; then
      continue
    fi

    case "$explicit_config" in
      *.ovpn)
        printf 'openvpn\n'
        return 0
        ;;
      *.conf)
        if [[ -f "$explicit_config" ]] && grep -q '^[[:space:]]*\[Interface\]' "$explicit_config" 2>/dev/null; then
          printf 'wireguard\n'
          return 0
        fi
        # Fall through to auto-detect — could be OpenVPN .conf
        ;;
    esac
  done

  local ovpn_dir="${OPENVPN_SOURCE_DIR:-./config/openvpn}"
  local wg_dir="${WIREGUARD_SOURCE_DIR:-./config/wireguard}"

  if [[ -d "$ovpn_dir" ]]; then
    local ovpn_files
    mapfile -t ovpn_files < <(find "$ovpn_dir" -maxdepth 1 -type f -name '*.ovpn' 2>/dev/null)
    if [[ "${#ovpn_files[@]}" -gt 0 ]]; then
      printf 'openvpn\n'
      return 0
    fi
  fi

  if [[ -d "$wg_dir" ]]; then
    local wg_files
    mapfile -t wg_files < <(find "$wg_dir" -maxdepth 1 -type f -name '*.conf' 2>/dev/null)
    for wg_conf in "${wg_files[@]}"; do
      if grep -q '^[[:space:]]*\[Interface\]' "$wg_conf" 2>/dev/null; then
        printf 'wireguard\n'
        return 0
      fi
    done
  fi

  printf 'Unable to detect VPN type: set VPN_TYPE or place config files\n' >&2
  return 1
}

# Get the source directory for the given VPN type.
# openvpn  → OPENVPN_SOURCE_DIR or ./config/openvpn
# wireguard → WIREGUARD_SOURCE_DIR or ./config/wireguard
vpn_source_dir() {
  local vpn_type="${1:-$(detect_vpn_type)}"
  case "$vpn_type" in
    openvpn)   printf '%s\n' "${OPENVPN_SOURCE_DIR:-./config/openvpn}" ;;
    wireguard) printf '%s\n' "${WIREGUARD_SOURCE_DIR:-./config/wireguard}" ;;
    *)
      printf 'Unknown VPN type: %s\n' "$vpn_type" >&2
      return 1
      ;;
  esac
}

# -----------------------------------------------------------------------------
# OpenVPN functions (preserved unchanged from openvpn-ddns-lib.sh)
# -----------------------------------------------------------------------------

default_source_dir() {
  printf '%s\n' "${OPENVPN_SOURCE_DIR:-./config/openvpn}"
}

detect_source_config() {
  if [[ -n "${OPENVPN_SOURCE_CONFIG:-}" ]]; then
    if [[ -f "$OPENVPN_SOURCE_CONFIG" ]]; then
      printf '%s\n' "$OPENVPN_SOURCE_CONFIG"
      return 0
    fi

    local source_dir candidate
    source_dir="$(default_source_dir)"
    candidate="$source_dir/$(basename "$OPENVPN_SOURCE_CONFIG")"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi

    printf 'Configured OPENVPN_SOURCE_CONFIG was not found: %s\n' "$OPENVPN_SOURCE_CONFIG" >&2
    return 1
  fi

  local source_dir
  source_dir="$(default_source_dir)"
  mapfile -t ovpn_files < <(find "$source_dir" -maxdepth 1 -type f -name '*.ovpn' | sort)

  if [[ "${#ovpn_files[@]}" -ne 1 ]]; then
    printf 'Expected exactly one .ovpn file in %s, found %s\n' "$source_dir" "${#ovpn_files[@]}" >&2
    return 1
  fi

  printf '%s\n' "${ovpn_files[0]}"
}

get_primary_remote_line() {
  local config_file="$1"
  grep -E '^[[:space:]]*remote[[:space:]]+' "$config_file" | head -1
}

get_remote_host() {
  local config_file="$1"
  local remote_line
  remote_line="$(get_primary_remote_line "$config_file")"
  awk '{print $2}' <<<"$remote_line"
}

resolve_ipv4() {
  local hostname="$1"

  if [[ -n "${DDNS_OVERRIDE_IP:-}" ]]; then
    printf '%s\n' "$DDNS_OVERRIDE_IP"
    return 0
  fi

  if [[ -n "${DDNS_RESOLVER:-}" ]] && command -v drill >/dev/null 2>&1; then
    local drilled
    drilled="$(drill A "$hostname" @"$DDNS_RESOLVER" 2>/dev/null | awk '/^[^;].*[[:space:]]+A[[:space:]]+/ {print $5; exit}')"
    if [[ -n "$drilled" ]]; then
      printf '%s\n' "$drilled"
      return 0
    fi
  fi

  if command -v getent >/dev/null 2>&1; then
    local got
    got="$(getent ahostsv4 "$hostname" | awk 'NR==1 {print $1}')"
    if [[ -n "$got" ]]; then
      printf '%s\n' "$got"
      return 0
    fi
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$hostname" <<'PY'
import socket
import sys

hostname = sys.argv[1]
infos = socket.getaddrinfo(hostname, None, socket.AF_INET, socket.SOCK_DGRAM)
seen = []
for info in infos:
    ip = info[4][0]
    if ip not in seen:
        seen.append(ip)
if not seen:
    raise SystemExit(1)
print(seen[0])
PY
    return 0
  fi

  printf 'Unable to resolve %s: need DDNS_OVERRIDE_IP, getent, drill, or python3\n' "$hostname" >&2
  return 1
}

render_openvpn_config() {
  local source_config="$1"
  local output_config="$2"
  local resolved_ip="$3"
  local original_host="$4"
  local source_config_dir

  source_config_dir="$(dirname "$source_config")"

  mkdir -p "$(dirname "$output_config")"

  awk -v host="$original_host" -v ip="$resolved_ip" -v source_dir="$source_config_dir" '
    function absolutize_path(path_value) {
      if (path_value == "" || path_value == "stdin") {
        return path_value
      }
      if (path_value ~ /^\//) {
        return path_value
      }
      return source_dir "/" path_value
    }

    /^[[:space:]]*remote[[:space:]]+/ {
      if ($2 == host) {
        $2 = ip
      }
    }

    /^[[:space:]]*(ca|cert|key|tls-auth|tls-crypt|auth-user-pass)[[:space:]]+/ {
      if ($2 != "") {
        $2 = absolutize_path($2)
      }
    }

    { print }
  ' "$source_config" > "$output_config"
}

# -----------------------------------------------------------------------------
# WireGuard functions
# -----------------------------------------------------------------------------

# Auto-detect the WireGuard source config.
# Priority: VPN_SOURCE_CONFIG env var → exactly one .conf with [Interface] in dir.
detect_wg_source_config() {
  local explicit_config="${WIREGUARD_SOURCE_CONFIG:-${VPN_SOURCE_CONFIG:-}}"
  if [[ -n "$explicit_config" ]]; then
    if [[ -f "$explicit_config" ]]; then
      printf '%s\n' "$explicit_config"
      return 0
    fi

    local source_dir candidate
    source_dir="$(vpn_source_dir wireguard)"
    candidate="$source_dir/$(basename "$explicit_config")"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi

    printf 'Configured WIREGUARD_SOURCE_CONFIG was not found: %s\n' "$explicit_config" >&2
    return 1
  fi

  local source_dir
  source_dir="$(vpn_source_dir wireguard)"
  mapfile -t wg_files < <(find "$source_dir" -maxdepth 1 -type f -name '*.conf' -exec grep -l '^[[:space:]]*\[Interface\]' {} \; | sort)

  if [[ "${#wg_files[@]}" -ne 1 ]]; then
    printf 'Expected exactly one WireGuard .conf file with [Interface] in %s, found %s\n' "$source_dir" "${#wg_files[@]}" >&2
    return 1
  fi

  printf '%s\n' "${wg_files[0]}"
}

# Extract the hostname from a WireGuard Endpoint line.
# Input: config file path
# Returns: hostname part of "Endpoint = hostname:port"
get_wg_endpoint_host() {
  local config_file="$1"
  grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$config_file" \
    | head -1 \
    | sed -E 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//; s/:[0-9]+$//'
}

# Extract the port from a WireGuard Endpoint line.
# Input: config file path
# Returns: port part of "Endpoint = hostname:port"
get_wg_endpoint_port() {
  local config_file="$1"
  grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$config_file" \
    | head -1 \
    | sed -E 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*[^:]*://'
}

# Render a WireGuard config with the resolved IP in the Endpoint line.
# Format: "Endpoint = hostname:port" → "Endpoint = ip:port"
# No path normalization needed (WireGuard uses inlined keys, not file refs).
render_wireguard_config() {
  local source_config="$1"
  local output_config="$2"
  local resolved_ip="$3"
  local original_host="$4"

  mkdir -p "$(dirname "$output_config")"

  awk -v host="$original_host" -v ip="$resolved_ip" '
    /^[[:space:]]*Endpoint[[:space:]]*=/ {
      line = $0
      sub(/#.*$/, "", line)
      sub(/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*/, "", line)
      colon = index(line, ":")
      if (colon > 0) {
        extracted_host = substr(line, 1, colon - 1)
        if (extracted_host == host) {
          sub(host, ip, $0)
        }
      }
    }
    { print }
  ' "$source_config" > "$output_config"
}

# -----------------------------------------------------------------------------
# Dispatch layer — unified interface for protocol-agnostic consumers
# -----------------------------------------------------------------------------

# Detect source config for the active VPN type.
# Uses VPN_TYPE env var (set by sourcing script) or auto-detects.
vpn_detect_source_config() {
  local vpn_type="${VPN_TYPE:-$(detect_vpn_type)}"
  case "$vpn_type" in
    openvpn)   detect_source_config ;;
    wireguard) detect_wg_source_config ;;
    *)
      printf 'Unknown VPN type: %s\n' "$vpn_type" >&2
      return 1
      ;;
  esac
}

# Get the remote host from the source config.
# Dispatches to OpenVPN or WireGuard implementation based on VPN_TYPE.
vpn_get_remote_host() {
  local config_file="$1"
  local vpn_type="${VPN_TYPE:-$(detect_vpn_type)}"
  case "$vpn_type" in
    openvpn)   get_remote_host "$config_file" ;;
    wireguard) get_wg_endpoint_host "$config_file" ;;
    *)
      printf 'Unknown VPN type: %s\n' "$vpn_type" >&2
      return 1
      ;;
  esac
}

# Render the runtime config with resolved IP.
# Dispatches to OpenVPN or WireGuard implementation based on VPN_TYPE.
vpn_render_config() {
  local source_config="$1"
  local output_config="$2"
  local resolved_ip="$3"
  local original_host="$4"
  local vpn_type="${VPN_TYPE:-$(detect_vpn_type)}"
  case "$vpn_type" in
    openvpn)   render_openvpn_config "$source_config" "$output_config" "$resolved_ip" "$original_host" ;;
    wireguard) render_wireguard_config "$source_config" "$output_config" "$resolved_ip" "$original_host" ;;
    *)
      printf 'Unknown VPN type: %s\n' "$vpn_type" >&2
      return 1
      ;;
  esac
}

# -----------------------------------------------------------------------------
# State management (protocol-agnostic)
# -----------------------------------------------------------------------------

write_last_ip() {
  local state_dir="${STATE_DIR:-./state}"
  mkdir -p "$state_dir/ddns"
  printf '%s\n' "$1" > "$state_dir/ddns/last-ip"
}

read_last_ip() {
  local state_dir="${STATE_DIR:-./state}"
  local path="$state_dir/ddns/last-ip"
  [[ -f "$path" ]] || return 1
  cat "$path"
}
