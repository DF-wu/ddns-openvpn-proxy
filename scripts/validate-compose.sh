#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

if [ -n "${1:-}" ]; then
  env_file=$1
  [ -f "$env_file" ] || {
    printf 'ERROR: Compose environment file not found: %s\n' "$env_file" >&2
    exit 1
  }
  label=$env_file
elif [ -f "$repo_root/.env" ]; then
  env_file=$repo_root/.env
  label=".env"
else
  env_file=$repo_root/.env.example
  label=".env.example"
fi

rendered=$temporary_dir/compose.json
docker compose --env-file "$env_file" -f "$repo_root/docker-compose.yml" \
  config --format json > "$rendered"

assert_jq() {
  expression=$1
  description=$2
  if ! jq -e "$expression" "$rendered" >/dev/null; then
    printf 'ERROR: Compose invariant failed: %s\n' "$description" >&2
    exit 1
  fi
}

assert_jq 'all(.services[]; has("build") | not)' 'no service may build an image'
assert_jq '[.services | keys[]] == ["ddns-init","ddns-watcher","docker-socket-proxy","gluetun","vproxy"]' \
  'the five-service production topology must be present'
assert_jq '.services."ddns-init".image == .services."ddns-watcher".image' \
  'init and watcher must use the same stock helper image'
assert_jq '.services."ddns-init".environment.VPN_TYPE == .services.gluetun.environment.VPN_TYPE and
           .services."ddns-watcher".environment.VPN_TYPE == .services.gluetun.environment.VPN_TYPE' \
  'init, watcher, and Gluetun must use the same VPN type'
assert_jq '.services."ddns-init".environment.VPN_RENDERED_CONFIG == "/state/runtime/vpn.conf" and
           .services."ddns-watcher".environment.VPN_RENDERED_CONFIG == "/state/runtime/vpn.conf" and
           .services.gluetun.environment.OPENVPN_CUSTOM_CONFIG == "/state/runtime/vpn.conf" and
           .services.gluetun.environment.WIREGUARD_CONF_SECRETFILE == "/state/runtime/vpn.conf"' \
  'both VPN protocols must consume the atomically rendered runtime profile'
assert_jq 'all([.services."ddns-init", .services."ddns-watcher", .services.gluetun][];
           any(.volumes[]; .target == "/source" and .read_only == true)) and
           ([.services."ddns-init", .services."ddns-watcher", .services.gluetun]
             | map(.volumes[] | select(.target == "/source") | .source)
             | unique | length == 1) and
           .services."ddns-init".environment.VPN_SOURCE_CONFIG ==
             .services."ddns-watcher".environment.VPN_SOURCE_CONFIG and
           (.services."ddns-init".environment.VPN_SOURCE_CONFIG | startswith("/source/"))' \
  'init, watcher, and Gluetun must share the read-only source profile mount'
assert_jq '.services.gluetun.depends_on."ddns-init".condition == "service_completed_successfully"' \
  'Gluetun must wait for successful initial rendering'
assert_jq '.services.vproxy.network_mode == "service:gluetun"' \
  'vproxy must share Gluetun network namespace'
assert_jq '.services.vproxy.container_name ==
             .services."ddns-watcher".environment.VPROXY_CONTAINER_NAME and
           .services.vproxy.environment.VPN_TYPE == .services.gluetun.environment.VPN_TYPE' \
  'watcher target and VPN type must match vproxy'
assert_jq '.services.gluetun.environment.HEALTH_SERVER_ADDRESS == ":9999" and
           (.services.gluetun.environment.FIREWALL_INPUT_PORTS | split(",") |
             (index("1080") != null and index("9999") != null))' \
  'Gluetun firewall must admit the SOCKS5 listener and internal health server'
# shellcheck disable=SC2016 # Compose preserves the escaped container-shell variable.
assert_jq '(.services.vproxy.healthcheck.test[1] |
             contains("127.0.0.1:9999") and
             contains("/sys/class/net/") and
             contains("ip -4 route get") and
             contains("dev $${interface}"))' \
  'vproxy healthcheck must verify Gluetun health, the VPN interface, and VPN route'
assert_jq '.services."ddns-watcher".depends_on.vproxy.condition == "service_healthy"' \
  'watcher must start only after the initial vproxy namespace is healthy'
assert_jq '.services."ddns-watcher".environment.DOCKER_HOST == "tcp://docker-socket-proxy:2375"' \
  'watcher must use the restricted Docker API proxy'
assert_jq '.services."docker-socket-proxy".environment.GLUETUN_CONTAINER_NAME ==
             .services.gluetun.container_name and
           .services."docker-socket-proxy".environment.VPROXY_CONTAINER_NAME ==
             .services.vproxy.container_name and
           .services."ddns-watcher".environment.GLUETUN_CONTAINER_NAME ==
             .services.gluetun.container_name' \
  'Docker API proxy must restrict restart to the configured Gluetun and vproxy containers'
assert_jq 'all([.services."ddns-init", .services."ddns-watcher"][];
           (.environment | has("OPENVPN_USER") | not) and
           (.environment | has("OPENVPN_PASSWORD") | not) and
           (.environment | has("HTTPPROXY_USER") | not) and
           (.environment | has("HTTPPROXY_PASSWORD") | not) and
           (.environment | has("SOCKS5_USER") | not) and
           (.environment | has("SOCKS5_PASSWORD") | not) and
           (.environment | has("WIREGUARD_PRIVATE_KEY") | not) and
           (.environment | has("WIREGUARD_PRESHARED_KEY") | not))' \
  'helper services must receive only credential-presence flags, never secrets'
assert_jq '(.services.gluetun.environment | has("WIREGUARD_PRIVATE_KEY") | not) and
           (.services.gluetun.environment | has("WIREGUARD_PRESHARED_KEY") | not)' \
  'WireGuard keys must come from the runtime secret file, not environment variables'
assert_jq '.networks."docker-api".internal == true' \
  'Docker API network must be internal'
assert_jq '[.services | to_entries[] | select(any(.value.volumes[]?; .source == "/var/run/docker.sock")) | .key] == ["docker-socket-proxy"]' \
  'only docker-socket-proxy may mount the host Docker socket'
assert_jq '.services."docker-socket-proxy".command[0:2] == ["/bin/sh", "-ec"] and
           (.services."docker-socket-proxy".command[2] |
             contains("/usr/local/etc/haproxy/restart-only.cfg.tmpl")) and
           any(.services."docker-socket-proxy".volumes[];
             .target == "/usr/local/etc/haproxy/restart-only.cfg.tmpl" and
             .read_only == true) and
           (.services."docker-socket-proxy".command[2] |
             contains("@GLUETUN_CONTAINER_NAME@") and
             contains("@VPROXY_CONTAINER_NAME@")) and
           (.services."docker-socket-proxy".environment | has("CONTAINERS") | not) and
           (.services."docker-socket-proxy".environment | has("POST") | not) and
           (.services."docker-socket-proxy".environment | has("ALLOW_RESTARTS") | not)' \
  'Docker API proxy must load the read-only restart-only HAProxy policy'
assert_jq 'all(.services | to_entries[] | select(.key != "gluetun"); .value.cap_drop == ["ALL"])' \
  'all non-VPN services must drop Linux capabilities'
assert_jq '.services."ddns-init".cap_add == ["DAC_READ_SEARCH"] and
           .services."ddns-watcher".cap_add == ["DAC_READ_SEARCH"] and
           (.services.vproxy | has("cap_add") | not) and
           .services."docker-socket-proxy".cap_add == ["DAC_READ_SEARCH"]' \
  'bind-mount readers may only add DAC_READ_SEARCH for restrictive host file modes'
assert_jq 'all(.services[]; .security_opt == ["no-new-privileges:true"])' \
  'all services must set no-new-privileges'
assert_jq 'all(.services[];
           .logging.driver == "json-file" and
           (.logging.options."max-size" | length > 0) and
           (.logging.options."max-file" | length > 0))' \
  'all services must rotate json-file logs'
assert_jq 'all(.services[]; (.image | contains("ddns-openvpn-proxy-watcher") | not))' \
  'the removed project-specific watcher image must not return'

images=$(jq -r '.services[].image' "$rendered" | sort -u)
for image in $images; do
  case $image in
    *:latest|*:edge|*:master|*:main)
      printf 'ERROR: Image must use an immutable version tag or digest, not a moving tag: %s\n' "$image" >&2
      exit 1
      ;;
  esac
done

http_user=$(jq -r '.services.gluetun.environment.HTTPPROXY_USER // ""' "$rendered")
http_password=$(jq -r '.services.gluetun.environment.HTTPPROXY_PASSWORD // ""' "$rendered")
socks_user=$(jq -r '.services.vproxy.environment.SOCKS5_USER // ""' "$rendered")
socks_password=$(jq -r '.services.vproxy.environment.SOCKS5_PASSWORD // ""' "$rendered")
openvpn_user=$(jq -r '.services.gluetun.environment.OPENVPN_USER // ""' "$rendered")
openvpn_password=$(jq -r '.services.gluetun.environment.OPENVPN_PASSWORD // ""' "$rendered")
vpn_type=$(jq -r '.services.gluetun.environment.VPN_TYPE // ""' "$rendered")
wireguard_allowed_ips=$(jq -r '.services.gluetun.environment.WIREGUARD_ALLOWED_IPS // ""' "$rendered")
wireguard_mtu=$(jq -r '.services.gluetun.environment.WIREGUARD_MTU // ""' "$rendered")
wireguard_implementation=$(jq -r '.services.gluetun.environment.WIREGUARD_IMPLEMENTATION // ""' "$rendered")

case $vpn_type in
  openvpn|wireguard) ;;
  *)
    printf 'ERROR: VPN_TYPE must be openvpn or wireguard, got: %s\n' "$vpn_type" >&2
    exit 1
    ;;
esac

[ -n "$wireguard_allowed_ips" ] || {
  printf 'ERROR: WIREGUARD_ALLOWED_IPS must not be empty.\n' >&2
  exit 1
}

case $wireguard_mtu in
  ''|*[!0-9]*)
    printf 'ERROR: WIREGUARD_MTU must be an integer.\n' >&2
    exit 1
    ;;
esac
if ! awk -v mtu="$wireguard_mtu" 'BEGIN { exit !(mtu >= 576 && mtu <= 65535) }'; then
  printf 'ERROR: WIREGUARD_MTU must be between 576 and 65535.\n' >&2
  exit 1
fi

case $wireguard_implementation in
  auto|userspace|kernelspace) ;;
  *)
    printf 'ERROR: WIREGUARD_IMPLEMENTATION must be auto, userspace, or kernelspace.\n' >&2
    exit 1
    ;;
esac

if { [ -n "$openvpn_user" ] && [ -z "$openvpn_password" ]; } ||
   { [ -z "$openvpn_user" ] && [ -n "$openvpn_password" ]; }; then
  printf 'ERROR: OPENVPN_USER and OPENVPN_PASSWORD must both be set or both be empty.\n' >&2
  exit 1
fi

if { [ -n "$http_user" ] && [ -z "$http_password" ]; } ||
   { [ -z "$http_user" ] && [ -n "$http_password" ]; }; then
  printf 'ERROR: HTTPPROXY_USER and HTTPPROXY_PASSWORD must both be set or both be empty.\n' >&2
  exit 1
fi

if { [ -n "$socks_user" ] && [ -z "$socks_password" ]; } ||
   { [ -z "$socks_user" ] && [ -n "$socks_password" ]; }; then
  printf 'ERROR: SOCKS5_USER and SOCKS5_PASSWORD must both be set or both be empty.\n' >&2
  exit 1
fi

public_bind=$(jq -r '
  [.services.gluetun.ports[]?.host_ip]
  | map(select(. != "127.0.0.1" and . != "::1"))
  | length > 0
' "$rendered")
http_enabled=$(jq -r '.services.gluetun.environment.HTTPPROXY // "off"' "$rendered")

if [ "$public_bind" = true ]; then
  if [ "$http_enabled" = on ] && { [ -z "$http_user" ] || [ -z "$http_password" ]; }; then
    printf 'ERROR: HTTP proxy credentials are required when PROXY_BIND_ADDRESS is not loopback.\n' >&2
    exit 1
  fi
  if [ -z "$socks_user" ] || [ -z "$socks_password" ]; then
    printf 'ERROR: SOCKS5 credentials are required when PROXY_BIND_ADDRESS is not loopback.\n' >&2
    exit 1
  fi
fi

if find "$repo_root" -path "$repo_root/.git" -prune -o -name Dockerfile -print | grep -q .; then
  printf 'ERROR: This repository is Compose-only; Dockerfiles are not allowed.\n' >&2
  exit 1
fi

printf 'Compose validation passed using %s.\n' "$label"
