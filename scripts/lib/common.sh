#!/bin/sh
# shellcheck disable=SC2154,SC2034
# Sourced by scripts/ddns-vpn.sh, which defines the globals used here
# (source_config, rendered_config, state files, restart targets) and consumes
# the variables this file sets.
# Shared helpers for ddns-vpn. Sourced by scripts/ddns-vpn.sh; not executable
# on its own. POSIX sh only: the helper runs from the stock docker:cli image.

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  level=$1
  shift
  printf '%s level=%s %s\n' "$(timestamp)" "$level" "$*"
}

# Configuration and usage errors exit with 64 (EX_USAGE) so operators can tell
# a permanent misconfiguration apart from a transient runtime failure (exit 1).
die() {
  log ERROR "$*" >&2
  exit 64
}

is_uint() {
  case $1 in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_ipv4() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255 ||
            (length($i) > 1 && substr($i, 1, 1) == "0")) exit 1
      }
    }
  '
}

validate_hostname() {
  hostname=$1
  case $hostname in
    ''|.*|*.|*..*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#hostname}" -le 253 ] || return 1
  return 0
}

validate_port() {
  port=$1
  is_uint "$port" || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# Credential pairs reach the helper only as 0/1 presence flags; the helper never
# sees the secret values themselves.
validate_configured_pair() {
  pair_name=$1
  user_configured=${2:-0}
  password_configured=${3:-0}
  case $user_configured:$password_configured in
    0:0|1:1) ;;
    *) die "$pair_name user and password must both be set or both be empty" ;;
  esac
}

validate_container_name() {
  variable=$1
  value=$2
  case $value in
    ''|-*|*[!A-Za-z0-9_.-]*) die "invalid $variable: $value" ;;
  esac
}

validate_source_file() {
  profile_name=$1
  [ -f "$source_config" ] || die "$profile_name profile not found: $source_config"
  [ -r "$source_config" ] || die "$profile_name profile is not readable: $source_config"
  [ -s "$source_config" ] || die "$profile_name profile is empty: $source_config"
}

# Resolve a file reference found inside a profile against the profile's own
# directory. Absolute paths are returned unchanged.
resolve_reference() {
  reference=$1
  case $reference in
    /*) printf '%s\n' "$reference" ;;
    *) printf '%s/%s\n' "$(dirname "$source_config")" "$reference" ;;
  esac
}

require_readable_reference() {
  directive=$1
  reference=$2
  resolved=$(resolve_reference "$reference")
  [ -r "$resolved" ] || die "$directive references an unreadable file: $resolved"
}

read_state() {
  file=$1
  [ -r "$file" ] || return 1
  sed -n '1p' "$file"
}

# All runtime artifacts are written to a temporary file in the destination
# directory and installed with rename(2), so readers never observe a partial
# file. Mode 0600 because profiles may embed keys.
write_state() {
  value=$1
  destination=$2
  directory=$(dirname "$destination")
  mkdir -p "$directory"
  temporary=$(mktemp "$directory/.tmp.XXXXXX")
  printf '%s\n' "$value" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$destination"
}

# Usage: producer_command | install_rendered DESTINATION
install_rendered() {
  destination=$1
  directory=$(dirname "$destination")
  mkdir -p "$directory"
  temporary=$(mktemp "$directory/.render.XXXXXX")
  cat > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$destination"
}

file_sha256() {
  sha256sum "$1" | awk '{ print $1 }'
}

# Usage: printf 'path\n...' | hash_file_list  -> single digest over every file
hash_file_list() {
  {
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      sha256sum "$path"
    done
  } | sha256sum | awk '{ print $1 }'
}

touch_heartbeat() {
  write_state "$(date -u '+%s')" "$heartbeat_file"
}
