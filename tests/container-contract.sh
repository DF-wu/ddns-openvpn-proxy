#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
project=ddns-openvpn-contract-$$
target=ddns-openvpn-restart-test-$$
proxy_target=ddns-openvpn-vproxy-test-$$
source_dir=$(mktemp -d)

cleanup() {
  docker compose -f "$repo_root/docker-compose.yml" -p "$project" \
    down --remove-orphans --volumes >/dev/null 2>&1 || true
  docker rm -f "$target" >/dev/null 2>&1 || true
  docker rm -f "$proxy_target" >/dev/null 2>&1 || true
  rm -rf "$source_dir"
}
trap cleanup EXIT HUP INT TERM

cp "$repo_root/examples/openvpn/custom.ovpn" "$source_dir/custom.ovpn"
chmod 600 "$source_dir/custom.ovpn"

export OPENVPN_CONFIG_DIR="$source_dir"
export OPENVPN_CONFIG_FILE=custom.ovpn
export DDNS_OVERRIDE_IPS=198.51.100.10

compose() {
  docker compose -f "$repo_root/docker-compose.yml" -p "$project" "$@"
}

compose up -d --wait --wait-timeout 60 docker-socket-proxy >/dev/null
compose run --rm --no-deps ddns-init validate >/dev/null
compose run --rm --no-deps ddns-init init >/dev/null

docker run -d --name "$target" alpine:3.22 sleep 300 >/dev/null

restarted=$(compose run --rm --no-deps --entrypoint docker ddns-watcher \
  container restart --timeout 2 -- "$target")
[ "$restarted" = "$target" ] || {
  printf 'ERROR: Restricted Docker API did not restart the test container.\n' >&2
  exit 1
}

if compose run --rm --no-deps --entrypoint docker ddns-watcher \
  container stop "$target" >/dev/null 2>&1; then
  printf 'ERROR: Restricted Docker API unexpectedly allowed container stop.\n' >&2
  exit 1
fi

vproxy_image=$(compose config --format json | jq -r '.services.vproxy.image')
docker run -d --name "$proxy_target" \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=8m,mode=1777 \
  --entrypoint /bin/sh "$vproxy_image" -ec \
  'exec /bin/vproxy run --bind 0.0.0.0:1080 socks5' >/dev/null

attempt=1
while ! docker exec "$proxy_target" nc -z 127.0.0.1 1080; do
  [ "$attempt" -lt 10 ] || {
    printf 'ERROR: Hardened vproxy listener did not become ready.\n' >&2
    exit 1
  }
  attempt=$((attempt + 1))
  sleep 1
done

printf 'Container contract test passed (stock helper, hardened vproxy, restart-only API).\n'
