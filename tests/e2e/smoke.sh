#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workdir="$repo_root/tests/e2e/.workdir"
project_name="openvpn_ddns_smoke"

reset_workdir() {
  mkdir -p "$workdir"
  docker run --rm -v "$workdir:/work" alpine:3.20 sh -c 'rm -rf /work/* /work/.[!.]* /work/..?* 2>/dev/null || true' >/dev/null 2>&1 || true
  mkdir -p "$workdir/server" "$workdir/config/openvpn"
}

cleanup() {
  docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" -f "$repo_root/tests/e2e/docker-compose.yml" --env-file "$workdir/.env" down --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$workdir:/work" alpine:3.20 sh -c 'rm -rf /work/* /work/.[!.]* /work/..?* 2>/dev/null || true' >/dev/null 2>&1 || true
}
trap cleanup EXIT

reset_workdir

printf 'Preparing local OpenVPN test fixture...\n'
docker run --rm -v "$workdir/server:/etc/openvpn" kylemanna/openvpn ovpn_genconfig -u udp://openvpn-server >/dev/null
docker run --rm -v "$workdir/server:/etc/openvpn" -e EASYRSA_BATCH=1 kylemanna/openvpn ovpn_initpki nopass >/dev/null
docker run --rm -v "$workdir/server:/etc/openvpn" alpine:3.20 sh -lc "sed -i '/push \"block-outside-dns\"/d; /push \"comp-lzo no\"/d' /etc/openvpn/openvpn.conf"
docker run --rm -v "$workdir/server:/etc/openvpn" kylemanna/openvpn easyrsa build-client-full client nopass >/dev/null
docker run --rm -v "$workdir/server:/etc/openvpn" kylemanna/openvpn ovpn_getclient client > "$workdir/config/openvpn/client.ovpn"
docker run --rm -v "$workdir/config:/work" alpine:3.20 sh -lc "sed -i '/^block-outside-dns$/d; /^comp-lzo /d' /work/openvpn/client.ovpn; printf '\nallow-compression no\nproviders legacy default\n' >> /work/openvpn/client.ovpn"

cat >"$workdir/.env" <<EOF
TZ=UTC
OPENVPN_CONFIG_DIR=$workdir/config
OPENVPN_USER=
OPENVPN_PASSWORD=
SOCKS5_PORT=1080
SOCKS5_USER=test
SOCKS5_PASSWORD=test
LAN_NETWORK=172.16.0.0/12
NAME_SERVERS=1.1.1.1,1.0.0.1
PUID=0
PGID=0
UMASK=022
E2E_OPENVPN_SERVER_DIR=$workdir/server
EOF

printf 'Validating compose files...\n'
docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" -f "$repo_root/tests/e2e/docker-compose.yml" --env-file "$workdir/.env" config -q

printf 'Starting local OpenVPN server fixture...\n'
docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" -f "$repo_root/tests/e2e/docker-compose.yml" --env-file "$workdir/.env" up -d openvpn-server

printf 'Starting OpenVPN + SOCKS5 runtime...\n'
docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" -f "$repo_root/tests/e2e/docker-compose.yml" --env-file "$workdir/.env" up -d vpn

printf 'Waiting for the upstream runtime to accept the hostname-based OpenVPN config and bring up tun0...\n'
for _ in $(seq 1 90); do
  logs="$(docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" -f "$repo_root/tests/e2e/docker-compose.yml" --env-file "$workdir/.env" logs vpn 2>&1 || true)"
  if grep -q "VPN remote server(s) defined as 'openvpn-server,'" <<<"$logs" \
    && docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" -f "$repo_root/tests/e2e/docker-compose.yml" --env-file "$workdir/.env" exec -T vpn sh -c 'ip link show tun0 >/dev/null 2>&1'; then
    contract_verified=1
    break
  fi
  sleep 2
done

if [[ "${contract_verified:-0}" != 1 ]]; then
  printf 'ERROR: The upstream runtime did not accept the hostname-based OpenVPN config in time.\n' >&2
  docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" -f "$repo_root/tests/e2e/docker-compose.yml" --env-file "$workdir/.env" logs vpn openvpn-server || true
  exit 1
fi

printf 'Starting upstream microsocks manually for the local fixture...\n'
docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" -f "$repo_root/tests/e2e/docker-compose.yml" --env-file "$workdir/.env" exec -T vpn sh -c 'vpn_ip=$(ip -o -4 addr show tun0 | awk "{print \$4}" | cut -d/ -f1); export vpn_ip VPN_ENABLED=yes ENABLE_SOCKS=yes SOCKS_USER=test SOCKS_PASS=test DEBUG=false; /bin/bash /home/nobody/microsocks.sh'

printf 'Checking that microsocks is listening...\n'
docker compose -p "$project_name" -f "$repo_root/docker-compose.yml" -f "$repo_root/tests/e2e/docker-compose.yml" --env-file "$workdir/.env" exec -T vpn sh -c 'ss -ltnp | grep -q ":9118"'

printf 'Runtime contract smoke test passed.\n'
