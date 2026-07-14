#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

if [[ -f "$repo_root/.env" ]]; then
  compose_env="$repo_root/.env"
  validation_label="using $repo_root/.env"
else
  mkdir -p "$temp_dir/config/openvpn" "$temp_dir/config/wireguard" "$temp_dir/state/openvpn" "$temp_dir/state/wireguard"
  cp "$repo_root/examples/openvpn/custom.ovpn" "$temp_dir/config/openvpn/client.ovpn"
  cp "$repo_root/examples/wireguard/wg0.conf" "$temp_dir/config/wireguard/wg0.conf"

  cat >"$temp_dir/.env" <<EOF
TZ=UTC
OPENVPN_CONFIG_DIR=$temp_dir/config
OPENVPN_SOURCE_CONFIG=$temp_dir/config/openvpn/client.ovpn
WIREGUARD_CONFIG_DIR=$temp_dir/config
WIREGUARD_SOURCE_CONFIG=$temp_dir/config/wireguard/wg0.conf
STATE_DIR=$temp_dir/state
DDNS_HOSTNAME=vpn.example.com
DDNS_POLL_SECONDS=60
DDNS_COOLDOWN_SECONDS=15
DDNS_RESOLVER=
DDNS_OVERRIDE_IP=203.0.113.10
HTTP_PROXY_PORT=8888
SOCKS5_PROXY_PORT=1080
SOCKS5_USER=
SOCKS5_PASSWORD=
VPROXY_IMAGE=ghcr.io/0x676e67/vproxy:latest
GLUETUN_CONTAINER_NAME=ddns-openvpn-proxy
WATCHER_IMAGE=ghcr.io/df-wu/ddns-openvpn-proxy-watcher:latest
GLUETUN_IMAGE=qmcgaw/gluetun:latest
VPN_TYPE=openvpn
EOF

  compose_env="$temp_dir/.env"
  validation_label="using generated example inputs"
fi

rendered_compose="$temp_dir/rendered-compose.yml"
docker compose \
  --env-file "$compose_env" \
  -f "$repo_root/docker-compose.yml" \
  config >"$rendered_compose"

assert_rendered_contains() {
  local expected="$1"
  local description="$2"

  if ! grep -Fq -- "$expected" "$rendered_compose"; then
    printf 'ERROR: Rendered Compose config is missing %s.\n' "$description" >&2
    printf 'Expected to find: %s\n' "$expected" >&2
    exit 1
  fi
}

# These assertions protect the cross-container SOCKS5 contract. A plain
# `docker compose config -q` only checks YAML syntax and did not catch a scalar
# command being split before vproxy was invoked.
assert_rendered_contains 'network_mode: service:gluetun' 'the shared Gluetun network namespace'
assert_rendered_contains 'FIREWALL_INPUT_PORTS: "1080"' 'the Gluetun firewall allowance for SOCKS5'
assert_rendered_contains 'SOCKS5_USER:' 'the SOCKS5 username environment variable'
assert_rendered_contains 'SOCKS5_PASSWORD:' 'the SOCKS5 password environment variable'
assert_rendered_contains 'exec vproxy run --bind 0.0.0.0:1080 socks5' 'the vproxy startup command'
assert_rendered_contains 'SOCKS5_USER and SOCKS5_PASSWORD must both be set or both be empty' 'partial-auth rejection'

rendered_environment_value() {
  local variable_name="$1"
  local line value

  line="$(grep -E "^[[:space:]]+${variable_name}:" "$rendered_compose" | head -1 || true)"
  value="${line#*:}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

rendered_value_is_empty() {
  case "$1" in
    ''|'""'|"''"|'null'|'~') return 0 ;;
    *) return 1 ;;
  esac
}

socks5_user_value="$(rendered_environment_value SOCKS5_USER)"
socks5_password_value="$(rendered_environment_value SOCKS5_PASSWORD)"

if rendered_value_is_empty "$socks5_user_value"; then
  socks5_user_is_empty=1
else
  socks5_user_is_empty=0
fi

if rendered_value_is_empty "$socks5_password_value"; then
  socks5_password_is_empty=1
else
  socks5_password_is_empty=0
fi

if [[ "$socks5_user_is_empty" -ne "$socks5_password_is_empty" ]]; then
  printf 'ERROR: SOCKS5_USER and SOCKS5_PASSWORD must both be set or both be empty.\n' >&2
  exit 1
fi

printf 'Docker Compose validation passed %s.\n' "$validation_label"
