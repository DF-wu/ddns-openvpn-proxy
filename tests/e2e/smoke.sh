#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workdir="$repo_root/tests/e2e/.workdir"
rm -rf "$workdir"
mkdir -p "$workdir/config/openvpn" "$workdir/state/openvpn" "$workdir/state/ddns"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

cat >"$workdir/config/openvpn/client.ovpn" <<'EOF'
client
proto udp
remote vpn.example.test 1194
ca ca.crt
EOF

printf 'dummy cert\n' > "$workdir/config/openvpn/ca.crt"

mkdir -p "$workdir/bin"
cat >"$workdir/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$1" "$2" >> "$DOCKER_LOG"
EOF
chmod +x "$workdir/bin/docker"

export OPENVPN_SOURCE_CONFIG="$workdir/config/openvpn/client.ovpn"
export OPENVPN_SOURCE_DIR="$workdir/config/openvpn"
export OPENVPN_RENDERED_CONFIG="$workdir/state/openvpn/current.ovpn"
export STATE_DIR="$workdir/state"
export DDNS_HOSTNAME="vpn.example.test"
export DDNS_OVERRIDE_IP="198.51.100.10"

"$repo_root/scripts/render-openvpn-config.sh" "$OPENVPN_SOURCE_CONFIG" "$OPENVPN_RENDERED_CONFIG"
grep -q 'remote 198.51.100.10 1194' "$OPENVPN_RENDERED_CONFIG"
grep -q "ca $workdir/config/openvpn/ca.crt" "$OPENVPN_RENDERED_CONFIG"

printf '198.51.100.10\n' > "$workdir/state/ddns/last-ip"
export DDNS_OVERRIDE_IP="198.51.100.11"
export GLUETUN_CONTAINER_NAME="gluetun-under-test"
export DOCKER_LOG="$workdir/docker.log"
export PATH="$workdir/bin:$PATH"
export WATCH_ONCE=1

"$repo_root/scripts/watch-ddns-and-restart.sh"

grep -q 'remote 198.51.100.11 1194' "$OPENVPN_RENDERED_CONFIG"
grep -q 'restart gluetun-under-test' "$DOCKER_LOG"

printf 'Smoke test passed.\n'
