#!/usr/bin/env bash
# Backward-compatible wrapper: sources the multi-protocol vpn-ddns-lib.sh
# with VPN_TYPE pinned to "openvpn" so all existing consumers continue to
# work unchanged. New consumers should source vpn-ddns-lib.sh directly and
# set VPN_TYPE=wireguard (or auto-detect) for WireGuard support.
set -euo pipefail

VPN_TYPE="${VPN_TYPE:-openvpn}"
source "$(dirname "${BASH_SOURCE[0]}")/vpn-ddns-lib.sh"
