#!/bin/sh
# shellcheck disable=SC2016 # $fixture inside single quotes is a jq argument.
set -eu

# Preserve main's safe startup graph, including its known unhealthy-boot limit.
# Stand-ins use no sockets, ports, TUN, source profiles or network access.
repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
project=ddns-startup-contract-$$
chmod 777 "$fixture"
cleanup() {
  docker compose -p "$project" -f "$fixture/compose.json" down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT HUP INT TERM

docker compose --env-file "$repo_root/.env.example" -f "$repo_root/docker-compose.yml" config --format json |
  jq --arg fixture "$fixture" '
    {services: (.services | with_entries(
      .value = {
        image: "alpine:3.22",
        depends_on: (.value.depends_on // {}),
        network_mode: (if .key == "vproxy" then "service:gluetun" else "none" end),
        read_only: true, cap_drop: ["ALL"],
        security_opt: ["no-new-privileges:true"],
        volumes: [($fixture + ":/fixture")],
        entrypoint: ["/bin/sh", "-ec"],
        command: [(if .key == "ddns-init" then "true"
                   elif .key == "vproxy" then "touch /fixture/sidecar-started; test -f /fixture/vpn-ready; exec sleep 300"
                   elif .key == "ddns-watcher" then "touch /fixture/watcher-started; test -f /fixture/vpn-ready; exec sleep 300"
                   else "exec sleep 300" end)]
      } +
      (if .key == "gluetun" then
        {healthcheck: {test: ["CMD", "test", "-f", "/fixture/vpn-ready"], interval: "1s", timeout: "1s", retries: 1}}
       elif (.key == "docker-socket-proxy" or .key == "vproxy") then
        {healthcheck: {test: ["CMD", "true"], interval: "1s", timeout: "1s", retries: 1}}
       else {} end)
    ))}
  ' > "$fixture/compose.json"

if docker compose -p "$project" -f "$fixture/compose.json" up -d --wait --wait-timeout 15 > "$fixture/up.log" 2>&1; then
  printf 'FAIL: unhealthy VPN must keep proxy/watcher startup gated\n' >&2
  exit 1
fi
if [ -f "$fixture/sidecar-started" ] || [ -f "$fixture/watcher-started" ]; then
  cat "$fixture/up.log" >&2
  printf 'FAIL: proxy or watcher started before VPN health\n' >&2
  exit 1
fi
printf 'PASS: unhealthy startup retains main proxy/watcher gates (known cold-recovery limitation).\n'

# Simulate an operator correcting the endpoint externally; readiness must
# admit the proxy, then the watcher, without a concurrent helper/VPN restart.
touch "$fixture/vpn-ready"
if ! docker compose -p "$project" -f "$fixture/compose.json" up -d --wait --wait-timeout 20 > "$fixture/up.log" 2>&1; then
  cat "$fixture/up.log" >&2
  exit 1
fi
if ! { [ -f "$fixture/sidecar-started" ] && [ -f "$fixture/watcher-started" ]; }; then
  printf 'FAIL: healthy startup did not start both proxy and watcher\n' >&2
  exit 1
fi
printf 'PASS: healthy startup completes normally with the established dependency graph.\n'
