#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
subject=$repo_root/scripts/ddns-openvpn.sh
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT HUP INT TERM

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %s - %s\n' "$pass_count" "$1"
}

fail() {
  printf 'not ok %s - %s\n' "$((pass_count + 1))" "$1" >&2
  exit 1
}

assert_contains() {
  expected=$1
  file=$2
  grep -Fq "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_equals() {
  expected=$1
  actual=$2
  description=$3
  [ "$expected" = "$actual" ] || fail "$description (expected '$expected', got '$actual')"
}

new_fixture() {
  name=$1
  fixture=$workdir/$name
  mkdir -p "$fixture/source" "$fixture/state" "$fixture/bin"
  printf 'dummy-ca\n' > "$fixture/source/ca.crt"
  cat > "$fixture/source/client.ovpn" <<'EOF'
client
dev tun
proto udp
remote vpn.example.test 1194 udp # DDNS endpoint
resolv-retry infinite
ping 10
ping-restart 60
persist-key
persist-tun
ca ca.crt
EOF
  cat > "$fixture/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
[ "${DOCKER_SHOULD_FAIL:-0}" = 0 ] || exit 1
last_argument=
for argument do
  last_argument=$argument
done
[ "${DOCKER_FAIL_CONTAINER:-}" != "$last_argument" ]
EOF
  cat > "$fixture/bin/getent" <<'EOF'
#!/bin/sh
printf '%s\n' "${GETENT_OUTPUT:-}"
EOF
  cat > "$fixture/bin/nslookup" <<'EOF'
#!/bin/sh
printf '%s\n' "${NSLOOKUP_OUTPUT:-}"
EOF
  cat > "$fixture/bin/wget" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$WGET_LOG"
[ "${WGET_SHOULD_FAIL:-0}" = 0 ]
EOF
  cat > "$fixture/bin/nc" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NC_LOG"
[ "${NC_SHOULD_FAIL:-0}" = 0 ]
EOF
  chmod +x "$fixture/bin/docker" "$fixture/bin/getent" "$fixture/bin/nslookup" \
    "$fixture/bin/wget" "$fixture/bin/nc"
  printf '%s\n' "$fixture"
}

new_wireguard_fixture() {
  fixture=$(new_fixture "$1")
  cat > "$fixture/source/wg0.conf" <<'EOF'
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
Endpoint = vpn.example.test:51820 # DDNS endpoint
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  printf '%s\n' "$fixture"
}

run_subject() {
  fixture=$1
  shift
  vpn_type_value=${VPN_TYPE:-openvpn}
  case $vpn_type_value in
    openvpn) source_name=client.ovpn ;;
    wireguard) source_name=wg0.conf ;;
    *) source_name=client.ovpn ;;
  esac
  PATH="$fixture/bin:$PATH" \
  STATE_DIR="$fixture/state" \
  VPN_TYPE="$vpn_type_value" \
  VPN_SOURCE_CONFIG="$fixture/source/$source_name" \
  VPN_RENDERED_CONFIG="$fixture/state/runtime/vpn.conf" \
  DDNS_POLL_SECONDS=10 \
  DDNS_INIT_RETRY_SECONDS=1 \
  DDNS_HOSTNAME="${DDNS_HOSTNAME:-}" \
  DDNS_RESOLVER="${DDNS_RESOLVER:-}" \
  DDNS_OVERRIDE_IPS="${DDNS_OVERRIDE_IPS:-}" \
  GETENT_OUTPUT="${GETENT_OUTPUT:-}" \
  NSLOOKUP_OUTPUT="${NSLOOKUP_OUTPUT:-}" \
  OPENVPN_USER_CONFIGURED="${OPENVPN_USER:+1}" \
  OPENVPN_PASSWORD_CONFIGURED="${OPENVPN_PASSWORD:+1}" \
  HTTPPROXY_ENABLED="${HTTPPROXY:-on}" \
  HTTPPROXY_USER_CONFIGURED="${HTTPPROXY_USER:+1}" \
  HTTPPROXY_PASSWORD_CONFIGURED="${HTTPPROXY_PASSWORD:+1}" \
  SOCKS5_USER_CONFIGURED="${SOCKS5_USER:+1}" \
  SOCKS5_PASSWORD_CONFIGURED="${SOCKS5_PASSWORD:+1}" \
  PROXY_BIND_ADDRESS="${PROXY_BIND_ADDRESS:-127.0.0.1}" \
  GLUETUN_CONTAINER_NAME=gluetun-test \
  VPROXY_CONTAINER_NAME=vproxy-test \
  GLUETUN_RESTART_TIMEOUT_SECONDS=5 \
  GLUETUN_HEALTH_TIMEOUT_SECONDS="${GLUETUN_HEALTH_TIMEOUT_SECONDS:-5}" \
  DOCKER_LOG="$fixture/docker.log" \
  WGET_LOG="$fixture/wget.log" \
  NC_LOG="$fixture/nc.log" \
  sh "$subject" "$@"
}

printf 'TAP version 13\n'

fixture=$(new_fixture validate)
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" validate >/dev/null
pass 'valid profile and environment are accepted'

fixture=$(new_fixture render)
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" render 198.51.100.10
assert_contains 'remote 198.51.100.10 1194 udp # DDNS endpoint' "$fixture/state/runtime/vpn.conf"
assert_contains "ca $fixture/source/ca.crt" "$fixture/state/runtime/vpn.conf"
pass 'renderer writes IP and absolute referenced-file paths'

fixture=$(new_fixture init)
DDNS_OVERRIDE_IPS='198.51.100.11,198.51.100.10' run_subject "$fixture" init >/dev/null
assert_equals '198.51.100.10' "$(cat "$fixture/state/ddns/last-ip")" 'init chooses a deterministic address'
assert_contains 'remote 198.51.100.10 1194 udp' "$fixture/state/runtime/vpn.conf"
pass 'init sorts multiple A records and seeds runtime state'

fixture=$(new_fixture default_resolver)
GETENT_OUTPUT='203.0.113.20 STREAM vpn.example.test
203.0.113.10 DGRAM vpn.example.test' \
  DDNS_OVERRIDE_IPS='' run_subject "$fixture" init >/dev/null
assert_equals '203.0.113.10' "$(cat "$fixture/state/ddns/last-ip")" \
  'default getent resolver output is parsed and sorted'
pass 'default container resolver path returns valid IPv4 addresses'

fixture=$(new_fixture custom_resolver)
NSLOOKUP_OUTPUT='Server: 1.1.1.1
Address: 1.1.1.1:53

Name: vpn.example.test
Address: 203.0.113.30' \
  DDNS_RESOLVER=1.1.1.1 DDNS_OVERRIDE_IPS='' run_subject "$fixture" init >/dev/null
assert_equals '203.0.113.30' "$(cat "$fixture/state/ddns/last-ip")" \
  'custom nslookup resolver output is parsed'
pass 'explicit DDNS resolver path ignores the resolver address itself'

fixture=$(new_fixture stable_rr)
DDNS_OVERRIDE_IPS='198.51.100.10,198.51.100.11' run_subject "$fixture" init >/dev/null
DDNS_OVERRIDE_IPS='198.51.100.11,198.51.100.10' run_subject "$fixture" watch-once >/dev/null
[ ! -e "$fixture/docker.log" ] || fail 'DNS answer ordering must not restart Gluetun'
pass 'multi-address DNS answer reordering does not flap the tunnel'

fixture=$(new_fixture dns_failure)
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" init >/dev/null
profile_before=$(cat "$fixture/state/runtime/vpn.conf")
profile_inode_before=$(stat -c %i "$fixture/state/runtime/vpn.conf")
hash_before=$(cat "$fixture/state/ddns/source.sha256")
hash_inode_before=$(stat -c %i "$fixture/state/ddns/source.sha256")
last_ip_inode_before=$(stat -c %i "$fixture/state/ddns/last-ip")
GETENT_OUTPUT='not-an-ip STREAM vpn.example.test
999.51.100.10 DGRAM vpn.example.test' \
  DDNS_OVERRIDE_IPS='' run_subject "$fixture" watch-once >/dev/null
assert_equals '198.51.100.10' "$(cat "$fixture/state/ddns/last-ip")" 'DNS failure preserves last IP'
assert_equals "$profile_before" "$(cat "$fixture/state/runtime/vpn.conf")" \
  'DNS failure preserves the rendered profile'
assert_equals "$profile_inode_before" "$(stat -c %i "$fixture/state/runtime/vpn.conf")" \
  'DNS failure does not replace the rendered profile'
assert_equals "$hash_before" "$(cat "$fixture/state/ddns/source.sha256")" \
  'DNS failure preserves the source fingerprint'
assert_equals "$hash_inode_before" "$(stat -c %i "$fixture/state/ddns/source.sha256")" \
  'DNS failure does not replace the source fingerprint state'
assert_equals "$last_ip_inode_before" "$(stat -c %i "$fixture/state/ddns/last-ip")" \
  'DNS failure does not replace last IP state'
[ ! -e "$fixture/docker.log" ] || fail 'DNS failure must not restart Gluetun'
pass 'empty or invalid DNS answers preserve profile, state, and active tunnel'

fixture=$(new_fixture address_change)
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" init >/dev/null
old_profile_inode=$(stat -c %i "$fixture/state/runtime/vpn.conf")
DDNS_OVERRIDE_IPS=198.51.100.20 run_subject "$fixture" watch-once >/dev/null
assert_contains 'remote 198.51.100.20 1194 udp' "$fixture/state/runtime/vpn.conf"
assert_contains 'container restart --timeout 5 -- gluetun-test' "$fixture/docker.log"
assert_contains 'container restart --timeout 5 -- vproxy-test' "$fixture/docker.log"
assert_equals 'container restart --timeout 5 -- gluetun-test
container restart --timeout 5 -- vproxy-test' "$(cat "$fixture/docker.log")" \
  'Gluetun must restart before vproxy'
[ "$old_profile_inode" != "$(stat -c %i "$fixture/state/runtime/vpn.conf")" ] ||
  fail 'changed profile must be installed with an atomic rename'
assert_equals '198.51.100.20' "$(cat "$fixture/state/ddns/last-ip")" 'changed address is committed'
pass 'DDNS address change atomically renders and restarts Gluetun then vproxy'

fixture=$(new_fixture profile_change)
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" init >/dev/null
printf 'updated-ca\n' > "$fixture/source/ca.crt"
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" watch-once >/dev/null
assert_contains 'container restart --timeout 5 -- gluetun-test' "$fixture/docker.log"
assert_contains 'container restart --timeout 5 -- vproxy-test' "$fixture/docker.log"
pass 'referenced certificate changes restart both containers at the same IP'

fixture=$(new_fixture restart_failure)
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" init >/dev/null
if DOCKER_SHOULD_FAIL=1 DDNS_OVERRIDE_IPS=198.51.100.20 run_subject "$fixture" watch-once >/dev/null 2>&1; then
  fail 'watch-once must report a failed Docker restart'
fi
assert_equals '198.51.100.10' "$(cat "$fixture/state/ddns/last-ip")" 'failed restart must not commit new IP'
pass 'failed restart retains old state for the next retry'

fixture=$(new_fixture health_timeout)
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" init >/dev/null
if WGET_SHOULD_FAIL=1 GLUETUN_HEALTH_TIMEOUT_SECONDS=1 \
  DDNS_OVERRIDE_IPS=198.51.100.20 run_subject "$fixture" watch-once >/dev/null 2>&1; then
  fail 'watch-once must fail when Gluetun does not become healthy'
fi
assert_equals 'container restart --timeout 5 -- gluetun-test' "$(cat "$fixture/docker.log")" \
  'vproxy must not restart before Gluetun is healthy'
assert_equals '198.51.100.10' "$(cat "$fixture/state/ddns/last-ip")" \
  'health timeout must not commit new IP'
pass 'Gluetun health timeout leaves vproxy and committed state untouched'

fixture=$(new_fixture vproxy_restart_failure)
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" init >/dev/null
if DOCKER_FAIL_CONTAINER=vproxy-test DDNS_OVERRIDE_IPS=198.51.100.20 \
  run_subject "$fixture" watch-once >/dev/null 2>&1; then
  fail 'watch-once must report a failed vproxy restart'
fi
assert_equals '198.51.100.10' "$(cat "$fixture/state/ddns/last-ip")" \
  'failed vproxy restart must not commit new IP'
pass 'failed vproxy restart retains old state for a full-stack retry'

fixture=$(new_fixture vproxy_namespace_failure)
DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" init >/dev/null
if NC_SHOULD_FAIL=1 GLUETUN_HEALTH_TIMEOUT_SECONDS=1 \
  DDNS_OVERRIDE_IPS=198.51.100.20 run_subject "$fixture" watch-once >/dev/null 2>&1; then
  fail 'watch-once must fail when vproxy does not rejoin the Gluetun namespace'
fi
assert_equals '198.51.100.10' "$(cat "$fixture/state/ddns/last-ip")" \
  'vproxy namespace failure must not commit new IP'
pass 'missing vproxy listener in the Gluetun namespace retains old state'

fixture=$(new_fixture invalid_remote)
cat >> "$fixture/source/client.ovpn" <<'EOF'
remote backup.example.test 1194 udp
EOF
if DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'multiple remote directives must be rejected'
fi
pass 'ambiguous multi-remote profiles fail fast'

fixture=$(new_fixture missing_reference)
rm "$fixture/source/ca.crt"
if DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'missing referenced files must be rejected'
fi
pass 'missing certificate/key references fail fast'

fixture=$(new_fixture invalid_override)
if DDNS_OVERRIDE_IPS=not-an-ip run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'invalid override IP must be rejected'
fi
pass 'invalid diagnostic address overrides fail fast'

fixture=$(new_fixture openvpn_auth)
printf 'auth-user-pass\n' >> "$fixture/source/client.ovpn"
if DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'auth-user-pass without Gluetun credentials must be rejected'
fi
OPENVPN_USER=vpn-user OPENVPN_PASSWORD=vpn-password DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" validate >/dev/null
pass 'auth-user-pass requires a complete Gluetun credential pair'

fixture=$(new_fixture helper_proxy_gate)
if HTTPPROXY_USER=only-user DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'helper gate must reject partial HTTP credentials'
fi
if PROXY_BIND_ADDRESS=0.0.0.0 DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'helper gate must reject unauthenticated public proxy binding'
fi
PROXY_BIND_ADDRESS=0.0.0.0 \
  HTTPPROXY_USER=http-user HTTPPROXY_PASSWORD=http-password \
  SOCKS5_USER=socks-user SOCKS5_PASSWORD=socks-password \
  DDNS_OVERRIDE_IPS=198.51.100.10 run_subject "$fixture" validate >/dev/null
pass 'direct Compose helper gate enforces proxy exposure policy'

fixture=$(new_wireguard_fixture wireguard_validate)
VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" validate >/dev/null
pass 'valid WireGuard profile and environment are accepted'

fixture=$(new_wireguard_fixture wireguard_render)
cat >> "$fixture/source/wg0.conf" <<'EOF'

[Metadata]
Endpoint = do-not-rewrite.example.test:1234
EOF
VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" render 198.51.100.10
assert_contains 'Endpoint = 198.51.100.10:51820 # DDNS endpoint' \
  "$fixture/state/runtime/vpn.conf"
assert_contains 'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
  "$fixture/state/runtime/vpn.conf"
assert_contains 'Endpoint = do-not-rewrite.example.test:1234' \
  "$fixture/state/runtime/vpn.conf"
pass 'WireGuard renderer replaces only the endpoint hostname'

fixture=$(new_wireguard_fixture wireguard_init)
VPN_TYPE=wireguard DDNS_OVERRIDE_IPS='198.51.100.12,198.51.100.11' \
  run_subject "$fixture" init >/dev/null
assert_equals '198.51.100.11' "$(cat "$fixture/state/ddns/last-ip")" \
  'WireGuard init chooses a deterministic address'
assert_contains 'Endpoint = 198.51.100.11:51820' "$fixture/state/runtime/vpn.conf"
pass 'WireGuard init renders DDNS state for Gluetun'

fixture=$(new_wireguard_fixture wireguard_address_change)
VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" init >/dev/null
VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.20 \
  run_subject "$fixture" watch-once >/dev/null
assert_contains 'Endpoint = 198.51.100.20:51820' "$fixture/state/runtime/vpn.conf"
assert_contains 'container restart --timeout 5 -- gluetun-test' "$fixture/docker.log"
assert_contains 'container restart --timeout 5 -- vproxy-test' "$fixture/docker.log"
pass 'WireGuard DDNS address change renders and restarts both containers'

fixture=$(new_wireguard_fixture wireguard_profile_change)
VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" init >/dev/null
sed -i 's/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=/' \
  "$fixture/source/wg0.conf"
VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" watch-once >/dev/null
assert_contains 'container restart --timeout 5 -- gluetun-test' "$fixture/docker.log"
assert_contains 'container restart --timeout 5 -- vproxy-test' "$fixture/docker.log"
pass 'WireGuard profile changes restart both containers at the same IP'

fixture=$(new_wireguard_fixture wireguard_multiple_peers)
cat >> "$fixture/source/wg0.conf" <<'EOF'

[Peer]
PublicKey = DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=
Endpoint = backup.example.test:51820
EOF
if VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'multiple WireGuard peers must be rejected'
fi
pass 'ambiguous WireGuard multi-peer profiles fail fast'

fixture=$(new_wireguard_fixture wireguard_missing_key)
sed -i '/^PrivateKey[[:space:]]*=/d' "$fixture/source/wg0.conf"
if VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'WireGuard profile without PrivateKey must be rejected'
fi
pass 'WireGuard profiles missing required keys fail fast'

fixture=$(new_wireguard_fixture wireguard_invalid_endpoint)
sed -i 's/vpn.example.test:51820/vpn.example.test:70000/' "$fixture/source/wg0.conf"
if VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'WireGuard endpoint with invalid port must be rejected'
fi
pass 'invalid WireGuard endpoint ports fail fast'

fixture=$(new_wireguard_fixture wireguard_dns_failure)
VPN_TYPE=wireguard DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" init >/dev/null
VPN_TYPE=wireguard DDNS_OVERRIDE_IPS='' \
  run_subject "$fixture" watch-once >/dev/null
assert_equals '198.51.100.10' "$(cat "$fixture/state/ddns/last-ip")" \
  'WireGuard DNS failure preserves last IP'
[ ! -e "$fixture/docker.log" ] || fail 'WireGuard DNS failure must not restart Gluetun'
pass 'WireGuard transient DNS failure preserves the active tunnel'

fixture=$(new_fixture unknown_vpn_type)
if VPN_TYPE=ipsec DDNS_OVERRIDE_IPS=198.51.100.10 \
  run_subject "$fixture" validate >/dev/null 2>&1; then
  fail 'unknown VPN types must be rejected by the direct helper gate'
fi
pass 'direct helper gate rejects unknown VPN types'

printf '1..%s\n' "$pass_count"
