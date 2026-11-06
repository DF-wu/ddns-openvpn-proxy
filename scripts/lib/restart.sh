#!/bin/sh
# shellcheck disable=SC2154,SC2034
# Sourced by scripts/ddns-vpn.sh, which defines the globals used here
# (source_config, rendered_config, state files, restart targets) and consumes
# the variables this file sets.
# Restart orchestration for ddns-vpn. The helper only ever issues
# `docker container restart` for the configured targets; the Docker API proxy
# rejects everything else.

# Readiness probes are URLs: http://host:port/path is fetched with wget,
# tcp://host:port is checked with a TCP connect.
validate_probe() {
  variable=$1
  probe=$2
  case $probe in
    http://*|https://*) ;;
    tcp://*)
      probe_host=${probe#tcp://}
      probe_port=${probe_host##*:}
      probe_host=${probe_host%:*}
      if ! { [ -n "$probe_host" ] && validate_port "$probe_port"; }; then
        die "$variable must be tcp://HOST:PORT: $probe"
      fi
      ;;
    *) die "$variable must be an http://, https://, or tcp:// URL: $probe" ;;
  esac
}

probe_ready() {
  probe=$1
  case $probe in
    http://*|https://*)
      wget -q --spider -T 3 "$probe"
      ;;
    tcp://*)
      probe_host=${probe#tcp://}
      probe_port=${probe_host##*:}
      probe_host=${probe_host%:*}
      nc -z -w 2 "$probe_host" "$probe_port"
      ;;
    *) return 1 ;;
  esac
}

wait_ready() {
  probe=$1
  deadline=$(($(date -u '+%s') + health_timeout))

  while ! probe_ready "$probe"; do
    now=$(date -u '+%s')
    [ "$now" -lt "$deadline" ] || return 1
    sleep 1
  done
}

restart_container() {
  docker container restart --timeout "$restart_timeout" -- "$1" >/dev/null
}

# Restart chain: VPN container -> wait ready -> optional sidecar -> wait ready.
# Any failure returns 1 without committing state so the next poll retries the
# whole chain.
restart_vpn_stack() {
  if ! restart_container "$vpn_container"; then
    log ERROR "failed to restart VPN container=$vpn_container; will retry"
    return 1
  fi

  if ! wait_ready "$vpn_probe"; then
    log ERROR "VPN container did not become ready container=$vpn_container probe=$vpn_probe timeout=${health_timeout}s; will retry"
    return 1
  fi

  [ -n "$sidecar_container" ] || return 0

  if ! restart_container "$sidecar_container"; then
    log ERROR "failed to restart sidecar container=$sidecar_container; will retry"
    return 1
  fi

  if ! wait_ready "$sidecar_probe"; then
    log ERROR "sidecar did not rejoin the VPN network namespace container=$sidecar_container probe=$sidecar_probe timeout=${health_timeout}s; will retry"
    return 1
  fi
}
