#!/bin/sh
# shellcheck disable=SC2154,SC2034
# Sourced by scripts/ddns-vpn.sh, which defines the globals used here
# (source_config, rendered_config, state files, restart targets) and consumes
# the variables this file sets.
# OpenVPN adapter (Gluetun backend). Sourced by scripts/ddns-vpn.sh.
#
# Source profile: an OpenVPN client profile with exactly one active `remote`
# directive whose host is the DDNS hostname. Relative file references are
# validated against the profile directory and rewritten to absolute paths in
# the rendered profile so Gluetun reads them from the read-only /source mount.

openvpn_file_directives='ca|cert|key|tls-auth|tls-crypt|tls-crypt-v2|crl-verify|dh|pkcs12|secret|askpass|http-proxy-user-pass'

adapter_backend() {
  printf 'gluetun\n'
}

adapter_display_name() {
  printf 'OpenVPN\n'
}

# Print "directive<TAB>reference" for every file-referencing directive.
openvpn_file_references() {
  awk -v directives="^($openvpn_file_directives)\$" '
    /^[[:space:]]*[#;]/ { next }
    $1 ~ directives && NF >= 2 { print $1 "\t" $2 }
  ' "$source_config"
}

openvpn_validate_references() {
  tab=$(printf '\t')
  openvpn_file_references |
  while IFS="$tab" read -r directive reference; do
    case $reference in
      *\"*|*\'*)
        die "$directive uses a quoted path; paths containing whitespace are not supported: $reference"
        ;;
      stdin) ;;
      *) require_readable_reference "$directive" "$reference" ;;
    esac
  done
}

adapter_validate() {
  validate_source_file OpenVPN

  remote_count=$(awk '
    /^[[:space:]]*[#;]/ { next }
    $1 == "remote" { count++ }
    END { print count + 0 }
  ' "$source_config")
  [ "$remote_count" -eq 1 ] ||
    die "expected exactly one active remote directive in $source_config, found $remote_count"

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
  if ! { [ "$remote_fields" -ge 2 ] && [ "$remote_fields" -le 4 ]; }; then
    die "remote must be: remote HOST [PORT] [PROTO]"
  fi

  endpoint_host=$(awk '
    /^[[:space:]]*[#;]/ { next }
    $1 == "remote" { print $2; exit }
  ' "$source_config")

  endpoint_port=$(awk '
    /^[[:space:]]*[#;]/ { next }
    $1 == "remote" { if (NF >= 3 && $3 !~ /^[#;]/) print $3; exit }
  ' "$source_config")
  if [ -n "$endpoint_port" ]; then
    is_uint "$endpoint_port" || die "remote port is not numeric: $endpoint_port"
    validate_port "$endpoint_port" || die "remote port must be between 1 and 65535: $endpoint_port"
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
    if ! { [ "${OPENVPN_USER_CONFIGURED:-0}" = 1 ] &&
      [ "${OPENVPN_PASSWORD_CONFIGURED:-0}" = 1 ]; }; then
      die "profile uses auth-user-pass; set both OPENVPN_USER and OPENVPN_PASSWORD"
    fi
  fi

  openvpn_validate_references
}

# Fingerprint covers the profile and every file it references, so a rotated
# certificate triggers a restart even when the DDNS address is unchanged.
# auth-user-pass paths are excluded because Gluetun replaces that directive.
adapter_fingerprint() {
  tab=$(printf '\t')
  {
    printf '%s\n' "$source_config"
    openvpn_file_references |
    while IFS="$tab" read -r directive reference; do
      case $reference in
        stdin) ;;
        *) resolve_reference "$reference" ;;
      esac
    done
  } | hash_file_list
}

adapter_render() {
  resolved_ip=$1
  source_parent=$(dirname "$source_config")

  awk -v ip="$resolved_ip" -v source_parent="$source_parent" \
      -v directives="^($openvpn_file_directives)\$" '
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

    $1 ~ directives && NF >= 2 {
      $2 = absolute($2)
    }

    { print }
  ' "$source_config" | install_rendered "$rendered_config"
}
