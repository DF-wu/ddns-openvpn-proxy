#!/bin/sh
# shellcheck disable=SC2016 # $vpn/$backend/$vpn_type inside single quotes are jq variables
set -eu

# Validate the rendered Compose model of the stack selected by VPN_TYPE against
# the contract in docs/spec.md. Usage: scripts/validate-compose.sh [ENV_FILE]
# Without an argument the repository .env is used, or .env.example when no
# .env exists. Requires docker compose and jq.

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [ -n "${1:-}" ]; then
  env_file=$1
  [ -f "$env_file" ] || fail "Compose environment file not found: $env_file"
  label=$env_file
elif [ -f "$repo_root/.env" ]; then
  env_file=$repo_root/.env
  label=".env"
else
  env_file=$repo_root/.env.example
  label=".env.example"
fi

# Last assignment wins, surrounding quotes are stripped; the process
# environment takes precedence exactly like Compose interpolation.
env_value() {
  awk -F= -v key="$1" '
    /^[[:space:]]*#/ { next }
    $1 == key { value = substr($0, length(key) + 2) }
    END { print value }
  ' "$env_file" | sed "s/^[\"']//; s/[\"']\$//"
}

vpn_type=${VPN_TYPE:-$(env_value VPN_TYPE)}
vpn_type=${vpn_type:-openvpn}
case $vpn_type in
  openvpn|wireguard)
    backend=gluetun
    stack_file=docker-compose.yml
    vpn_service=gluetun
    expected_services='["ddns-init","ddns-watcher","docker-socket-proxy","gluetun","vproxy"]'
    ;;
  openconnect)
    backend=openconnect
    stack_file=docker-compose.openconnect.yml
    vpn_service=openconnect
    expected_services='["ddns-init","ddns-watcher","docker-socket-proxy","openconnect"]'
    ;;
  singbox)
    backend=singbox
    stack_file=docker-compose.singbox.yml
    vpn_service=singbox
    expected_services='["ddns-init","ddns-watcher","docker-socket-proxy","singbox"]'
    ;;
  *)
    fail "VPN_TYPE must be openvpn, wireguard, openconnect, or singbox, got: $vpn_type"
    ;;
esac

compose_file=${COMPOSE_FILE:-$(env_value COMPOSE_FILE)}
if [ -n "$compose_file" ] && [ "$compose_file" != "$stack_file" ]; then
  fail "COMPOSE_FILE=$compose_file does not serve VPN_TYPE=$vpn_type; expected $stack_file"
fi

rendered=$temporary_dir/compose.json
docker compose --env-file "$env_file" -f "$repo_root/$stack_file" \
  config --format json > "$rendered"

assert_jq() {
  expression=$1
  description=$2
  if ! jq -e --arg vpn "$vpn_service" --arg backend "$backend" --arg vpn_type "$vpn_type" \
      "$expression" "$rendered" >/dev/null; then
    fail "Compose invariant failed ($stack_file): $description"
  fi
}

# --- Topology --------------------------------------------------------------

assert_jq 'all(.services[]; has("build") | not)' 'no service may build an image'
assert_jq "[.services | keys[]] == $expected_services" \
  "the $backend backend topology must contain exactly the expected services"
assert_jq '.services."ddns-init".image == .services."ddns-watcher".image' \
  'init and watcher must use the same stock helper image'
assert_jq 'all([.services."ddns-init", .services."ddns-watcher"][];
           .entrypoint == ["/bin/sh", "/opt/ddns/ddns-vpn.sh"] and
           any(.volumes[]; .target == "/opt/ddns" and .read_only == true and (.source | endswith("/scripts"))))' \
  'helper services must run the mounted read-only ddns-vpn script tree'
assert_jq 'all([.services."ddns-init", .services."ddns-watcher"][];
           .environment.VPN_BACKEND == $backend and .environment.VPN_TYPE == $vpn_type)' \
  'helper services must declare the backend and VPN type of this stack'
assert_jq 'all([.services."ddns-init", .services."ddns-watcher"][];
           .environment.VPN_RENDERED_CONFIG == "/state/runtime/vpn.conf" and
           .environment.VPN_RENDERED_ENV == "/state/runtime/vpn.env" and
           any(.volumes[]; .target == "/state" and .source == "vpn-state" and (.read_only // false) == false))' \
  'helper services must render into the shared vpn-state volume'
assert_jq 'any(.services[$vpn].volumes[]; .target == "/state" and .source == "vpn-state" and .read_only == true)' \
  'the VPN service must read the runtime profile from a read-only vpn-state mount'
assert_jq 'all([.services."ddns-init", .services."ddns-watcher", .services[$vpn]][];
           any(.volumes[]; .target == "/source" and .read_only == true)) and
           ([.services."ddns-init", .services."ddns-watcher", .services[$vpn]]
             | map(.volumes[] | select(.target == "/source") | .source)
             | unique | length == 1) and
           .services."ddns-init".environment.VPN_SOURCE_CONFIG ==
             .services."ddns-watcher".environment.VPN_SOURCE_CONFIG and
           (.services."ddns-init".environment.VPN_SOURCE_CONFIG | startswith("/source/"))' \
  'init, watcher, and the VPN service must share the read-only source profile mount'
assert_jq '.services[$vpn].depends_on."ddns-init".condition == "service_completed_successfully"' \
  'the VPN service must wait for successful initial rendering'
assert_jq '.services."ddns-watcher".depends_on[$vpn] != null and
           .services."ddns-watcher".depends_on."docker-socket-proxy".condition == "service_healthy"' \
  'watcher must start after the VPN service and a healthy Docker API proxy'
assert_jq '.services."ddns-watcher".environment.DOCKER_HOST == "tcp://docker-socket-proxy:2375" and
           (.services."ddns-watcher".networks | has("docker-api"))' \
  'watcher must reach Docker only through the restricted API proxy network'
assert_jq '.services."ddns-watcher".environment.VPN_CONTAINER_NAME == .services[$vpn].container_name and
           .services."ddns-init".environment.VPN_CONTAINER_NAME == .services[$vpn].container_name' \
  'helper restart target must be the VPN service container name'
assert_jq '(.services."ddns-watcher".environment.VPN_HEALTH_PROBE // "" |
             startswith("http://") or startswith("tcp://"))' \
  'watcher must have an http:// or tcp:// readiness probe for the VPN service'
assert_jq '(.services[$vpn].ports | length == 2) and
           all(.services[$vpn].ports[]; .protocol == "tcp" and (.host_ip | length > 0))' \
  'the VPN service must publish exactly the HTTP and SOCKS5 TCP ports on an explicit bind address'

# --- Docker API boundary -----------------------------------------------------

assert_jq '.networks."docker-api".internal == true' \
  'Docker API network must be internal'
assert_jq '[.services | to_entries[] | select(any(.value.volumes[]?; .source == "/var/run/docker.sock")) | .key] == ["docker-socket-proxy"]' \
  'only docker-socket-proxy may mount the host Docker socket'
assert_jq '.services."docker-socket-proxy".command[0:2] == ["/bin/sh", "-ec"] and
           (.services."docker-socket-proxy".command[2] |
             contains("/usr/local/etc/haproxy/restart-only.cfg.tmpl") and
             contains("@RESTART_RULES@") and
             contains("RESTART_TARGETS")) and
           any(.services."docker-socket-proxy".volumes[];
             .target == "/usr/local/etc/haproxy/restart-only.cfg.tmpl" and
             .read_only == true) and
           (.services."docker-socket-proxy".environment | has("CONTAINERS") | not) and
           (.services."docker-socket-proxy".environment | has("POST") | not) and
           (.services."docker-socket-proxy".environment | has("ALLOW_RESTARTS") | not)' \
  'Docker API proxy must render the read-only restart-only HAProxy policy from RESTART_TARGETS'
assert_jq '(.services."docker-socket-proxy".environment.RESTART_TARGETS | split(" ")) ==
           ([.services[$vpn].container_name] +
            (if .services.vproxy then [.services.vproxy.container_name] else [] end))' \
  'Docker API proxy restart targets must be exactly the VPN container and its sidecar'

# --- Hardening ---------------------------------------------------------------

assert_jq 'all(.services | to_entries[] | select(.key != $vpn); .value.cap_drop == ["ALL"])' \
  'all non-VPN services must drop Linux capabilities'
assert_jq '.services."ddns-init".cap_add == ["DAC_READ_SEARCH"] and
           .services."ddns-watcher".cap_add == ["DAC_READ_SEARCH"] and
           .services."docker-socket-proxy".cap_add == ["DAC_READ_SEARCH"] and
           ((.services.vproxy // {}) | has("cap_add") | not)' \
  'bind-mount readers may only add DAC_READ_SEARCH for restrictive host file modes'
assert_jq 'all(.services[]; .security_opt == ["no-new-privileges:true"])' \
  'all services must set no-new-privileges'
assert_jq 'all([.services."ddns-init", .services."ddns-watcher", .services."docker-socket-proxy"][];
           .read_only == true)' \
  'helper and socket proxy services must use a read-only root filesystem'
assert_jq 'all(.services[];
           .logging.driver == "json-file" and
           (.logging.options."max-size" | length > 0) and
           (.logging.options."max-file" | length > 0))' \
  'all services must rotate json-file logs'
assert_jq 'all([.services."ddns-init", .services."ddns-watcher"][];
           (.environment | keys | map(select(test("PASSWORD$|PRIVATE_KEY$|PRESHARED_KEY$|TOTP_SECRET$|^OPENVPN_USER$|^HTTPPROXY_USER$|^SOCKS5_USER$|^OPENCONNECT_USER$"))) == []))' \
  'helper services must receive only credential-presence flags, never secrets'
assert_jq 'all(.services[]; (.image | contains("ddns-openvpn-proxy-watcher") | not))' \
  'the removed project-specific watcher image must not return'

images=$(jq -r '.services[].image' "$rendered" | sort -u)
for image in $images; do
  case $image in
    *:latest|*:edge|*:master|*:main)
      fail "Image must use an immutable version tag or digest, not a moving tag: $image"
      ;;
  esac
done

if find "$repo_root" -path "$repo_root/.git" -prune -o -name Dockerfile -print | grep -q .; then
  fail 'This repository is Compose-only; Dockerfiles are not allowed.'
fi

# --- Backend contracts -------------------------------------------------------

validate_gluetun() {
  assert_jq '.services.gluetun.cap_add == ["NET_ADMIN"] and
             any(.services.gluetun.devices[]; (if type == "string" then . else .source end) == "/dev/net/tun")' \
    'Gluetun is the only service with NET_ADMIN and the TUN device'
  assert_jq '.services.gluetun.environment.VPN_SERVICE_PROVIDER == "custom" and
             .services.gluetun.environment.VPN_TYPE == $vpn_type and
             .services.vproxy.environment.VPN_TYPE == $vpn_type' \
    'Gluetun and vproxy must use the custom provider with the selected VPN type'
  assert_jq '.services.gluetun.environment.OPENVPN_CUSTOM_CONFIG == "/state/runtime/vpn.conf" and
             .services.gluetun.environment.WIREGUARD_CONF_SECRETFILE == "/state/runtime/vpn.conf"' \
    'both Gluetun protocols must consume the atomically rendered runtime profile'
  assert_jq '(.services.gluetun.environment | has("WIREGUARD_PRIVATE_KEY") | not) and
             (.services.gluetun.environment | has("WIREGUARD_PRESHARED_KEY") | not)' \
    'WireGuard keys must come from the runtime secret file, not environment variables'
  assert_jq '.services.vproxy.network_mode == "service:gluetun" and
             .services.vproxy.container_name ==
               .services."ddns-watcher".environment.SIDECAR_CONTAINER_NAME and
             .services."ddns-watcher".environment.SIDECAR_HEALTH_PROBE == "tcp://gluetun:1080"' \
    'vproxy must share the Gluetun namespace and be the helper sidecar restart target'
  assert_jq '.services.gluetun.environment.HEALTH_SERVER_ADDRESS == ":9999" and
             .services."ddns-watcher".environment.VPN_HEALTH_PROBE == "http://gluetun:9999" and
             (.services.gluetun.environment.FIREWALL_INPUT_PORTS | split(",") |
               (index("1080") != null and index("9999") != null))' \
    'Gluetun firewall must admit the SOCKS5 listener and the internal health server'
  # shellcheck disable=SC2016 # Compose preserves the escaped container-shell variable.
  assert_jq '(.services.vproxy.healthcheck.test[1] |
               contains("127.0.0.1:9999") and
               contains("/sys/class/net/") and
               contains("ip -4 route get") and
               contains("dev $${interface}"))' \
    'vproxy healthcheck must verify Gluetun health, the VPN interface, and VPN route'
  assert_jq '[.services.gluetun.ports[].target] | sort == [1080, 8888]' \
    'Gluetun must publish the HTTP proxy (8888) and the vproxy SOCKS5 listener (1080)'

  wireguard_allowed_ips=$(jq -r '.services.gluetun.environment.WIREGUARD_ALLOWED_IPS // ""' "$rendered")
  wireguard_mtu=$(jq -r '.services.gluetun.environment.WIREGUARD_MTU // ""' "$rendered")
  wireguard_implementation=$(jq -r '.services.gluetun.environment.WIREGUARD_IMPLEMENTATION // ""' "$rendered")
  [ -n "$wireguard_allowed_ips" ] || fail 'WIREGUARD_ALLOWED_IPS must not be empty.'
  case $wireguard_mtu in
    ''|*[!0-9]*) fail 'WIREGUARD_MTU must be an integer.' ;;
  esac
  awk -v mtu="$wireguard_mtu" 'BEGIN { exit !(mtu >= 576 && mtu <= 65535) }' ||
    fail 'WIREGUARD_MTU must be between 576 and 65535.'
  case $wireguard_implementation in
    auto|userspace|kernelspace) ;;
    *) fail 'WIREGUARD_IMPLEMENTATION must be auto, userspace, or kernelspace.' ;;
  esac

  http_user=$(jq -r '.services.gluetun.environment.HTTPPROXY_USER // ""' "$rendered")
  http_password=$(jq -r '.services.gluetun.environment.HTTPPROXY_PASSWORD // ""' "$rendered")
  socks_user=$(jq -r '.services.vproxy.environment.SOCKS5_USER // ""' "$rendered")
  socks_password=$(jq -r '.services.vproxy.environment.SOCKS5_PASSWORD // ""' "$rendered")
  http_enabled=$(jq -r '.services.gluetun.environment.HTTPPROXY // "off"' "$rendered")
  require_pair OPENVPN_USER OPENVPN_PASSWORD \
    "$(jq -r '.services.gluetun.environment.OPENVPN_USER // ""' "$rendered")" \
    "$(jq -r '.services.gluetun.environment.OPENVPN_PASSWORD // ""' "$rendered")"
}

validate_openconnect() {
  assert_jq '.services.openconnect.cap_add == ["NET_ADMIN"] and
             any(.services.openconnect.devices[]; (if type == "string" then . else .source end) == "/dev/net/tun") and
             ((.services.openconnect.privileged // false) == false)' \
    'OpenConnect needs NET_ADMIN and the TUN device but must not be privileged'
  assert_jq '.services.openconnect.environment.TUNNEL_GATE == "1" and
             .services.openconnect.environment.TUNNEL_GATE_INTERFACE == "tun0" and
             .services.openconnect.environment.PROXY_PORT == "8888" and
             .services.openconnect.environment.SOCKS_PORT == "8889" and
             .services.openconnect.environment.MAX_RECONNECT_ATTEMPTS == "0"' \
    'OpenConnect must gate its proxy ports on tunnel state and reconnect indefinitely'
  assert_jq '(.services.openconnect.command[0] |
               contains(". /state/runtime/vpn.env") and
               contains("--config=/state/runtime/vpn.conf") and
               contains("exec /usr/local/bin/fix-dns /entrypoint.sh"))' \
    'OpenConnect must start from the rendered runtime profile and gateway URL'
  assert_jq '(.services.openconnect.healthcheck.test[1] |
               contains("tun0") and contains("ip -4 route get") and
               contains(":8888") and contains(":8889"))' \
    'OpenConnect healthcheck must verify the tunnel interface, route, and both listeners'
  assert_jq '[.services.openconnect.ports[].target] | sort == [8888, 8889]' \
    'OpenConnect must publish tinyproxy (8888) and microsocks (8889)'
  assert_jq '.services."ddns-watcher".environment.VPN_HEALTH_PROBE == "tcp://openconnect:8888" and
             ((.services."ddns-watcher".environment.SIDECAR_CONTAINER_NAME // "") == "")' \
    'OpenConnect readiness is the gated HTTP listener and there is no sidecar'
  assert_jq '(.services."ddns-init".environment.OPENCONNECT_SERVER // "" | length > 0)' \
    'OPENCONNECT_SERVER must be set to the gateway hostname'
  assert_jq '(.services."ddns-init".environment.OPENCONNECT_PORT // "" | test("^[0-9]+$"))' \
    'OPENCONNECT_PORT must be numeric'
  require_pair OPENCONNECT_USER OPENCONNECT_PASSWORD \
    "$(jq -r '.services.openconnect.environment.OPENCONNECT_USER // ""' "$rendered")" \
    "$(jq -r '.services.openconnect.environment.OPENCONNECT_PASSWORD // ""' "$rendered")"
  http_user=
  http_password=
  socks_user=
  socks_password=
  http_enabled=on
}

validate_singbox() {
  assert_jq '.services.singbox.cap_drop == ["ALL"] and
             (.services.singbox | has("cap_add") | not) and
             (.services.singbox | has("devices") | not) and
             .services.singbox.read_only == true and
             any(.services.singbox.tmpfs[]; startswith("/run/sing-box"))' \
    'sing-box runs in proxy-only mode: no capabilities, no TUN, read-only root'
  assert_jq '(.services.singbox.command[0] |
               contains("00-managed.json") and
               contains("10-profile.json") and
               contains("cp /state/runtime/vpn.conf") and
               contains("sing-box check -C") and
               contains("\"final\": \"vpn\"") and
               contains("\"detour\": \"vpn\"") and
               contains("exec sing-box -D"))' \
    'sing-box must validate the merged managed+rendered configuration before running'
  assert_jq '.services.singbox.healthcheck.test == ["CMD", "/bin/sh", "/run/sing-box/healthcheck.sh"]' \
    'sing-box healthcheck must exercise the proxy data path'
  assert_jq '[.services.singbox.ports[].target] | sort == [1080, 8888]' \
    'sing-box must publish the HTTP (8888) and SOCKS5 (1080) mixed inbounds'
  assert_jq '(.services."ddns-watcher".environment.VPN_HEALTH_PROBE | contains("/proxies/vpn/delay")) and
             ((.services."ddns-watcher".environment.SIDECAR_CONTAINER_NAME // "") == "")' \
    'sing-box readiness is a Clash API URL test through the vpn outbound and there is no sidecar'
  http_user=$(jq -r '.services.singbox.environment.HTTPPROXY_USER // ""' "$rendered")
  http_password=$(jq -r '.services.singbox.environment.HTTPPROXY_PASSWORD // ""' "$rendered")
  socks_user=$(jq -r '.services.singbox.environment.SOCKS5_USER // ""' "$rendered")
  socks_password=$(jq -r '.services.singbox.environment.SOCKS5_PASSWORD // ""' "$rendered")
  http_enabled=$(jq -r '.services.singbox.environment.HTTPPROXY // "off"' "$rendered")
}

require_pair() {
  user_name=$1
  password_name=$2
  user_value=$3
  password_value=$4
  if { [ -n "$user_value" ] && [ -z "$password_value" ]; } ||
     { [ -z "$user_value" ] && [ -n "$password_value" ]; }; then
    fail "$user_name and $password_name must both be set or both be empty."
  fi
}

"validate_$backend"

require_pair HTTPPROXY_USER HTTPPROXY_PASSWORD "$http_user" "$http_password"
require_pair SOCKS5_USER SOCKS5_PASSWORD "$socks_user" "$socks_password"

public_bind=$(jq -r --arg vpn "$vpn_service" '
  [.services[$vpn].ports[]?.host_ip]
  | map(select(. != "127.0.0.1" and . != "::1"))
  | length > 0
' "$rendered")

if [ "$public_bind" = true ]; then
  case $backend in
    openconnect)
      fail 'The openconnect backend has no proxy authentication; PROXY_BIND_ADDRESS must stay 127.0.0.1.'
      ;;
  esac
  if [ "$http_enabled" = on ] && { [ -z "$http_user" ] || [ -z "$http_password" ]; }; then
    fail 'HTTP proxy credentials are required when PROXY_BIND_ADDRESS is not loopback.'
  fi
  if [ -z "$socks_user" ] || [ -z "$socks_password" ]; then
    fail 'SOCKS5 credentials are required when PROXY_BIND_ADDRESS is not loopback.'
  fi
fi

printf 'Compose validation passed for %s backend (%s) using %s.\n' "$backend" "$stack_file" "$label"
