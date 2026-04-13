# Architecture

## Goal

Use the official Gluetun image for the OpenVPN client and a separate watcher image for DDNS rendering and restart orchestration.

## Why this exists

For custom OpenVPN configs, Gluetun expects an IP-based remote target at runtime. A DDNS hostname can change later, so the running tunnel would keep using the old IP unless something outside Gluetun updates the runtime profile and restarts the container.

This repository does that in three steps:

1. keep the source `.ovpn` hostname-based
2. render a runtime `.ovpn` with the current IPv4
3. restart Gluetun when the hostname resolves differently

## Services

### `ddns-init`

- runs from the published watcher image
- resolves the hostname once at startup
- renders `state/openvpn/current.ovpn`
- seeds `state/ddns/last-ip`

This prevents Gluetun from starting before the runtime config exists.

### `gluetun`

- runs the OpenVPN client using `OPENVPN_CUSTOM_CONFIG`
- exposes Gluetun's built-in HTTP proxy on port `8888`
- is restarted by the watcher when the rendered remote IP changes

### `ddns-watcher`

- runs from the same published watcher image
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

## Why the watcher is a separate image

The target host should only need pulled images plus `.env` and local OpenVPN files. Publishing the watcher separately to GHCR keeps deployment simple and keeps local machines out of the build path.

## Why restart the whole container

Restarting Gluetun matches the deployment requirement directly and avoids relying on in-process config reload behavior.

## Why referenced file paths are normalized

Gluetun rewrites the custom OpenVPN config internally. Relative paths for directives like `ca`, `cert`, `key`, `tls-auth`, `tls-crypt`, and `auth-user-pass` are unsafe, so the renderer converts them to absolute container paths under `/gluetun/source/openvpn/`.

## Scope limits

- IPv4 only
- single source profile by default
- HTTP proxy only
- Docker socket access is required for `ddns-watcher`
- no attempt to hot-swap the IP without reconnecting the tunnel
