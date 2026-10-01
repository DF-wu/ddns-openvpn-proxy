#!/bin/sh
# Deprecated entry point kept for deployments that still mount this path.
# The implementation moved to scripts/ddns-vpn.sh (see docs/spec.md).
exec /bin/sh "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/ddns-vpn.sh" "$@"
