#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT HUP INT TERM

new_fixture() {
  name=$1
  fixture=$workdir/$name
  mkdir -p "$fixture/app/scripts" "$fixture/source/openvpn" \
    "$fixture/state/openvpn" "$fixture/state/ddns" "$fixture/bin"
  cp "$repo_root/compat/watcher/"*.sh "$fixture/app/scripts/"
  cat > "$fixture/source/openvpn/client.ovpn" <<'EOF'
client
remote vpn.example.test 1194
EOF
  cat > "$fixture/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
case $1 in
  inspect) printf 'healthy\n' ;;
  restart) printf '%s\n' "$2" ;;
esac
EOF
  cat > "$fixture/bin/getent" <<'EOF'
#!/bin/sh
printf '%s\n' "${GETENT_OUTPUT:-}"
EOF
  cat > "$fixture/bin/python3" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$fixture/bin/"*
  printf '%s\n' "$fixture"
}

run_watcher() {
  fixture=$1
  shift
  PATH="$fixture/bin:$PATH" \
  DOCKER_LOG="$fixture/docker.log" \
  WATCH_ONCE=1 \
  VPN_TYPE=openvpn \
  OPENVPN_SOURCE_CONFIG="$fixture/source/openvpn/client.ovpn" \
  OPENVPN_SOURCE_DIR="$fixture/source/openvpn" \
  OPENVPN_RENDERED_CONFIG="$fixture/state/openvpn/current.ovpn" \
  STATE_DIR="$fixture/state" \
  DDNS_HOSTNAME=vpn.example.test \
  DDNS_POLL_SECONDS=10 \
  DDNS_COOLDOWN_SECONDS=0 \
  GLUETUN_CONTAINER_NAME=gluetun-test \
  VPROXY_CONTAINER_NAME=vproxy-test \
  GLUETUN_HEALTH_TIMEOUT_SECONDS=5 \
  "$@" bash "$fixture/app/scripts/watch-ddns-and-restart.sh"
}

fixture=$(new_fixture dns-failure)
printf 'remote 198.51.100.10 1194\n' > "$fixture/state/openvpn/current.ovpn"
printf '198.51.100.10\n' > "$fixture/state/ddns/last-ip"
before=$(sha256sum "$fixture/state/openvpn/current.ovpn" "$fixture/state/ddns/last-ip")
run_watcher "$fixture" env DDNS_OVERRIDE_IP= >/dev/null
after=$(sha256sum "$fixture/state/openvpn/current.ovpn" "$fixture/state/ddns/last-ip")
[ "$before" = "$after" ]
[ ! -e "$fixture/docker.log" ]

fixture=$(new_fixture address-change)
printf 'remote 198.51.100.10 1194\n' > "$fixture/state/openvpn/current.ovpn"
printf '198.51.100.10\n' > "$fixture/state/ddns/last-ip"
run_watcher "$fixture" env DDNS_OVERRIDE_IP=198.51.100.20 >/dev/null
grep -q '^remote 198\.51\.100\.20 1194$' "$fixture/state/openvpn/current.ovpn"
[ "$(cat "$fixture/state/ddns/last-ip")" = 198.51.100.20 ]
[ "$(cat "$fixture/docker.log")" = 'restart gluetun-test
inspect --format {{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} gluetun-test
restart vproxy-test
inspect --format {{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} vproxy-test' ]

printf 'Compatibility watcher tests passed.\n'