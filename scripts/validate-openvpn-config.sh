#!/usr/bin/env bash
set -euo pipefail

# This validator intentionally stays host-side and dependency-light.
# It catches the common mistakes that make the stack fail before Docker even starts.

input_path="${1:-}"

if [[ -z "$input_path" ]]; then
  if [[ -n "${OPENVPN_CONFIG_DIR:-}" ]]; then
    input_path="$OPENVPN_CONFIG_DIR/openvpn"
  elif [[ -f ./.env ]]; then
    env_dir="$(grep -E '^OPENVPN_CONFIG_DIR=' ./.env | tail -1 | cut -d= -f2- || true)"
    input_path="${env_dir:-./config}/openvpn"
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

if [[ -z "$config_file" || ! -f "$config_file" ]]; then
  printf 'ERROR: OpenVPN config file not found: %s\n' "$config_file" >&2
  exit 1
fi

config_dir="$(cd "$(dirname "$config_file")" && pwd)"
config_file="$(cd "$config_dir" && pwd)/$(basename "$config_file")"

remote_line="$(grep -E '^[[:space:]]*remote[[:space:]]+' "$config_file" | head -1 || true)"
if [[ -z "$remote_line" ]]; then
  printf 'ERROR: No remote line found in %s\n' "$config_file" >&2
  exit 1
fi

read -r _ remote_host remote_port remote_proto _ <<<"$remote_line"

config_proto="$(grep -E '^[[:space:]]*proto[[:space:]]+' "$config_file" | head -1 | awk '{print $2}' || true)"
config_port="$(grep -E '^[[:space:]]*port[[:space:]]+' "$config_file" | head -1 | awk '{print $2}' || true)"

remote_port="${remote_port:-$config_port}"
remote_proto="${remote_proto:-$config_proto}"

remote_port="${remote_port:-1194}"
remote_proto="${remote_proto:-udp}"

printf 'Validated config: %s\n' "$config_file"
printf 'Primary remote: host=%s port=%s proto=%s\n' "$remote_host" "${remote_port:-<missing>}" "${remote_proto:-<missing>}"

# We warn on literal IPs because the whole point of this project is DDNS-friendly hostnames.
if [[ "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'WARNING: remote host looks like an IPv4 address, not a hostname. DDNS benefits only apply when you keep a hostname in remote.\n' >&2
fi

if [[ -z "${remote_host:-}" ]]; then
  printf 'ERROR: Expected remote line format to include at least a hostname after the remote directive.\n' >&2
  exit 1
fi

check_path_directive() {
  local directive="$1"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r _ maybe_path _ <<<"$line"

    # auth-user-pass with no second field is valid and means interactive or provider-specific auth handling.
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
  done < <(grep -E "^[[:space:]]*$directive[[:space:]]+" "$config_file" || true)
}

for directive in ca cert key tls-auth tls-crypt auth-user-pass; do
  check_path_directive "$directive"
done

printf 'OpenVPN config validation passed.\n'
