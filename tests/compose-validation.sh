#!/bin/sh
set -eu

# Negative and positive cases for scripts/validate-compose.sh across every
# backend stack. Each case starts from .env.example and appends overrides.

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT HUP INT TERM

case_number=0

make_env() {
  env_file=$workdir/case-$case_number.env
  cp "$repo_root/.env.example" "$env_file"
  # Drop keys that a case overrides so the override is unambiguous.
  for assignment in "$@"; do
    key=${assignment%%=*}
    sed -i "/^$key=/d" "$env_file"
  done
  printf '%s\n' "$@" >> "$env_file"
  printf '%s\n' "$env_file"
}

expect_failure() {
  description=$1
  shift
  case_number=$((case_number + 1))
  env_file=$(make_env "$@")
  if "$repo_root/scripts/validate-compose.sh" "$env_file" >/dev/null 2>&1; then
    printf 'not ok %s - %s\n' "$case_number" "$description" >&2
    exit 1
  fi
  printf 'ok %s - %s\n' "$case_number" "$description"
}

expect_success() {
  description=$1
  shift
  case_number=$((case_number + 1))
  env_file=$(make_env "$@")
  if ! "$repo_root/scripts/validate-compose.sh" "$env_file" >/dev/null; then
    printf 'not ok %s - %s\n' "$case_number" "$description" >&2
    exit 1
  fi
  printf 'ok %s - %s\n' "$case_number" "$description"
}

render_json() {
  stack=$1
  env_file=$2
  docker compose --env-file "$env_file" -f "$repo_root/$stack" config --format json
}

printf 'TAP version 13\n'

# --- Gluetun backend ------------------------------------------------------------

expect_failure 'public bind without proxy credentials is rejected' \
  'PROXY_BIND_ADDRESS=0.0.0.0'
expect_failure 'partial HTTP credentials are rejected' \
  'HTTPPROXY_USER=only-user'
expect_failure 'partial SOCKS5 credentials are rejected' \
  'SOCKS5_PASSWORD=only-password'
expect_failure 'partial OpenVPN credentials are rejected' \
  'OPENVPN_USER=only-user'
expect_failure 'moving image tags are rejected' \
  'GLUETUN_IMAGE=qmcgaw/gluetun:latest'
expect_failure 'unknown VPN type is rejected' \
  'VPN_TYPE=ipsec'
expect_failure 'out-of-range WireGuard MTU is rejected' \
  'WIREGUARD_MTU=500'
expect_failure 'unknown WireGuard implementation is rejected' \
  'WIREGUARD_IMPLEMENTATION=magic'
expect_failure 'COMPOSE_FILE that does not serve VPN_TYPE is rejected' \
  'VPN_TYPE=openvpn' 'COMPOSE_FILE=docker-compose.openconnect.yml'

expect_success 'authenticated public bind is accepted' \
  'PROXY_BIND_ADDRESS=0.0.0.0' \
  'HTTPPROXY_USER=http-user' 'HTTPPROXY_PASSWORD=http-password' \
  'SOCKS5_USER=socks-user' 'SOCKS5_PASSWORD=socks-password'
expect_success 'WireGuard Compose mode is accepted' \
  'VPN_TYPE=wireguard' 'VPN_CONFIG_DIR=./config/wireguard' 'VPN_CONFIG_FILE=wg0.conf'

case_number=$((case_number + 1))
legacy_env=$(make_env 'OPENVPN_CONFIG_DIR=./legacy-openvpn' 'OPENVPN_CONFIG_FILE=legacy.ovpn' \
  'GLUETUN_CONTAINER_NAME=legacy-gluetun')
sed -i '/^VPN_CONFIG_DIR=/d; /^VPN_CONFIG_FILE=/d; /^VPN_CONTAINER_NAME=/d' "$legacy_env"
"$repo_root/scripts/validate-compose.sh" "$legacy_env" >/dev/null
if ! render_json docker-compose.yml "$legacy_env" | jq -e '
  .services."ddns-init".environment.VPN_SOURCE_CONFIG == "/source/legacy.ovpn" and
  any(.services."ddns-init".volumes[];
    .target == "/source" and (.source | endswith("/legacy-openvpn"))) and
  .services.gluetun.container_name == "legacy-gluetun" and
  .services."ddns-watcher".environment.VPN_CONTAINER_NAME == "legacy-gluetun" and
  (.services."docker-socket-proxy".environment.RESTART_TARGETS | startswith("legacy-gluetun "))
' >/dev/null; then
  printf 'not ok %s - legacy OPENVPN_CONFIG_*/GLUETUN_CONTAINER_NAME aliases remain compatible\n' \
    "$case_number" >&2
  exit 1
fi
printf 'ok %s - legacy OPENVPN_CONFIG_*/GLUETUN_CONTAINER_NAME aliases remain compatible\n' "$case_number"

case_number=$((case_number + 1))
stale_env=$(make_env 'HTTPPROXY_STEALTH=off')
"$repo_root/scripts/validate-compose.sh" "$stale_env" >/dev/null 2>"$workdir/stale.err"
if ! { grep -q 'HTTPPROXY_STEALTH .* is ignored' "$workdir/stale.err" &&
       render_json docker-compose.yml "$stale_env" | jq -e '
         .services.gluetun.environment.HTTPPROXY_STEALTH == "on" and
         .services.gluetun.environment.BLOCK_MALICIOUS == "off" and
         .services.gluetun.environment.PUBLICIP_ENABLED == "off" and
         .services.vproxy.environment.VPROXY_LOG == "warn"
       ' >/dev/null; }; then
  printf 'not ok %s - Gluetun stays transparent and quiet even with a stale HTTPPROXY_STEALTH=off\n' \
    "$case_number" >&2
  exit 1
fi
printf 'ok %s - Gluetun stays transparent and quiet even with a stale HTTPPROXY_STEALTH=off\n' "$case_number"

# --- OpenConnect backend --------------------------------------------------------

openconnect_base='VPN_TYPE=openconnect VPN_CONFIG_DIR=./config/openconnect VPN_CONFIG_FILE=client.conf COMPOSE_FILE=docker-compose.openconnect.yml OPENCONNECT_SERVER=vpn.example.com OPENCONNECT_USER=alice OPENCONNECT_PASSWORD=secret'

# shellcheck disable=SC2086 # deliberate word splitting of KEY=VALUE tokens
expect_success 'OpenConnect loopback stack is accepted' $openconnect_base
# shellcheck disable=SC2086
expect_failure 'OpenConnect without OPENCONNECT_SERVER is rejected' $openconnect_base \
  'OPENCONNECT_SERVER='
# shellcheck disable=SC2086
expect_failure 'OpenConnect partial credentials are rejected' $openconnect_base \
  'OPENCONNECT_PASSWORD='
# shellcheck disable=SC2086
expect_failure 'OpenConnect public bind is rejected even with proxy credentials' $openconnect_base \
  'PROXY_BIND_ADDRESS=0.0.0.0' \
  'HTTPPROXY_USER=http-user' 'HTTPPROXY_PASSWORD=http-password' \
  'SOCKS5_USER=socks-user' 'SOCKS5_PASSWORD=socks-password'
# shellcheck disable=SC2086
expect_failure 'OpenConnect stack with a Gluetun VPN_TYPE is rejected' $openconnect_base \
  'VPN_TYPE=openvpn'

# --- sing-box backend -----------------------------------------------------------

singbox_base='VPN_TYPE=singbox VPN_CONFIG_DIR=./config/sing-box VPN_CONFIG_FILE=config.json COMPOSE_FILE=docker-compose.singbox.yml'

# shellcheck disable=SC2086
expect_success 'sing-box loopback stack is accepted' $singbox_base
# shellcheck disable=SC2086
expect_success 'sing-box authenticated public bind is accepted' $singbox_base \
  'PROXY_BIND_ADDRESS=0.0.0.0' \
  'HTTPPROXY_USER=http-user' 'HTTPPROXY_PASSWORD=http-password' \
  'SOCKS5_USER=socks-user' 'SOCKS5_PASSWORD=socks-password'
# shellcheck disable=SC2086
expect_failure 'sing-box public bind without credentials is rejected' $singbox_base \
  'PROXY_BIND_ADDRESS=0.0.0.0'
# shellcheck disable=SC2086
expect_failure 'sing-box moving image tag is rejected' $singbox_base \
  'SINGBOX_IMAGE=ghcr.io/sagernet/sing-box:latest'

case_number=$((case_number + 1))
# shellcheck disable=SC2086
singbox_env=$(make_env $singbox_base 'VPN_CONTAINER_NAME=custom-singbox')
if ! render_json docker-compose.singbox.yml "$singbox_env" | jq -e '
  .services.singbox.container_name == "custom-singbox" and
  .services."docker-socket-proxy".environment.RESTART_TARGETS == "custom-singbox" and
  (.services."ddns-watcher".environment | has("SIDECAR_CONTAINER_NAME") | not)
' >/dev/null; then
  printf 'not ok %s - single-container backends expose exactly one restart target\n' "$case_number" >&2
  exit 1
fi
printf 'ok %s - single-container backends expose exactly one restart target\n' "$case_number"

case_number=$((case_number + 1))
# shellcheck disable=SC2086
singbox_env=$(make_env $singbox_base)
if ! render_json docker-compose.singbox.yml "$singbox_env" |
    jq -e '.services.singbox.environment.SINGBOX_LOG_LEVEL == "warn"' >/dev/null; then
  printf 'not ok %s - sing-box does not log proxied destinations by default\n' "$case_number" >&2
  exit 1
fi
printf 'ok %s - sing-box does not log proxied destinations by default\n' "$case_number"

printf '1..%s\n' "$case_number"
