#!/usr/bin/env bash
set -euo pipefail

vpn_type="${VPN_TYPE:-openvpn}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workdir="$repo_root/tests/e2e/.workdir"
rm -rf "$workdir"
mkdir -p "$workdir/config/openvpn" "$workdir/config/wireguard" "$workdir/state/openvpn" "$workdir/state/wireguard" "$workdir/state/ddns"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

mkdir -p "$workdir/bin"
cat >"$workdir/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$1" "$2" >> "$DOCKER_LOG"
EOF
chmod +x "$workdir/bin/docker"

export STATE_DIR="$workdir/state"
export DDNS_HOSTNAME="vpn.example.test"
export DDNS_OVERRIDE_IP="198.51.100.10"
export GLUETUN_CONTAINER_NAME="gluetun-under-test"
export DOCKER_LOG="$workdir/docker.log"
export PATH="$workdir/bin:$PATH"
export WATCH_ONCE=1

if [[ "$vpn_type" == "wireguard" ]]; then
  cat >"$workdir/config/wireguard/wg0.conf" <<'EOF'
# comment before interface

[Interface]
PrivateKey = test_private_key
Address = 10.0.0.2/24

[Peer]
PublicKey = test_public_key
Endpoint = vpn.example.test:51820
AllowedIPs = 0.0.0.0/0
EOF

  export WIREGUARD_SOURCE_CONFIG="$workdir/config/wireguard/wg0.conf"
  export WIREGUARD_RENDERED_CONFIG="$workdir/state/wireguard/wg0.conf"
  unset VPN_TYPE

  "$repo_root/scripts/validate-wireguard-config.sh" "$WIREGUARD_SOURCE_CONFIG"
  "$repo_root/scripts/render-vpn-config.sh" "$WIREGUARD_SOURCE_CONFIG" "$WIREGUARD_RENDERED_CONFIG"
  grep -q 'Endpoint = 198.51.100.10:51820' "$WIREGUARD_RENDERED_CONFIG"

  printf '198.51.100.10\n' > "$workdir/state/ddns/last-ip"
  export DDNS_OVERRIDE_IP="198.51.100.11"

  "$repo_root/scripts/watch-ddns-and-restart.sh"

  grep -q 'Endpoint = 198.51.100.11:51820' "$WIREGUARD_RENDERED_CONFIG"
  grep -q 'restart gluetun-under-test' "$DOCKER_LOG"

  printf 'WireGuard smoke test passed.\n'
else
  cat >"$workdir/config/openvpn/client.ovpn" <<'EOF'
client
proto udp
remote vpn.example.test 1194
ca ca.crt
EOF

  printf 'dummy cert\n' > "$workdir/config/openvpn/ca.crt"

  export OPENVPN_SOURCE_CONFIG="$workdir/config/openvpn/client.ovpn"
  export OPENVPN_SOURCE_DIR="$workdir/config/openvpn"
  export OPENVPN_RENDERED_CONFIG="$workdir/state/openvpn/current.ovpn"

  "$repo_root/scripts/render-openvpn-config.sh" "$OPENVPN_SOURCE_CONFIG" "$OPENVPN_RENDERED_CONFIG"
  grep -q 'remote 198.51.100.10 1194' "$OPENVPN_RENDERED_CONFIG"
  grep -q "ca $workdir/config/openvpn/ca.crt" "$OPENVPN_RENDERED_CONFIG"

  printf '198.51.100.10\n' > "$workdir/state/ddns/last-ip"
  export DDNS_OVERRIDE_IP="198.51.100.11"

  "$repo_root/scripts/watch-ddns-and-restart.sh"

  grep -q 'remote 198.51.100.11 1194' "$OPENVPN_RENDERED_CONFIG"
  grep -q 'restart gluetun-under-test' "$DOCKER_LOG"

  printf 'OpenVPN smoke test passed.\n'
fi
