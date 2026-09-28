#!/bin/sh
set -eu

# Real container contract for every backend stack. Creates isolated temporary
# Compose projects, never touches the operator's .env or state, and cleans up
# with a trap. Needs a Docker daemon, Compose v2, jq, curl, and /dev/net/tun
# for the OpenConnect runtime checks. No real VPN server is used: sing-box is
# exercised end to end against a local sing-box server, OpenConnect against a
# closed port, Gluetun against Alpine stand-ins for the restart-only API.

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
suffix=$$
project=ddns-contract-$suffix
source_dir=$(mktemp -d)
state_dir=$(mktemp -d)

gluetun_target=ddns-contract-gluetun-$suffix
vproxy_target=ddns-contract-vproxy-$suffix
other_target=ddns-contract-denied-$suffix
openconnect_target=ddns-contract-openconnect-$suffix
singbox_target=ddns-contract-singbox-$suffix
ss_server=ddns-contract-ss-server-$suffix
http_target=ddns-contract-http-target-$suffix
http_port=$((20000 + suffix % 20000))
socks_port=$((http_port + 1))

# Keep Compose progress spinners out of the test transcript.
export COMPOSE_PROGRESS=quiet

step() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

compose() {
  stack=$1
  shift
  docker compose -f "$repo_root/$stack" -p "$project" "$@"
}

cleanup() {
  # Fixture containers first: an attached non-Compose container would keep
  # the project network alive when `down` tries to remove it.
  for container in "$gluetun_target" "$vproxy_target" "$other_target" \
      "$openconnect_target" "$singbox_target" "$ss_server" "$http_target"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  for stack in docker-compose.yml docker-compose.openconnect.yml docker-compose.singbox.yml; do
    docker compose -f "$repo_root/$stack" -p "$project" \
      down --remove-orphans --volumes >/dev/null 2>&1 || true
  done
  rm -rf "$source_dir" "$state_dir"
}
trap cleanup EXIT HUP INT TERM

# --- Fixtures -----------------------------------------------------------------

cp "$repo_root/examples/openvpn/custom.ovpn" "$source_dir/custom.ovpn"
cat > "$source_dir/wg0.conf" <<'EOF'
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = vpn.example.test:51820
AllowedIPs = 0.0.0.0/0
EOF
cat > "$source_dir/client.conf" <<'EOF'
protocol=anyconnect
no-dtls
EOF
cat > "$source_dir/config.json" <<'EOF'
{
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "vpn",
      "server": "vpn.example.test",
      "server_port": 8388,
      "method": "aes-128-gcm",
      "password": "contract-test"
    }
  ]
}
EOF
cat > "$source_dir/ss-server.json" <<'EOF'
{
  "log": { "level": "warn" },
  "inbounds": [
    { "type": "shadowsocks", "tag": "ss-in", "listen": "0.0.0.0", "listen_port": 8388,
      "method": "aes-128-gcm", "password": "contract-test" }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
chmod 600 "$source_dir"/*

# Common environment for every stack. Process environment wins over .env.
export VPN_CONFIG_DIR="$source_dir"
export PROXY_BIND_ADDRESS=127.0.0.1
export HTTP_PROXY_PORT="$http_port"
export SOCKS5_PROXY_PORT="$socks_port"

# =============================================================================
step "Gluetun backend: helper image, rendering, and the restart-only Docker API"
# =============================================================================

export VPN_TYPE=openvpn
export VPN_CONFIG_FILE=custom.ovpn
export DDNS_OVERRIDE_IPS=198.51.100.10
export VPN_CONTAINER_NAME="$gluetun_target"
export VPROXY_CONTAINER_NAME="$vproxy_target"

compose docker-compose.yml up -d --wait --wait-timeout 60 docker-socket-proxy >/dev/null
compose docker-compose.yml run --rm --no-deps --entrypoint /bin/sh ddns-watcher -ec \
  'command -v wget >/dev/null && command -v nc >/dev/null' >/dev/null
compose docker-compose.yml run --rm --no-deps ddns-init validate >/dev/null
compose docker-compose.yml run --rm --no-deps ddns-init init >/dev/null

export VPN_TYPE=wireguard
export VPN_CONFIG_FILE=wg0.conf
export DDNS_OVERRIDE_IPS=198.51.100.20
compose docker-compose.yml run --rm --no-deps ddns-init validate >/dev/null
compose docker-compose.yml run --rm --no-deps ddns-init init >/dev/null
# shellcheck disable=SC2016 # command substitution belongs to the container shell
compose docker-compose.yml run --rm --no-deps --entrypoint /bin/sh ddns-init -ec \
  'grep -Fq "Endpoint = 198.51.100.20:51820" /state/runtime/vpn.conf &&
   test "$(stat -c %a /state/runtime/vpn.conf)" = 600' >/dev/null

docker run -d --name "$gluetun_target" alpine:3.22 sleep 300 >/dev/null
docker run -d --name "$other_target" alpine:3.22 sleep 300 >/dev/null

vproxy_image=$(compose docker-compose.yml config --format json | jq -r '.services.vproxy.image')
docker run -d --name "$vproxy_target" \
  --network "container:$gluetun_target" \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=8m,mode=1777 \
  --entrypoint /bin/sh "$vproxy_image" -ec \
  'exec /bin/vproxy run --bind 0.0.0.0:1080 socks5' >/dev/null

restarted=$(compose docker-compose.yml run --rm --no-deps --entrypoint docker ddns-watcher \
  container restart --timeout 2 -- "$gluetun_target")
[ "$restarted" = "$gluetun_target" ] || fail 'restricted Docker API did not restart the Gluetun target'
restarted=$(compose docker-compose.yml run --rm --no-deps --entrypoint docker ddns-watcher \
  container restart --timeout 2 -- "$vproxy_target")
[ "$restarted" = "$vproxy_target" ] || fail 'restricted Docker API did not restart the vproxy target'

gluetun_netns=$(docker exec "$gluetun_target" readlink /proc/self/ns/net)
vproxy_netns=$(docker exec "$vproxy_target" readlink /proc/self/ns/net)
[ "$gluetun_netns" = "$vproxy_netns" ] || fail 'restarted vproxy did not rejoin the Gluetun network namespace'

assert_docker_denied() {
  stack=$1
  operation=$2
  shift 2
  if compose "$stack" run --rm --no-deps --entrypoint docker ddns-watcher "$@" >/dev/null 2>&1; then
    fail "restricted Docker API unexpectedly allowed container $operation"
  fi
}

assert_docker_denied docker-compose.yml inspect container inspect "$gluetun_target"
assert_docker_denied docker-compose.yml vproxy-inspect container inspect "$vproxy_target"
assert_docker_denied docker-compose.yml other-restart container restart --timeout 2 -- "$other_target"
assert_docker_denied docker-compose.yml stop container stop "$gluetun_target"
assert_docker_denied docker-compose.yml vproxy-stop container stop "$vproxy_target"
assert_docker_denied docker-compose.yml kill container kill "$gluetun_target"
assert_docker_denied docker-compose.yml pause container pause "$gluetun_target"
assert_docker_denied docker-compose.yml remove container rm --force "$gluetun_target"

attempt=1
while ! docker exec "$vproxy_target" nc -z 127.0.0.1 1080; do
  [ "$attempt" -lt 10 ] || fail 'hardened vproxy listener did not become ready'
  attempt=$((attempt + 1))
  sleep 1
done
docker exec "$vproxy_target" /bin/sh -ec \
  'command -v wget >/dev/null && command -v ip >/dev/null && command -v grep >/dev/null'

compose docker-compose.yml down --remove-orphans --volumes >/dev/null 2>&1
docker rm -f "$gluetun_target" "$vproxy_target" "$other_target" >/dev/null 2>&1
printf 'Gluetun backend contract passed.\n'

# =============================================================================
step "OpenConnect backend: rendering, non-privileged runtime, tunnel gate, restart-only API"
# =============================================================================

export VPN_TYPE=openconnect
export VPN_CONFIG_FILE=client.conf
export OPENCONNECT_SERVER=vpn.example.test
export OPENCONNECT_PORT=1
export OPENCONNECT_USER=contract
export OPENCONNECT_PASSWORD=contract
export OPENCONNECT_RECONNECT_DELAY=5
# 127.0.0.1:1 refuses immediately inside the container; OpenConnect must still
# try exactly that address because of the rendered resolve= line.
export DDNS_OVERRIDE_IPS=127.0.0.1
export VPN_CONTAINER_NAME="$openconnect_target"
unset VPROXY_CONTAINER_NAME

compose docker-compose.openconnect.yml run --rm --no-deps ddns-init validate >/dev/null
compose docker-compose.openconnect.yml run --rm --no-deps ddns-init init >/dev/null
compose docker-compose.openconnect.yml run --rm --no-deps --entrypoint /bin/sh ddns-init -ec \
  'grep -Fq "resolve=vpn.example.test:127.0.0.1" /state/runtime/vpn.conf &&
   grep -Fq "non-inter" /state/runtime/vpn.conf &&
   grep -Fq "DDNS_VPN_URL='"'"'https://vpn.example.test:1'"'"'" /state/runtime/vpn.env' >/dev/null

if [ -c /dev/net/tun ]; then
  compose docker-compose.openconnect.yml up -d --wait --wait-timeout 60 docker-socket-proxy >/dev/null
  compose docker-compose.openconnect.yml up -d openconnect >/dev/null
  attempt=1
  until docker logs "$openconnect_target" 2>&1 | grep -q 'Failed to connect to 127.0.0.1:1'; do
    [ "$attempt" -lt 30 ] || {
      docker logs "$openconnect_target" 2>&1 | tail -20 >&2
      fail 'OpenConnect did not attempt the resolved address from the rendered profile'
    }
    attempt=$((attempt + 1))
    sleep 1
  done
  docker logs "$openconnect_target" 2>&1 | grep -q 'ddns-vpn: connecting to https://vpn.example.test:1 via 127.0.0.1' ||
    fail 'OpenConnect wrapper did not source the rendered vpn.env'
  [ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$openconnect_target")" = false ] ||
    fail 'OpenConnect container must not run privileged'
  docker exec "$openconnect_target" iptables -S OPENCONNECT_PROXY_GATE 2>/dev/null |
    grep -q 'REJECT' || fail 'tunnel gate REJECT rule is not installed while the tunnel is down'
  if docker exec "$openconnect_target" nc -z -w 2 127.0.0.1 8888; then
    fail 'gated HTTP proxy port accepted a connection while the tunnel is down'
  fi
  if compose docker-compose.openconnect.yml run --rm --no-deps --entrypoint nc ddns-watcher \
      -z -w 2 openconnect 8888 >/dev/null 2>&1; then
    fail 'watcher readiness probe must fail while the OpenConnect tunnel is down'
  fi
  restarted=$(compose docker-compose.openconnect.yml run --rm --no-deps --entrypoint docker ddns-watcher \
    container restart --timeout 2 -- "$openconnect_target")
  [ "$restarted" = "$openconnect_target" ] || fail 'restricted Docker API did not restart the OpenConnect target'
  assert_docker_denied docker-compose.openconnect.yml inspect container inspect "$openconnect_target"
  assert_docker_denied docker-compose.openconnect.yml stop container stop "$openconnect_target"
  printf 'OpenConnect backend contract passed.\n'
else
  printf 'OpenConnect runtime checks skipped: /dev/net/tun is not available on this host.\n'
fi
compose docker-compose.openconnect.yml down --remove-orphans --volumes >/dev/null 2>&1

# =============================================================================
step "sing-box backend: end-to-end data path through a local Shadowsocks server"
# =============================================================================

export VPN_TYPE=singbox
export VPN_CONFIG_FILE=config.json
export VPN_CONTAINER_NAME="$singbox_target"
export HTTPPROXY_USER=http-user
export HTTPPROXY_PASSWORD=http-password
export SOCKS5_USER=socks-user
export SOCKS5_PASSWORD=socks-password
unset OPENCONNECT_SERVER OPENCONNECT_PORT OPENCONNECT_USER OPENCONNECT_PASSWORD OPENCONNECT_RECONNECT_DELAY

# A throwaway helper run creates the project default network; the local
# Shadowsocks server and an HTTP target join it so the sing-box service can
# reach them exactly like a remote VPN server.
compose docker-compose.singbox.yml up -d --wait --wait-timeout 60 docker-socket-proxy >/dev/null
compose docker-compose.singbox.yml run --rm --no-deps --entrypoint true ddns-watcher >/dev/null
project_network=$(docker network ls --format '{{.Name}}' | grep "^${project}_default$" || true)
[ -n "$project_network" ] || fail 'Compose default network for the sing-box stack was not created'

singbox_image=$(compose docker-compose.singbox.yml config --format json | jq -r '.services.singbox.image')
docker run -d --name "$ss_server" --network "$project_network" \
  -v "$source_dir/ss-server.json:/etc/sing-box/config.json:ro" \
  "$singbox_image" run -c /etc/sing-box/config.json >/dev/null
docker run -d --name "$http_target" --network "$project_network" alpine:3.22 sh -c '
  while true; do
    printf "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" | nc -l -p 8080
  done' >/dev/null

ss_server_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$project_network\").IPAddress}}" "$ss_server")
http_target_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$project_network\").IPAddress}}" "$http_target")
[ -n "$ss_server_ip" ] && [ -n "$http_target_ip" ] || fail 'could not determine fixture container addresses'

export DDNS_OVERRIDE_IPS="$ss_server_ip"
export SINGBOX_HEALTH_URL="http://$http_target_ip:8080/"
export SINGBOX_HEALTH_PROBE="http://singbox:9090/proxies/vpn/delay?timeout=5000&url=http%3A%2F%2F$http_target_ip%3A8080%2F"

compose docker-compose.singbox.yml run --rm --no-deps ddns-init validate >/dev/null
# --wait blocks until the healthcheck fetched SINGBOX_HEALTH_URL through the
# authenticated mixed inbound, the shadowsocks outbound, and the fixture server.
if ! compose docker-compose.singbox.yml up -d --wait --wait-timeout 90 singbox >/dev/null 2>&1; then
  docker logs "$singbox_target" 2>&1 | tail -30 >&2
  fail 'sing-box service did not become healthy through the local Shadowsocks path'
fi
compose docker-compose.singbox.yml run --rm --no-deps --entrypoint /bin/sh ddns-init -ec \
  "grep -Fq '\"server\": \"$ss_server_ip\"' /state/runtime/vpn.conf" >/dev/null

[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapAdd}} {{.HostConfig.Privileged}}' "$singbox_target")" = 'true [] false' ] ||
  fail 'sing-box container must be read-only, without added capabilities, and unprivileged'

status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -x "http://127.0.0.1:$http_port" "http://$http_target_ip:8080/" || true)
[ "$status" = 407 ] || fail "unauthenticated HTTP proxy request must be rejected with 407, got $status"
status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -x "http://127.0.0.1:$http_port" -U http-user:http-password "http://$http_target_ip:8080/" || true)
[ "$status" = 204 ] || fail "authenticated HTTP proxy request through sing-box failed, got $status"
status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  --socks5-hostname "127.0.0.1:$socks_port" -U socks-user:socks-password "http://$http_target_ip:8080/" || true)
[ "$status" = 204 ] || fail "authenticated SOCKS5 request through sing-box failed, got $status"
if curl -s -o /dev/null --max-time 10 --socks5-hostname "127.0.0.1:$socks_port" -U socks-user:wrong \
    "http://$http_target_ip:8080/"; then
  fail 'SOCKS5 request with a wrong password must be rejected'
fi

compose docker-compose.singbox.yml run --rm --no-deps --entrypoint wget ddns-watcher \
  -q --spider -T 8 "$SINGBOX_HEALTH_PROBE" >/dev/null ||
  fail 'watcher readiness probe (Clash API delay through the vpn outbound) failed'

restarted=$(compose docker-compose.singbox.yml run --rm --no-deps --entrypoint docker ddns-watcher \
  container restart --timeout 2 -- "$singbox_target")
[ "$restarted" = "$singbox_target" ] || fail 'restricted Docker API did not restart the sing-box target'
assert_docker_denied docker-compose.singbox.yml inspect container inspect "$singbox_target"
assert_docker_denied docker-compose.singbox.yml stop container stop "$singbox_target"

attempt=1
until compose docker-compose.singbox.yml run --rm --no-deps --entrypoint wget ddns-watcher \
    -q --spider -T 8 "$SINGBOX_HEALTH_PROBE" >/dev/null 2>&1; do
  [ "$attempt" -lt 20 ] || fail 'sing-box data path did not recover after a restricted restart'
  attempt=$((attempt + 1))
  sleep 2
done
printf 'sing-box backend contract passed.\n'

printf '\nContainer contract test passed for the gluetun, openconnect, and singbox backends.\n'
