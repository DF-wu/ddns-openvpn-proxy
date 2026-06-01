#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/vpn-ddns-lib.sh
source "$repo_root/scripts/vpn-ddns-lib.sh"

vpn_type="${VPN_TYPE:-openvpn}"

if [[ "$vpn_type" == "wireguard" ]]; then
  exec "$repo_root/scripts/validate-wireguard-config.sh" "$@"
else
  exec "$repo_root/scripts/validate-openvpn-config.sh" "$@"
fi
