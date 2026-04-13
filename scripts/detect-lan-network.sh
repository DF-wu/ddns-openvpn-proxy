#!/usr/bin/env bash
set -euo pipefail

# Print the first non-docker CIDR route that looks like the host LAN.
# This is a helper only; always confirm the result before putting it in .env.
lan_cidr="$(ip route | awk '!/ (docker0|br-|veth|tun)/ && /^[0-9]/ && /src/ {print $1; exit}' || true)"

if [[ -z "$lan_cidr" ]]; then
  printf 'ERROR: Could not infer a LAN CIDR automatically. Set LAN_NETWORK manually in .env.\n' >&2
  exit 1
fi

printf '%s\n' "$lan_cidr"
