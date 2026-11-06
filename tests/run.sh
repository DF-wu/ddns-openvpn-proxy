#!/bin/sh
set -eu

# Offline test suites: no Docker daemon needed except `docker compose config`
# for the Compose contract cases. The real container contract lives in
# tests/container-contract.sh (make test-container).

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)

printf '### helper behaviour (tests/helper.sh)\n'
sh "$repo_root/tests/helper.sh"
printf '\n### Compose contract (tests/compose-validation.sh)\n'
sh "$repo_root/tests/compose-validation.sh"
printf '\n### frozen compatibility watcher (tests/compat-watcher.sh)\n'
sh "$repo_root/tests/compat-watcher.sh"
