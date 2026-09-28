#!/bin/sh
# shellcheck disable=SC2154,SC2034
# Sourced by scripts/ddns-vpn.sh, which defines the globals used here
# (source_config, rendered_config, state files, restart targets) and consumes
# the variables this file sets.
# WireGuard adapter (Gluetun backend). Sourced by scripts/ddns-vpn.sh.
#
# Source profile: a single-peer wg-quick style profile whose Peer Endpoint is
# HOSTNAME:PORT. Only the Endpoint host is rewritten; keys stay in the file and
# reach Gluetun through WIREGUARD_CONF_SECRETFILE, never through environment.

adapter_backend() {
  printf 'gluetun\n'
}

adapter_display_name() {
  printf 'WireGuard\n'
}

adapter_validate() {
  validate_source_file WireGuard

  wireguard_endpoint=$(awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    function invalid(message) {
      print "WireGuard profile " message > "/dev/stderr"
      failed = 1
    }

    /^[[:space:]]*([#;]|$)/ { next }

    /^[[:space:]]*\[/ {
      heading = trim($0)
      if (heading == "[Interface]") {
        section = "interface"
        interface_count++
      } else if (heading == "[Peer]") {
        section = "peer"
        peer_count++
      } else {
        section = "other"
      }
      next
    }

    {
      line = $0
      sub(/[[:space:]]+[#;].*$/, "", line)
      separator = index(line, "=")
      if (separator == 0) next
      key = trim(substr(line, 1, separator - 1))
      value = trim(substr(line, separator + 1))

      if (section == "interface" && key == "PrivateKey") {
        private_key_count++
        if (value == "") invalid("has an empty Interface PrivateKey")
      } else if (section == "interface" && key == "Address") {
        address_count++
        if (value == "") invalid("has an empty Interface Address")
      } else if (section == "peer" && key == "PublicKey") {
        public_key_count++
        if (value == "") invalid("has an empty Peer PublicKey")
      } else if (section == "peer" && key == "Endpoint") {
        endpoint_count++
        endpoint = value
      }
    }

    END {
      if (interface_count != 1) invalid("must contain exactly one [Interface] section")
      if (peer_count != 1) invalid("must contain exactly one [Peer] section")
      if (private_key_count != 1) invalid("must contain exactly one Interface PrivateKey")
      if (address_count != 1) invalid("must contain exactly one Interface Address")
      if (public_key_count != 1) invalid("must contain exactly one Peer PublicKey")
      if (endpoint_count != 1) invalid("must contain exactly one Peer Endpoint")
      if (failed) exit 1
      print endpoint
    }
  ' "$source_config") || die "invalid WireGuard profile: $source_config"

  case $wireguard_endpoint in
    *:*:*) die "WireGuard Endpoint must use a hostname and one port: $wireguard_endpoint" ;;
    *:*) ;;
    *) die "WireGuard Endpoint must be HOST:PORT: $wireguard_endpoint" ;;
  esac

  endpoint_host=${wireguard_endpoint%:*}
  endpoint_port=${wireguard_endpoint##*:}
  validate_hostname "$endpoint_host" ||
    die "invalid WireGuard Endpoint hostname: $endpoint_host"
  is_uint "$endpoint_port" || die "WireGuard Endpoint port is not numeric: $endpoint_port"
  validate_port "$endpoint_port" ||
    die "WireGuard Endpoint port must be between 1 and 65535: $endpoint_port"
}

adapter_fingerprint() {
  file_sha256 "$source_config"
}

adapter_render() {
  resolved_ip=$1

  awk -v ip="$resolved_ip" '
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]+/, "", section)
      sub(/[[:space:]]+$/, "", section)
      print
      next
    }

    section == "[Peer]" && /^[[:space:]]*Endpoint[[:space:]]*=/ {
      match($0, /^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*/)
      prefix = substr($0, 1, RLENGTH)
      remainder = substr($0, RLENGTH + 1)
      comment = ""
      if (match(remainder, /[[:space:]]+[#;]/)) {
        comment = substr(remainder, RSTART)
        remainder = substr(remainder, 1, RSTART - 1)
      }
      sub(/^[[:space:]]+/, "", remainder)
      sub(/[[:space:]]+$/, "", remainder)
      separator = index(remainder, ":")
      port = substr(remainder, separator + 1)
      print prefix ip ":" port comment
      next
    }

    { print }
  ' "$source_config" | install_rendered "$rendered_config"
}
