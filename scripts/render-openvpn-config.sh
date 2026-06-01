#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/vpn-ddns-lib.sh
source "$repo_root/scripts/vpn-ddns-lib.sh"

VPN_TYPE=openvpn exec "$repo_root/scripts/render-vpn-config.sh" "$@"
