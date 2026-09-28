#!/bin/sh
# shellcheck disable=SC2154,SC2034
# Sourced by scripts/ddns-vpn.sh, which defines the globals used here
# (source_config, rendered_config, state files, restart targets) and consumes
# the variables this file sets.
# OpenConnect adapter (openconnect backend). Sourced by scripts/ddns-vpn.sh.
#
# Source profile: an OpenConnect options file in the `--config` format (one
# long option per line without the leading dashes). The gateway is not part of
# that format, so it comes from OPENCONNECT_SERVER and OPENCONNECT_PORT. The
# renderer appends a `resolve=HOST:IP` line so OpenConnect connects to the
# resolved address while still validating the certificate for HOST, and writes
# a companion vpn.env the backend container sources at start.

openconnect_file_options='cafile|certificate|sslkey|mca-certificate|mca-key'
openconnect_forbidden_options='config|resolve|user|passwd-on-stdin|cookie-on-stdin|background|interface|script-tun'
openconnect_protocols='anyconnect|nc|gp|pulse|f5|fortinet|array'

adapter_backend() {
  printf 'openconnect\n'
}

adapter_display_name() {
  printf 'OpenConnect\n'
}

# Print "option<TAB>value" for every non-comment line. Accepts `key=value`,
# `key = value`, `key value`, and bare flags (value empty), like OpenConnect.
openconnect_options() {
  awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (match(line, /[[:space:]]*=[[:space:]]*|[[:space:]]+/)) {
        key = substr(line, 1, RSTART - 1)
        value = substr(line, RSTART + RLENGTH)
      } else {
        key = line
        value = ""
      }
      print key "\t" value
    }
  ' "$source_config"
}

# Values with a URI scheme (pkcs11:, tpm:) are not files.
openconnect_is_file_value() {
  case $1 in
    ''|*:*) return 1 ;;
    *) return 0 ;;
  esac
}

adapter_validate() {
  validate_source_file OpenConnect

  endpoint_host=${OPENCONNECT_SERVER:-}
  endpoint_port=${OPENCONNECT_PORT:-443}
  [ -n "$endpoint_host" ] || die "OPENCONNECT_SERVER must be set to the gateway hostname"
  validate_hostname "$endpoint_host" || die "invalid OPENCONNECT_SERVER hostname: $endpoint_host"
  is_ipv4 "$endpoint_host" && die "OPENCONNECT_SERVER must be a hostname, not an IPv4 address: $endpoint_host"
  validate_port "$endpoint_port" || die "OPENCONNECT_PORT must be between 1 and 65535: $endpoint_port"

  if [ "${OPENCONNECT_USER_CONFIGURED:-0}" != 1 ]; then
    log WARN "OPENCONNECT_USER is empty; only certificate-based authentication can succeed"
  fi

  tab=$(printf '\t')
  openconnect_options |
  while IFS="$tab" read -r option value; do
    case $option in
      *[!A-Za-z0-9-]*) die "invalid option syntax in OpenConnect profile: $option" ;;
    esac
    if printf '%s\n' "$option" | grep -Eqx "$openconnect_forbidden_options"; then
      die "OpenConnect profile must not set '$option'; the stack manages it (see docs/backends/openconnect.md)"
    fi
    if [ "$option" = protocol ] && ! printf '%s\n' "$value" | grep -Eqx "$openconnect_protocols"; then
      die "unsupported OpenConnect protocol: $value"
    fi
    if printf '%s\n' "$option" | grep -Eqx "$openconnect_file_options"; then
      case $value in
        *\"*|*\'*) die "$option uses a quoted path; paths containing whitespace are not supported: $value" ;;
      esac
      if openconnect_is_file_value "$value"; then
        require_readable_reference "$option" "$value"
      fi
    fi
  done
}

adapter_fingerprint() {
  tab=$(printf '\t')
  {
    printf '%s\n' "$source_config"
    openconnect_options |
    while IFS="$tab" read -r option value; do
      if printf '%s\n' "$option" | grep -Eqx "$openconnect_file_options" &&
         openconnect_is_file_value "$value"; then
        resolve_reference "$value"
      fi
    done
  } | hash_file_list
}

adapter_render() {
  resolved_ip=$1
  source_parent=$(dirname "$source_config")

  {
    awk -v source_parent="$source_parent" -v file_options="^($openconnect_file_options)\$" '
      /^[[:space:]]*(#|$)/ { print; next }
      {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (match(line, /[[:space:]]*=[[:space:]]*|[[:space:]]+/)) {
          key = substr(line, 1, RSTART - 1)
          value = substr(line, RSTART + RLENGTH)
        } else {
          key = line
          value = ""
        }
        if (key ~ file_options && value != "" && value !~ /:/ && value !~ /^\//) {
          print key "=" source_parent "/" value
          next
        }
        print
      }
    ' "$source_config"
    printf '\n# --- appended by ddns-vpn; do not edit ---\n'
    printf 'non-inter\n'
    printf 'resolve=%s:%s\n' "$endpoint_host" "$resolved_ip"
  } | install_rendered "$rendered_config"

  {
    printf "DDNS_VPN_HOST='%s'\n" "$endpoint_host"
    printf "DDNS_VPN_PORT='%s'\n" "$endpoint_port"
    printf "DDNS_VPN_IP='%s'\n" "$resolved_ip"
    printf "DDNS_VPN_URL='https://%s:%s'\n" "$endpoint_host" "$endpoint_port"
  } | install_rendered "$rendered_env"
}
