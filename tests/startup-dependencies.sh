#!/bin/sh
# shellcheck disable=SC2016 # $fixture inside single quotes is a jq argument.
set -eu

# Real Compose startup using the production dependency graph and harmless
# Alpine stand-ins. The VPN cannot become healthy until the watcher starts.
# No production sockets, ports, devices, source profiles or state are mounted.
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
        read_only: true,
        cap_drop: ["ALL"],
        security_opt: ["no-new-privileges:true"],
        volumes: [($fixture + ":/fixture")],
        entrypoint: ["/bin/sh", "-ec"],
        command: [(if .key == "ddns-init" then "true"
                   elif .key == "ddns-watcher" then "touch /fixture/watcher-started; exec sleep 300"
                   else "exec sleep 300" end)]
      } +
      (if .key == "gluetun" then
        {healthcheck: {test: ["CMD", "test", "-f", "/fixture/watcher-started"], interval: "1s", timeout: "1s", retries: 1}}
       elif .key == "docker-socket-proxy" then
        {healthcheck: {test: ["CMD", "true"], interval: "1s", timeout: "1s", retries: 1}}
       else {} end)
    ))}
  ' > "$fixture/compose.json"

if ! docker compose -p "$project" -f "$fixture/compose.json" up -d --wait --wait-timeout 15 > "$fixture/up.log" 2>&1; then
  cat "$fixture/up.log" >&2
  printf 'FAIL: watcher must start even when VPN health requires DDNS recovery\n' >&2
  exit 1
fi
[ -f "$fixture/watcher-started" ] || {
  printf 'FAIL: watcher did not start\n' >&2
  exit 1
}
printf 'Compose startup dependency contract passed: watcher unblocks unhealthy VPN.\n'
