# Architecture

## Goal

Use the official Gluetun image for the VPN client and a separate watcher image for DDNS rendering and restart orchestration, supporting both OpenVPN and WireGuard.

## Why this exists

For custom VPN configs, Gluetun expects an IP-based remote target at runtime. A DDNS hostname can change later, so the running tunnel would keep using the old IP unless something outside Gluetun updates the runtime profile and restarts the container.

This repository does that in three steps:

1. keep the source config hostname-based
2. render a runtime config with the current IPv4
3. restart Gluetun when the hostname resolves differently

## Supported protocols

| Protocol | Source config | Runtime config | Hostname field |
|----------|---------------|----------------|----------------|
| OpenVPN  | `.ovpn`       | `state/openvpn/current.ovpn` | `remote hostname port` |
| WireGuard| `.conf`       | `state/wireguard/wg0.conf`   | `Endpoint = hostname:port` |

## Services

### `ddns-init`

- runs from the published watcher image
- resolves the hostname once at startup
- renders the runtime config (OpenVPN or WireGuard, depending on `VPN_TYPE`)
- seeds `state/ddns/last-ip`

This prevents Gluetun from starting before the runtime config exists.

### `gluetun`

- runs the VPN client using the protocol selected by `VPN_TYPE`
- OpenVPN: uses `OPENVPN_CUSTOM_CONFIG`
- WireGuard: uses `WIREGUARD_CUSTOM_CONFIG`
- exposes Gluetun's built-in HTTP proxy on port `8888`
- is restarted by the watcher when the rendered remote IP changes

### `ddns-watcher`

- runs from the same published watcher image
- polls the hostname on a fixed interval
- compares the latest IPv4 with `state/ddns/last-ip`
- rewrites the runtime config when the IP changes
- restarts the Gluetun container through the Docker socket

### `vproxy`

- runs the `ghcr.io/0x676e67/vproxy` image as a sidecar
- shares the Gluetun container's network namespace via `network_mode: service:gluetun`
- exposes a SOCKS5 proxy on port `1080` that routes through the VPN tunnel
- optional username/password authentication

## Data flow

### OpenVPN

```text
source .ovpn with hostname
        │
        ▼
  ddns-init / ddns-watcher
        │ resolve hostname
        ▼
state/openvpn/current.ovpn
        │
        ▼
     Gluetun
        │
        ├── OpenVPN tunnel
        ├── HTTP proxy :8888
        └── SOCKS5 proxy :1080
```

### WireGuard

```text
source .conf with hostname in Endpoint
        │
        ▼
  ddns-init / ddns-watcher
        │ resolve hostname
        ▼
state/wireguard/wg0.conf
        │
        ▼
     Gluetun
        │
        ├── WireGuard tunnel
        ├── HTTP proxy :8888
        └── SOCKS5 proxy :1080
```

## Multi-protocol dispatch layer

The core logic lives in `scripts/vpn-ddns-lib.sh`. A `case` statement dispatches to OpenVPN or WireGuard implementations based on the `VPN_TYPE` env var:

```bash
vpn_render_config() {
  local vpn_type="${VPN_TYPE:-$(detect_vpn_type)}"
  case "$vpn_type" in
    openvpn)   render_openvpn_config "$@" ;;
    wireguard) render_wireguard_config "$@" ;;
  esac
}
```

This keeps the protocol-specific code isolated and makes adding a third protocol straightforward.

## Why the watcher is a separate image

The target host should only need pulled images plus `.env` and local VPN files. Publishing the watcher separately to GHCR keeps deployment simple and keeps local machines out of the build path.

## Why restart the whole container

Restarting Gluetun matches the deployment requirement directly and avoids relying on in-process config reload behavior.

## Why referenced file paths are normalized (OpenVPN only)

Gluetun rewrites the custom OpenVPN config internally. Relative paths for directives like `ca`, `cert`, `key`, `tls-auth`, `tls-crypt`, and `auth-user-pass` are unsafe, so the renderer converts them to absolute container paths under `/gluetun/source/openvpn/`.

WireGuard configs use inlined keys (no external file references), so no path normalization is needed.

## Scope limits

- IPv4 only
- single source profile by default
- Docker socket access is required for `ddns-watcher`
- no attempt to hot-swap the IP without reconnecting the tunnel

## Extension point: adding a new VPN type

To add support for a third VPN protocol:

1. Implement three functions in `scripts/vpn-ddns-lib.sh`:
   - `detect_<protocol>_source_config` — find the source config file
   - `get_<protocol>_remote_host` — extract the hostname from the config
   - `render_<protocol>_config` — replace hostname with IP in the config

2. Add a `case` branch in `vpn_detect_source_config`, `vpn_get_remote_host`, and `vpn_render_config`

3. Create `scripts/validate-<protocol>-config.sh`

4. Update `docker-compose.yml` to mount the new protocol's source directory and set the appropriate `GLUETUN_*` env var

5. Update `.env.example` with new protocol-specific variables

6. Add an example config under `examples/<protocol>/`

7. Add a smoke test case in `tests/e2e/smoke.sh`
