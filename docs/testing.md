# Testing

## Validation

Run the repository checks first:

```bash
make validate-repo
```

This validates:

- OpenVPN source profile contract (`examples/openvpn/custom.ovpn`)
- WireGuard source profile contract (`examples/wireguard/wg0.conf`)
- Docker Compose rendering with image-based watcher inputs

To validate your own configs:

```bash
make validate-config              # defaults to OpenVPN
make validate-config VPN_TYPE=wireguard
```

## Smoke test

```bash
make smoke
```

This runs smoke tests for both protocols:

- `make smoke-openvpn` — tests the OpenVPN render/restart flow
- `make smoke-wireguard` — tests the WireGuard render/restart flow

The smoke tests are intentionally lightweight. They do not require a real VPN server. Instead they verify the DDNS-specific behavior this repository owns:

- the renderer rewrites a hostname-based `remote` (OpenVPN) or `Endpoint` (WireGuard) to the current IP
- the renderer rewrites relative certificate/key/auth paths to absolute container paths (OpenVPN only)
- the watcher detects an IP change
- the watcher restarts the configured Gluetun container name

## What is not covered automatically

- a full tunnel bring-up against a real VPN server
- host-specific `/dev/net/tun` behavior
- firewall behavior outside the compose stack
- WireGuard key exchange and handshake

Those checks should be done manually on the target Linux Docker host after `docker compose up -d`.

## GitHub Actions

- `CI` runs validation (`make validate-repo`) and smoke checks (`make smoke`)
- `publish-watcher` builds the watcher image and pushes it to GHCR
- image publishing is limited to watcher-related changes on `main`
- CI triggers on changes to: `docker-compose.yml`, `.env.example`, `scripts/**`, `tests/**`, `examples/**`, `Makefile`
