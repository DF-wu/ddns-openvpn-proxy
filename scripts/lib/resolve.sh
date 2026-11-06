#!/bin/sh
# shellcheck disable=SC2154,SC2034
# Sourced by scripts/ddns-vpn.sh, which defines the globals used here
# (source_config, rendered_config, state files, restart targets) and consumes
# the variables this file sets.
# DNS resolution and deterministic address selection for ddns-vpn.

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

split_override_ips() {
  printf '%s\n' "${DDNS_OVERRIDE_IPS:-}" | tr ',' '\n' |
    awk '{ for (i = 1; i <= NF; i++) print $i }'
}

validate_override_ips() {
  [ -n "${DDNS_OVERRIDE_IPS:-}" ] || return 0
  override_tokens=$(split_override_ips)
  [ -n "$override_tokens" ] || die "DDNS_OVERRIDE_IPS contains no addresses"
  override_valid=$(printf '%s\n' "$override_tokens" | filter_ipv4s)
  [ "$(printf '%s\n' "$override_tokens" | sort -u)" = "$override_valid" ] ||
    die "DDNS_OVERRIDE_IPS contains an invalid IPv4 address"
}

# Print every valid IPv4 A record for $ddns_hostname, sorted and de-duplicated.
# Resolution order: diagnostic override, explicit resolver via nslookup, or the
# container's configured resolver via getent.
resolve_ipv4s() {
  if [ -n "${DDNS_OVERRIDE_IPS:-}" ]; then
    split_override_ips | filter_ipv4s
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

# Keep the previously committed address while it is still published, so DNS
# round-robin reordering never triggers a restart. Otherwise take the first
# sorted address.
select_ip() {
  addresses=$1
  preferred=${2:-}

  if [ -n "$preferred" ] && printf '%s\n' "$addresses" | grep -Fxq "$preferred"; then
    printf '%s\n' "$preferred"
    return
  fi

  printf '%s\n' "$addresses" | sed -n '1p'
}

resolve_and_select() {
  preferred=${1:-}
  addresses=$(resolve_ipv4s || true)
  [ -n "$addresses" ] || return 1
  select_ip "$addresses" "$preferred"
}
