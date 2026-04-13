#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

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
