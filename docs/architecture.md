# Architecture

## Goal

Use Gluetun as the OpenVPN client runtime, but restore DDNS behavior by resolving the hostname outside Gluetun and restarting the container when the resolved IP changes.

## Why this exists

For custom OpenVPN configs, Gluetun's documented flow expects an IP-based remote target instead of live hostname resolution. That is a good default for DNS-leak prevention, but it means a DDNS hostname change is not picked up automatically by the running tunnel.

The workaround here is intentional and narrow:

1. keep the source `.ovpn` hostname-based for operator clarity
2. render a runtime `.ovpn` with the current IPv4
3. restart Gluetun when the DDNS hostname resolves differently

## Services

### `ddns-init`

- resolves the effective hostname once at startup
- renders `state/openvpn/current.ovpn`
- seeds `state/ddns/last-ip`

This prevents a startup race where Gluetun would otherwise boot before the rendered config exists.

### `gluetun`

- runs the OpenVPN client using `OPENVPN_CUSTOM_CONFIG`
- exposes Gluetun's built-in HTTP proxy on port `8888`
- is restarted by the watcher when the rendered remote IP changes

### `ddns-watcher`

- polls the hostname on a fixed interval
- compares the latest IPv4 with `state/ddns/last-ip`
- rewrites `state/openvpn/current.ovpn` when the IP changes
- restarts the Gluetun container through the Docker socket

## Data flow

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
        └── HTTP proxy :8888
```

## Why restart the whole container

The user explicitly asked to restart Gluetun when the DDNS target changes. Doing a real container restart also avoids relying on undocumented or insufficiently proven config-reload behavior inside a live Gluetun process. The tradeoff is that the watcher needs Docker socket access.

## Why referenced file paths are normalized

Gluetun rewrites the custom OpenVPN config internally, so relative paths for directives like `ca`, `cert`, `key`, `tls-auth`, `tls-crypt`, and `auth-user-pass` are unsafe. The renderer converts those paths to absolute container paths under `/gluetun/source/openvpn/` so the referenced files remain valid after Gluetun loads the rendered config.

## Scope limits

- IPv4 only in v1
- single source profile by default
- HTTP proxy only
- Docker socket access is required for `ddns-watcher`
- no attempt to hot-swap the IP without reconnecting the tunnel
