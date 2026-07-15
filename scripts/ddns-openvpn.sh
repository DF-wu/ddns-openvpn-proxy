#!/bin/sh
set -eu

# DDNS-to-Gluetun adapter. This is deliberately POSIX shell so the repository
# can run it from the stock docker:cli image without installing packages or
# building a project-specific image.

state_dir=${STATE_DIR:-/state}
source_config=${OPENVPN_SOURCE_CONFIG:-/source/client.ovpn}
rendered_config=${OPENVPN_RENDERED_CONFIG:-$state_dir/openvpn/client.ovpn}
last_ip_file=$state_dir/ddns/last-ip
source_hash_file=$state_dir/ddns/source.sha256
heartbeat_file=$state_dir/ddns/watcher-heartbeat
poll_seconds=${DDNS_POLL_SECONDS:-60}
retry_seconds=${DDNS_INIT_RETRY_SECONDS:-5}
gluetun_container=${GLUETUN_CONTAINER_NAME:-ddns-openvpn-proxy}
restart_timeout=${GLUETUN_RESTART_TIMEOUT_SECONDS:-20}

remote_source_host=
ddns_hostname=

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  level=$1
  shift
  printf '%s level=%s %s\n' "$(timestamp)" "$level" "$*"
}

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

validate_configured_pair() {
  pair_name=$1
  user_configured=${2:-0}
  password_configured=${3:-0}
  case $user_configured:$password_configured in
    0:0|1:1) ;;
    *) die "$pair_name user and password must both be set or both be empty" ;;
  esac
}

validate_relative_references() {
  source_parent=$(dirname "$source_config")
  tab=$(printf '\t')

  awk '
    /^[[:space:]]*[#;]/ { next }
    $1 ~ /^(ca|cert|key|tls-auth|tls-crypt|tls-crypt-v2|crl-verify|dh|pkcs12|secret|askpass|http-proxy-user-pass)$/ && NF >= 2 {
      print $1 "\t" $2
    }
  ' "$source_config" |
  while IFS="$tab" read -r directive reference; do
    case $reference in
      *\"*|*\'*)
        die "$directive uses a quoted path; paths containing whitespace are not supported: $reference"
        ;;
      stdin) ;;
      /*)
        [ -r "$reference" ] || die "$directive references an unreadable file: $reference"
        ;;
      *)
        [ -r "$source_parent/$reference" ] ||
          die "$directive references an unreadable file: $source_parent/$reference"
        ;;
    esac
  done
}

validate_config() {
  [ -f "$source_config" ] || die "OpenVPN profile not found: $source_config"
  [ -r "$source_config" ] || die "OpenVPN profile is not readable: $source_config"
  [ -s "$source_config" ] || die "OpenVPN profile is empty: $source_config"

  remote_count=$(awk '
    /^[[:space:]]*[#;]/ { next }
    $1 == "remote" { count++ }
    END { print count + 0 }
  ' "$source_config")
  [ "$remote_count" -eq 1 ] ||
    die "expected exactly one active remote directive in $source_config, found $remote_count"

  remote_source_host=$(awk '
    /^[[:space:]]*[#;]/ { next }
    $1 == "remote" { print $2; exit }
  ' "$source_config")

  remote_fields=$(awk '
    /^[[:space:]]*[#;]/ { next }
    $1 == "remote" {
      fields = NF
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[#;]/) {
          fields = i - 1
          break
        }
      }
      print fields
      exit
    }
  ' "$source_config")
  [ "$remote_fields" -ge 2 ] && [ "$remote_fields" -le 4 ] ||
    die "remote must be: remote HOST [PORT] [PROTO]"

  remote_port=$(awk '
    /^[[:space:]]*[#;]/ { next }
    $1 == "remote" { if (NF >= 3 && $3 !~ /^[#;]/) print $3; exit }
  ' "$source_config")
  if [ -n "$remote_port" ]; then
    is_uint "$remote_port" || die "remote port is not numeric: $remote_port"
    [ "$remote_port" -ge 1 ] && [ "$remote_port" -le 65535 ] ||
      die "remote port must be between 1 and 65535: $remote_port"
  fi

  remote_protocol=$(awk '
    /^[[:space:]]*[#;]/ { next }
    $1 == "remote" { if (NF >= 4 && $4 !~ /^[#;]/) print $4; exit }
  ' "$source_config")
  case $remote_protocol in
    ''|udp|tcp) ;;
    *) die "remote protocol must be udp or tcp when specified: $remote_protocol" ;;
  esac

  auth_user_pass_count=$(awk '
    /^[[:space:]]*[#;]/ { next }
    $1 == "auth-user-pass" { count++ }
    END { print count + 0 }
  ' "$source_config")
  if [ "$auth_user_pass_count" -gt 0 ]; then
    [ "${OPENVPN_USER_CONFIGURED:-0}" = 1 ] &&
      [ "${OPENVPN_PASSWORD_CONFIGURED:-0}" = 1 ] ||
      die "profile uses auth-user-pass; set both OPENVPN_USER and OPENVPN_PASSWORD"
  fi

  validate_configured_pair OPENVPN \
    "${OPENVPN_USER_CONFIGURED:-0}" "${OPENVPN_PASSWORD_CONFIGURED:-0}"
  validate_configured_pair HTTPPROXY \
    "${HTTPPROXY_USER_CONFIGURED:-0}" "${HTTPPROXY_PASSWORD_CONFIGURED:-0}"
  validate_configured_pair SOCKS5 \
    "${SOCKS5_USER_CONFIGURED:-0}" "${SOCKS5_PASSWORD_CONFIGURED:-0}"

  case ${HTTPPROXY_ENABLED:-on} in
    on|off) ;;
    *) die "HTTPPROXY must be on or off" ;;
  esac

  if [ "${PROXY_BIND_ADDRESS:-127.0.0.1}" != 127.0.0.1 ]; then
    [ "${SOCKS5_USER_CONFIGURED:-0}" = 1 ] ||
      die "SOCKS5 credentials are required when PROXY_BIND_ADDRESS is not 127.0.0.1"
    if [ "${HTTPPROXY_ENABLED:-on}" = on ]; then
      [ "${HTTPPROXY_USER_CONFIGURED:-0}" = 1 ] ||
        die "HTTP proxy credentials are required when PROXY_BIND_ADDRESS is not 127.0.0.1"
    fi
  fi

  ddns_hostname=${DDNS_HOSTNAME:-$remote_source_host}
  validate_hostname "$ddns_hostname" || die "invalid DDNS hostname: $ddns_hostname"
  if is_ipv4 "$ddns_hostname"; then
    die "DDNS target must be a hostname, not an IPv4 address: $ddns_hostname"
  fi

  if [ -n "${DDNS_RESOLVER:-}" ]; then
    is_ipv4 "$DDNS_RESOLVER" || die "DDNS_RESOLVER must be an IPv4 address: $DDNS_RESOLVER"
  fi

  if [ -n "${DDNS_OVERRIDE_IPS:-}" ]; then
    override_tokens=$(printf '%s\n' "$DDNS_OVERRIDE_IPS" |
      tr ',' '\n' | awk '{ for (i = 1; i <= NF; i++) print $i }')
    [ -n "$override_tokens" ] || die "DDNS_OVERRIDE_IPS contains no addresses"
    override_valid=$(printf '%s\n' "$override_tokens" | filter_ipv4s)
    [ "$(printf '%s\n' "$override_tokens" | sort -u)" = "$override_valid" ] ||
      die "DDNS_OVERRIDE_IPS contains an invalid IPv4 address"
  fi

  is_uint "$poll_seconds" && [ "$poll_seconds" -ge 10 ] ||
    die "DDNS_POLL_SECONDS must be an integer of at least 10"
  is_uint "$retry_seconds" && [ "$retry_seconds" -ge 1 ] ||
    die "DDNS_INIT_RETRY_SECONDS must be a positive integer"
  is_uint "$restart_timeout" && [ "$restart_timeout" -ge 1 ] ||
    die "GLUETUN_RESTART_TIMEOUT_SECONDS must be a positive integer"
  case $gluetun_container in
    ''|-*|*[!A-Za-z0-9_.-]*) die "invalid GLUETUN_CONTAINER_NAME: $gluetun_container" ;;
  esac

  validate_relative_references
}

filter_ipv4s() {
  awk -F. '
    NF == 4 {
      valid = 1
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255 ||
            (length($i) > 1 && substr($i, 1, 1) == "0")) valid = 0
      }
      if (valid) print $0
    }
  ' | sort -u
}

resolve_ipv4s() {
  if [ -n "${DDNS_OVERRIDE_IPS:-}" ]; then
    printf '%s\n' "$DDNS_OVERRIDE_IPS" | tr ',' '\n' |
      awk '{ for (i = 1; i <= NF; i++) print $i }' | filter_ipv4s
    return
  fi

  if [ -n "${DDNS_RESOLVER:-}" ]; then
    nslookup "$ddns_hostname" "$DDNS_RESOLVER" 2>/dev/null |
      awk '
        /^Name:[[:space:]]/ { answers = 1; next }
        answers && /^Address([[:space:]][0-9]+)?:[[:space:]]/ {
          sub(/^Address([[:space:]][0-9]+)?:[[:space:]]*/, "")
          print
        }
      ' | filter_ipv4s
    return
  fi

  getent ahostsv4 "$ddns_hostname" 2>/dev/null |
    awk '{ print $1 }' | filter_ipv4s
}

read_state() {
  file=$1
  [ -r "$file" ] || return 1
  sed -n '1p' "$file"
}

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

source_hash() {
  source_parent=$(dirname "$source_config")
  tab=$(printf '\t')

  {
    sha256sum "$source_config"
    awk '
      /^[[:space:]]*[#;]/ { next }
      $1 ~ /^(ca|cert|key|tls-auth|tls-crypt|tls-crypt-v2|crl-verify|dh|pkcs12|secret|askpass|http-proxy-user-pass)$/ && NF >= 2 {
        print $1 "\t" $2
      }
    ' "$source_config" |
    while IFS="$tab" read -r directive reference; do
      case $reference in
        stdin) ;;
        /*) sha256sum "$reference" ;;
        *) sha256sum "$source_parent/$reference" ;;
      esac
    done
  } | sha256sum | awk '{ print $1 }'
}

select_ip() {
  addresses=$1
  preferred=${2:-}

  if [ -n "$preferred" ] && printf '%s\n' "$addresses" | grep -Fxq "$preferred"; then
    printf '%s\n' "$preferred"
    return
  fi

  printf '%s\n' "$addresses" | sed -n '1p'
}

render_config() {
  resolved_ip=$1
  output_parent=$(dirname "$rendered_config")
  source_parent=$(dirname "$source_config")
  mkdir -p "$output_parent"
  temporary=$(mktemp "$output_parent/.client.ovpn.XXXXXX")

  awk -v ip="$resolved_ip" -v source_parent="$source_parent" '
    function absolute(path) {
      if (path == "" || path == "stdin" || path ~ /^\//) return path
      return source_parent "/" path
    }

    /^[[:space:]]*[#;]/ { print; next }

    $1 == "remote" {
      $2 = ip
      print
      next
    }

    $1 ~ /^(ca|cert|key|tls-auth|tls-crypt|tls-crypt-v2|crl-verify|dh|pkcs12|secret|askpass|http-proxy-user-pass)$/ && NF >= 2 {
      $2 = absolute($2)
    }

    { print }
  ' "$source_config" > "$temporary"

  chmod 600 "$temporary"
  mv -f "$temporary" "$rendered_config"
}

touch_heartbeat() {
  write_state "$(date -u '+%s')" "$heartbeat_file"
}

resolve_and_select() {
  preferred=${1:-}
  addresses=$(resolve_ipv4s || true)
  [ -n "$addresses" ] || return 1
  select_ip "$addresses" "$preferred"
}

initialize() {
  validate_config
  log INFO "initializing hostname=$ddns_hostname profile=$source_config"

  while :; do
    previous_ip=$(read_state "$last_ip_file" || true)
    if selected_ip=$(resolve_and_select "$previous_ip"); then
      render_config "$selected_ip"
      write_state "$selected_ip" "$last_ip_file"
      write_state "$(source_hash)" "$source_hash_file"
      log INFO "rendered profile hostname=$ddns_hostname ip=$selected_ip output=$rendered_config"
      return 0
    fi

    log WARN "DNS lookup failed hostname=$ddns_hostname retry_in=${retry_seconds}s"
    sleep "$retry_seconds"
  done
}

restart_gluetun() {
  docker container restart --timeout "$restart_timeout" -- "$gluetun_container" >/dev/null
}

watch_once() {
  validate_config
  touch_heartbeat
  previous_ip=$(read_state "$last_ip_file" || true)
  previous_hash=$(read_state "$source_hash_file" || true)

  if ! selected_ip=$(resolve_and_select "$previous_ip"); then
    log WARN "DNS lookup failed hostname=$ddns_hostname; keeping current tunnel"
    return 0
  fi

  current_hash=$(source_hash)
  if [ "$selected_ip" = "$previous_ip" ] &&
     [ "$current_hash" = "$previous_hash" ] &&
     [ -s "$rendered_config" ]; then
    return 0
  fi

  reason=profile-change
  [ "$selected_ip" = "$previous_ip" ] || reason=address-change
  render_config "$selected_ip"

  if restart_gluetun; then
    write_state "$selected_ip" "$last_ip_file"
    write_state "$current_hash" "$source_hash_file"
    log INFO "restarted Gluetun reason=$reason hostname=$ddns_hostname old_ip=${previous_ip:-none} new_ip=$selected_ip"
    return 0
  fi

  log ERROR "failed to restart Gluetun container=$gluetun_container; will retry"
  return 1
}

watch() {
  validate_config
  trap 'log INFO "watcher stopping"; exit 0' INT TERM
  log INFO "watching hostname=$ddns_hostname interval=${poll_seconds}s"

  while :; do
    watch_once || true
    [ "${WATCH_ONCE:-0}" = 1 ] && return 0
    sleep "$poll_seconds"
  done
}

healthcheck() {
  is_uint "$poll_seconds" || exit 1
  heartbeat=$(read_state "$heartbeat_file" || true)
  is_uint "$heartbeat" || exit 1
  now=$(date -u '+%s')
  maximum_age=$((poll_seconds * 3 + 30))
  age=$((now - heartbeat))
  [ "$age" -ge 0 ] && [ "$age" -le "$maximum_age" ]
}

usage() {
  cat <<'EOF'
Usage: ddns-openvpn.sh COMMAND

Commands:
  validate     Validate the source OpenVPN profile and environment
  render IP    Render the Gluetun-compatible profile with IP
  init         Resolve DDNS and render the initial runtime profile
  watch        Poll DDNS, render changes, and restart Gluetun
  watch-once   Run one watcher iteration (primarily for diagnostics/tests)
  healthcheck  Check that the watcher loop is making progress
EOF
}

command=${1:-}
case $command in
  validate)
    validate_config
    log INFO "configuration valid hostname=$ddns_hostname profile=$source_config"
    ;;
  render)
    validate_config
    [ "$#" -eq 2 ] || die "render requires one IPv4 address"
    is_ipv4 "$2" || die "invalid render IPv4 address: $2"
    render_config "$2"
    ;;
  init)
    initialize
    ;;
  watch)
    watch
    ;;
  watch-once)
    validate_config
    watch_once
    ;;
  healthcheck)
    healthcheck
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
