#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/openvpn-ddns-lib.sh
source "$repo_root/scripts/openvpn-ddns-lib.sh"

input_path="${1:-}"

if [[ -z "$input_path" ]]; then
  if [[ -n "${OPENVPN_SOURCE_CONFIG:-}" ]]; then
    input_path="$OPENVPN_SOURCE_CONFIG"
  elif [[ -n "${OPENVPN_CONFIG_DIR:-}" ]]; then
    input_path="$OPENVPN_CONFIG_DIR/openvpn"
  else
    input_path="./config/openvpn"
  fi
fi

if [[ -d "$input_path" ]]; then
  mapfile -t ovpn_files < <(find "$input_path" -maxdepth 1 -type f -name '*.ovpn' | sort)
  if [[ "${#ovpn_files[@]}" -eq 0 ]]; then
    printf 'ERROR: No .ovpn file found in directory: %s\n' "$input_path" >&2
    exit 1
  fi
  if [[ "${#ovpn_files[@]}" -gt 1 ]]; then
    printf 'ERROR: Found multiple .ovpn files in %s. Keep exactly one active profile in this directory.\n' "$input_path" >&2
    printf 'Files:\n' >&2
    printf '  - %s\n' "${ovpn_files[@]}" >&2
    exit 1
  fi
  config_file="${ovpn_files[0]}"
else
  config_file="$input_path"
fi

if [[ ! -f "$config_file" ]]; then
  printf 'ERROR: OpenVPN config file not found: %s\n' "$config_file" >&2
  exit 1
fi

config_dir="$(cd "$(dirname "$config_file")" && pwd)"
config_file="$config_dir/$(basename "$config_file")"

remote_line="$(get_primary_remote_line "$config_file" || true)"
if [[ -z "$remote_line" ]]; then
  printf 'ERROR: No remote line found in %s\n' "$config_file" >&2
  exit 1
fi

read -r _ remote_host remote_port remote_proto _ <<<"$remote_line"
remote_port="${remote_port:-1194}"
remote_proto="${remote_proto:-udp}"

printf 'Validated config: %s\n' "$config_file"
printf 'Primary remote: host=%s port=%s proto=%s\n' "$remote_host" "$remote_port" "$remote_proto"

if [[ "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'WARNING: remote host already looks like a literal IPv4 address. This repository is meant for hostname/DDNS-driven source configs.\n' >&2
fi

check_path_directive() {
  local directive="$1"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r _ maybe_path _ <<<"$line"

    if [[ "$directive" == "auth-user-pass" && -z "${maybe_path:-}" ]]; then
      continue
    fi

    [[ -z "${maybe_path:-}" ]] && continue
    [[ "$maybe_path" == "stdin" ]] && continue

    if [[ "$maybe_path" = /* ]]; then
      resolved_path="$maybe_path"
    else
      resolved_path="$config_dir/$maybe_path"
    fi

    if [[ ! -f "$resolved_path" ]]; then
      printf 'ERROR: %s references missing file: %s\n' "$directive" "$resolved_path" >&2
      exit 1
    fi
  done < <(grep -E "^[[:space:]]*$directive([[:space:]]+.+)?$" "$config_file" || true)
}

for directive in ca cert key tls-auth tls-crypt auth-user-pass; do
  check_path_directive "$directive"
done

printf 'OpenVPN config validation passed.\n'
