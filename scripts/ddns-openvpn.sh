#!/bin/sh
# Deprecated command alias; requires the complete scripts/ tree beside it.
# Copying or mounting this file alone no longer works (see docs/spec.md).
exec /bin/sh "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/ddns-vpn.sh" "$@"
