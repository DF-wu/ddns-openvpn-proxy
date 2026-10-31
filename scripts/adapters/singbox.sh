#!/bin/sh
# shellcheck disable=SC2154,SC2034
# Sourced by scripts/ddns-vpn.sh, which defines the globals used here
# (source_config, rendered_config, state files, restart targets) and consumes
# the variables this file sets.
# sing-box adapter (singbox backend). Sourced by scripts/ddns-vpn.sh.
#
# Source profile: a sing-box JSON configuration that defines the outbound(s)
# only. The outbound reaching the VPN/proxy server must be tagged "vpn" and its
# "server" must be the DDNS hostname. Inbounds, DNS, and the default route are
# managed by the stack (docker-compose.singbox.yml) so proxy credentials and
# leak protection come from .env rather than from the profile.
#
# The renderer replaces `"server": "HOST"` with the resolved IPv4 address and
# rewrites relative certificate_path/key_path values to absolute /source paths.
# JSON is handled with awk on the whole document, so formatting (pretty or
# minified) does not matter. The runtime file is validated by `sing-box check`
# inside the backend container before sing-box starts.

singbox_path_keys='certificate_path|key_path'

adapter_backend() {
  printf 'singbox\n'
}

adapter_display_name() {
  printf 'sing-box\n'
}

# Print every string value of a JSON key given as $1, one per line.
singbox_string_values() {
  key=$1
  awk -v key="\"$key\"[[:space:]]*:[[:space:]]*\"" '
    {
      rest = $0
      while (match(rest, key "[^\"]*\"")) {
        found = substr(rest, RSTART, RLENGTH)
        sub(key, "", found)
        sub(/"$/, "", found)
        print found
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$source_config"
}

singbox_has_key() {
  grep -Eq "\"$1\"[[:space:]]*:" "$source_config"
}

adapter_validate() {
  validate_source_file sing-box

  singbox_has_key outbounds || die "sing-box profile must define \"outbounds\""
  singbox_has_key inbounds &&
    die "sing-box profile must not define \"inbounds\"; the stack manages proxy listeners (see docs/backends/singbox.md)"
  grep -Eq '"tag"[[:space:]]*:[[:space:]]*"vpn"' "$source_config" ||
    die "sing-box profile must contain an outbound tagged \"vpn\""
  if singbox_has_key dns || singbox_has_key route; then
    log WARN "sing-box profile defines dns/route; stack-managed values (dns.final, route.final) take precedence"
  fi

  server_hosts=$(singbox_string_values server | while IFS= read -r value; do
    is_ipv4 "$value" || printf '%s\n' "$value"
  done | sort -u)

  if [ -n "${DDNS_HOSTNAME:-}" ]; then
    endpoint_host=$DDNS_HOSTNAME
    printf '%s\n' "$server_hosts" | grep -Fxq "$endpoint_host" ||
      die "DDNS_HOSTNAME=$endpoint_host does not appear as a \"server\" value in the sing-box profile"
  else
    host_count=$(printf '%s\n' "$server_hosts" | grep -c . || true)
    case $host_count in
      1) endpoint_host=$server_hosts ;;
      0) die "sing-box profile has no hostname-based \"server\"; the vpn outbound must use the DDNS hostname" ;;
      *) die "sing-box profile has several hostname-based \"server\" values; set DDNS_HOSTNAME to the one to monitor" ;;
    esac
  fi
  validate_hostname "$endpoint_host" || die "invalid sing-box server hostname: $endpoint_host"
  endpoint_port=

  for key in certificate_path key_path; do
    singbox_string_values "$key" | while IFS= read -r value; do
      require_readable_reference "$key" "$value"
    done
  done
}

adapter_fingerprint() {
  {
    printf '%s\n' "$source_config"
    for key in certificate_path key_path; do
      singbox_string_values "$key" | while IFS= read -r value; do
        resolve_reference "$value"
      done
    done
  } | hash_file_list
}

adapter_render() {
  resolved_ip=$1
  source_parent=$(dirname "$source_config")

  awk -v host="$endpoint_host" -v ip="$resolved_ip" -v source_parent="$source_parent" \
      -v path_keys="\"($singbox_path_keys)\"[[:space:]]*:[[:space:]]*\"[^\"/][^\"]*\"" '
    {
      line = $0
      gsub("\"server\"[[:space:]]*:[[:space:]]*\"" host "\"", "\"server\": \"" ip "\"", line)
      out = ""
      while (match(line, path_keys)) {
        found = substr(line, RSTART, RLENGTH)
        key = found
        sub(/[[:space:]]*:.*$/, "", key)
        value = found
        sub(/^"[^"]*"[[:space:]]*:[[:space:]]*"/, "", value)
        sub(/"$/, "", value)
        out = out substr(line, 1, RSTART - 1) key ": \"" source_parent "/" value "\""
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  ' "$source_config" | install_rendered "$rendered_config"
}
