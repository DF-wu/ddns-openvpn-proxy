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
- `vproxy` sharing Gluetun's network namespace
- the Gluetun firewall allowing the fixed SOCKS5 container port `1080`
- SOCKS5 credentials being passed into the sidecar
- the complete multi-line `vproxy` startup command surviving Compose rendering
- fail-closed handling when only one SOCKS5 credential is configured
- the selected `.env` not containing only one of the two SOCKS5 credentials

The Compose checks inspect the rendered configuration, not just YAML syntax.
This distinction matters because `docker compose config -q` can accept a valid
file even when a scalar command has been split before the `vproxy` executable.

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
- live HTTP/SOCKS5 proxy handshakes and authenticated requests through a real tunnel

Those checks should be done manually on the target Linux Docker host after `docker compose up -d`.

## Manual proxy verification

After the real VPN tunnel is healthy, verify that all long-running services are
running:

```bash
docker compose ps gluetun vproxy ddns-watcher
```

Test HTTP and SOCKS5 against the same address service:

```bash
curl -x http://127.0.0.1:8888 https://ifconfig.me
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
```

Both responses should contain the VPN exit address. If authentication is
enabled, test each proxy with its own credentials:

```bash
curl -x http://127.0.0.1:8888 -U HTTP_USER:HTTP_PASSWORD https://ifconfig.me
curl --socks5-hostname 127.0.0.1:1080 -U SOCKS_USER:SOCKS_PASSWORD https://ifconfig.me
```

Also test a rejected request with missing or incorrect credentials. This
confirms that a listener intended to be private is not accepting anonymous
connections.

The supported SOCKS5 integration path is TCP `CONNECT`. UDP `ASSOCIATE` is not
part of this deployment's test contract because the required dynamic UDP
listener is not published by Compose.

## GitHub Actions

- `CI` runs validation (`make validate-repo`) and smoke checks (`make smoke`)
- `publish-watcher` builds the watcher image and pushes it to GHCR
- image publishing is limited to watcher-related changes on `main`
- CI triggers on changes to: `docker-compose.yml`, `.env.example`, `scripts/**`, `tests/**`, `examples/**`, `Makefile`
