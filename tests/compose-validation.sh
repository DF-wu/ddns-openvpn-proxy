#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT HUP INT TERM

case_number=0

expect_failure() {
  description=$1
  shift
  case_number=$((case_number + 1))
  env_file=$workdir/fail-$case_number.env
  cp "$repo_root/.env.example" "$env_file"
  printf '%s\n' "$@" >> "$env_file"
  if "$repo_root/scripts/validate-compose.sh" "$env_file" >/dev/null 2>&1; then
    printf 'not ok %s - %s\n' "$case_number" "$description" >&2
    exit 1
  fi
  printf 'ok %s - %s\n' "$case_number" "$description"
}

printf 'TAP version 13\n'

expect_failure 'public bind without proxy credentials is rejected' \
  'PROXY_BIND_ADDRESS=0.0.0.0'

expect_failure 'partial HTTP credentials are rejected' \
  'HTTPPROXY_USER=only-user'

expect_failure 'partial SOCKS5 credentials are rejected' \
  'SOCKS5_PASSWORD=only-password'

expect_failure 'partial OpenVPN credentials are rejected' \
  'OPENVPN_USER=only-user'

expect_failure 'moving image tags are rejected' \
  'GLUETUN_IMAGE=qmcgaw/gluetun:latest'

case_number=$((case_number + 1))
public_env=$workdir/public.env
cp "$repo_root/.env.example" "$public_env"
printf '%s\n' \
  'PROXY_BIND_ADDRESS=0.0.0.0' \
  'HTTPPROXY_USER=http-user' \
  'HTTPPROXY_PASSWORD=http-password' \
  'SOCKS5_USER=socks-user' \
  'SOCKS5_PASSWORD=socks-password' >> "$public_env"
"$repo_root/scripts/validate-compose.sh" "$public_env" >/dev/null
printf 'ok %s - authenticated public bind is accepted\n' "$case_number"

printf '1..%s\n' "$case_number"

