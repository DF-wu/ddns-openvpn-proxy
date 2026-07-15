#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
project=ddns-openvpn-contract-$$
target=ddns-openvpn-restart-test-$$
other_target=ddns-openvpn-denied-test-$$
proxy_target=ddns-openvpn-vproxy-test-$$
source_dir=$(mktemp -d)

cleanup() {
  docker compose -f "$repo_root/docker-compose.yml" -p "$project" \
    down --remove-orphans --volumes >/dev/null 2>&1 || true
  docker rm -f "$target" >/dev/null 2>&1 || true
  docker rm -f "$other_target" >/dev/null 2>&1 || true
  docker rm -f "$proxy_target" >/dev/null 2>&1 || true
  rm -rf "$source_dir"
}
trap cleanup EXIT HUP INT TERM

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
chmod 600 "$source_dir/custom.ovpn" "$source_dir/wg0.conf"

export VPN_TYPE=openvpn
export VPN_CONFIG_DIR="$source_dir"
export VPN_CONFIG_FILE=custom.ovpn
export DDNS_OVERRIDE_IPS=198.51.100.10
export GLUETUN_CONTAINER_NAME="$target"
export VPROXY_CONTAINER_NAME="$proxy_target"

compose() {
  docker compose -f "$repo_root/docker-compose.yml" -p "$project" "$@"
}

compose up -d --wait --wait-timeout 60 docker-socket-proxy >/dev/null
compose run --rm --no-deps --entrypoint /bin/sh ddns-watcher -ec \
  'command -v wget >/dev/null && command -v nc >/dev/null' >/dev/null
compose run --rm --no-deps ddns-init validate >/dev/null
compose run --rm --no-deps ddns-init init >/dev/null

export VPN_TYPE=wireguard
export VPN_CONFIG_FILE=wg0.conf
export DDNS_OVERRIDE_IPS=198.51.100.20
compose run --rm --no-deps ddns-init validate >/dev/null
compose run --rm --no-deps ddns-init init >/dev/null
# shellcheck disable=SC2016 # command substitution belongs to the container shell
compose run --rm --no-deps --entrypoint /bin/sh ddns-init -ec \
  'grep -Fq "Endpoint = 198.51.100.20:51820" /state/runtime/vpn.conf &&
   test "$(stat -c %a /state/runtime/vpn.conf)" = 600' >/dev/null

docker run -d --name "$target" alpine:3.22 sleep 300 >/dev/null
docker run -d --name "$other_target" alpine:3.22 sleep 300 >/dev/null

vproxy_image=$(compose config --format json | jq -r '.services.vproxy.image')
docker run -d --name "$proxy_target" \
  --network "container:$target" \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=8m,mode=1777 \
  --entrypoint /bin/sh "$vproxy_image" -ec \
  'exec /bin/vproxy run --bind 0.0.0.0:1080 socks5' >/dev/null

restarted=$(compose run --rm --no-deps --entrypoint docker ddns-watcher \
  container restart --timeout 2 -- "$target")
[ "$restarted" = "$target" ] || {
  printf 'ERROR: Restricted Docker API did not restart the Gluetun target.\n' >&2
  exit 1
}

restarted=$(compose run --rm --no-deps --entrypoint docker ddns-watcher \
  container restart --timeout 2 -- "$proxy_target")
[ "$restarted" = "$proxy_target" ] || {
  printf 'ERROR: Restricted Docker API did not restart the vproxy target.\n' >&2
  exit 1
}

gluetun_netns=$(docker exec "$target" readlink /proc/self/ns/net)
vproxy_netns=$(docker exec "$proxy_target" readlink /proc/self/ns/net)
[ "$gluetun_netns" = "$vproxy_netns" ] || {
  printf 'ERROR: Restarted vproxy did not rejoin the Gluetun network namespace.\n' >&2
  exit 1
}

assert_docker_denied() {
  operation=$1
  shift
  if compose run --rm --no-deps --entrypoint docker ddns-watcher \
    "$@" >/dev/null 2>&1; then
    printf 'ERROR: Restricted Docker API unexpectedly allowed container %s.\n' \
      "$operation" >&2
    exit 1
  fi
}

assert_docker_denied inspect container inspect "$target"
assert_docker_denied vproxy-inspect container inspect "$proxy_target"
assert_docker_denied other-restart container restart --timeout 2 -- "$other_target"
assert_docker_denied stop container stop "$target"
assert_docker_denied vproxy-stop container stop "$proxy_target"
assert_docker_denied kill container kill "$target"
assert_docker_denied pause container pause "$target"
assert_docker_denied remove container rm --force "$target"

attempt=1
while ! docker exec "$proxy_target" nc -z 127.0.0.1 1080; do
  [ "$attempt" -lt 10 ] || {
    printf 'ERROR: Hardened vproxy listener did not become ready.\n' >&2
    exit 1
  }
  attempt=$((attempt + 1))
  sleep 1
done

docker exec "$proxy_target" /bin/sh -ec \
  'command -v wget >/dev/null && command -v ip >/dev/null && command -v grep >/dev/null'

printf 'Container contract test passed (helper, paired namespace, hardened health tools, two-target restart-only API).\n'
