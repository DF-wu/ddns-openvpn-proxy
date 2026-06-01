#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/vpn-ddns-lib.sh
source "$repo_root/scripts/vpn-ddns-lib.sh"

input_path="${1:-}"

if [[ -z "$input_path" ]]; then
  if [[ -n "${WIREGUARD_SOURCE_CONFIG:-}" ]]; then
    input_path="$WIREGUARD_SOURCE_CONFIG"
  elif [[ -n "${WIREGUARD_CONFIG_DIR:-}" ]]; then
    input_path="$WIREGUARD_CONFIG_DIR/wireguard"
  else
    input_path="./config/wireguard"
  fi
fi

if [[ -d "$input_path" ]]; then
  mapfile -t conf_files < <(find "$input_path" -maxdepth 1 -type f -name '*.conf' | sort)
  if [[ "${#conf_files[@]}" -eq 0 ]]; then
    printf 'ERROR: No .conf file found in directory: %s\n' "$input_path" >&2
    exit 1
  fi
  if [[ "${#conf_files[@]}" -gt 1 ]]; then
    printf 'ERROR: Found multiple .conf files in %s. Keep exactly one active profile in this directory.\n' "$input_path" >&2
    printf 'Files:\n' >&2
    printf '  - %s\n' "${conf_files[@]}" >&2
    exit 1
  fi
  config_file="${conf_files[0]}"
else
  config_file="$input_path"
fi

if [[ ! -f "$config_file" ]]; then
  printf 'ERROR: WireGuard config file not found: %s\n' "$config_file" >&2
  exit 1
fi

config_dir="$(cd "$(dirname "$config_file")" && pwd)"
config_file="$config_dir/$(basename "$config_file")"

if ! grep -q '^\[Interface\]' "$config_file"; then
  printf 'ERROR: No [Interface] section found in %s\n' "$config_file" >&2
  exit 1
fi

if ! grep -q '^\[Peer\]' "$config_file"; then
  printf 'ERROR: No [Peer] section found in %s\n' "$config_file" >&2
  exit 1
fi

endpoint_line="$(grep -E '^[[:space:]]*Endpoint[[:space:]]*=' "$config_file" | head -1 || true)"
if [[ -z "$endpoint_line" ]]; then
  printf 'ERROR: No Endpoint line found in %s\n' "$config_file" >&2
  exit 1
fi

endpoint_value="${endpoint_line#*=}"
endpoint_value="$(echo "$endpoint_value" | sed 's/^[[:space:]]*//')"
endpoint_host="${endpoint_value%:*}"

has_private_key=0
peer_has_public_key=0
in_peer=0

while IFS= read -r line; do
  case "$line" in
    \[Interface\])
      in_interface=1
      in_peer=0
      ;;
    \[Peer\])
      if [[ "$in_peer" == 1 && "$peer_has_public_key" -ne 1 ]]; then
        printf 'ERROR: [Peer] section missing PublicKey in %s\n' "$config_file" >&2
        exit 1
      fi
      in_interface=0
      in_peer=1
      peer_has_public_key=0
      ;;
    '['*)
      in_interface=0
      in_peer=0
      ;;
    *)
      if [[ "$in_interface" == 1 ]] && [[ "$line" =~ ^[[:space:]]*PrivateKey[[:space:]]*= ]]; then
        has_private_key=1
      fi
      if [[ "$in_peer" == 1 ]] && [[ "$line" =~ ^[[:space:]]*PublicKey[[:space:]]*= ]]; then
        peer_has_public_key=1
      fi
      ;;
  esac
done < "$config_file"

if [[ "$in_peer" == 1 && "$peer_has_public_key" -ne 1 ]]; then
  printf 'ERROR: [Peer] section missing PublicKey in %s\n' "$config_file" >&2
  exit 1
fi

if [[ "$has_private_key" -ne 1 ]]; then
  printf 'ERROR: No PrivateKey found in [Interface] section of %s\n' "$config_file" >&2
  exit 1
fi

printf 'Validated config: %s\n' "$config_file"
printf 'Endpoint: %s\n' "$endpoint_value"

if [[ "$endpoint_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'WARNING: Endpoint host already looks like a literal IPv4 address. This repository is meant for hostname/DDNS-driven source configs.\n' >&2
fi

printf 'WireGuard config validation passed.\n'
