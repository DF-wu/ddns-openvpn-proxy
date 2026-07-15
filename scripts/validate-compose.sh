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
assert_jq '.services.gluetun.depends_on."ddns-init".condition == "service_completed_successfully"' \
  'Gluetun must wait for successful initial rendering'
assert_jq '.services.vproxy.network_mode == "service:gluetun"' \
  'vproxy must share Gluetun network namespace'
assert_jq '.services.gluetun.environment.FIREWALL_INPUT_PORTS == "1080"' \
  'Gluetun firewall must admit the SOCKS5 listener'
assert_jq '.services."ddns-watcher".environment.DOCKER_HOST == "tcp://docker-socket-proxy:2375"' \
  'watcher must use the restricted Docker API proxy'
assert_jq '.services."docker-socket-proxy".environment.RESTART_CONTAINER_NAME ==
           .services.gluetun.container_name' \
  'Docker API proxy must restrict restart to the configured Gluetun container'
assert_jq 'all([.services."ddns-init", .services."ddns-watcher"][];
           (.environment | has("OPENVPN_USER") | not) and
           (.environment | has("OPENVPN_PASSWORD") | not) and
           (.environment | has("HTTPPROXY_USER") | not) and
           (.environment | has("HTTPPROXY_PASSWORD") | not) and
           (.environment | has("SOCKS5_USER") | not) and
           (.environment | has("SOCKS5_PASSWORD") | not))' \
  'helper services must receive only credential-presence flags, never secrets'
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
           (.services."docker-socket-proxy".environment | has("CONTAINERS") | not) and
           (.services."docker-socket-proxy".environment | has("POST") | not) and
           (.services."docker-socket-proxy".environment | has("ALLOW_RESTARTS") | not)' \
  'Docker API proxy must load the read-only restart-only HAProxy policy'
assert_jq 'all(.services | to_entries[] | select(.key != "gluetun"); .value.cap_drop == ["ALL"])' \
  'all non-VPN services must drop Linux capabilities'
assert_jq '.services."ddns-init".cap_add == ["DAC_READ_SEARCH"] and
           .services."ddns-watcher".cap_add == ["DAC_READ_SEARCH"] and
           (.services.vproxy | has("cap_add") | not) and
           (.services."docker-socket-proxy" | has("cap_add") | not)' \
  'only helper services may add DAC_READ_SEARCH for read-only 0600 source files'
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
