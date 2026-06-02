# Operations

## Prepare the source config

### OpenVPN

Place your OpenVPN profile and any referenced files under `config/openvpn/`.

```bash
mkdir -p config/openvpn
cp examples/openvpn/custom.ovpn config/openvpn/client.ovpn
```

The source profile should keep the hostname-based remote line:

```ovpn
remote vpn.example.com 1194
```

### WireGuard

Place your WireGuard profile under `config/wireguard/`.

```bash
mkdir -p config/wireguard
cp examples/wireguard/wg0.conf config/wireguard/wg0.conf
```

The source profile should keep the hostname-based Endpoint line:

```conf
Endpoint = vpn.example.com:51820
```

## Configure the stack

```bash
cp .env.example .env
```

Set at least these values:

- `VPN_TYPE` — `openvpn` or `wireguard`
- `WATCHER_IMAGE`
- `GLUETUN_IMAGE`
- `GLUETUN_CONTAINER_NAME`
- `DDNS_HOSTNAME` if you do not want it parsed from the source profile

Recommended values:

- `VPN_TYPE=openvpn`
- `WATCHER_IMAGE=ghcr.io/df-wu/ddns-openvpn-proxy-watcher:latest`
- `DDNS_POLL_SECONDS=60`
- `DDNS_COOLDOWN_SECONDS=15`
- `DDNS_INIT_RETRY_SECONDS=5`
- `DDNS_INIT_MAX_ATTEMPTS=0` to keep retrying until the first render succeeds
- `HTTP_PROXY_PORT=8888`
- `HTTPPROXY_USER` and `HTTPPROXY_PASSWORD` if you want proxy auth
- `HTTPPROXY_STEALTH=off` unless you specifically need stealth mode
- `SOCKS5_PROXY_PORT=1080`
- `SOCKS5_USER` and `SOCKS5_PASSWORD` if you want SOCKS5 auth
- `VPROXY_IMAGE=ghcr.io/0x676e67/vproxy:latest`
- `GLUETUN_CONTAINER_NAME=ddns-openvpn-proxy`

## Pull and start

Deploy after the `publish-watcher` workflow finishes for the commit you want to run.

```bash
docker compose pull
docker compose up -d
```

If the watcher package is private on GHCR, log in first:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

To stop the stack:

```bash
docker compose down --remove-orphans
```

## Logs

```bash
docker compose logs -f gluetun vproxy ddns-watcher
```

You should see:

- `ddns-init` logging the resolved IP and rendered config path
- `gluetun` starting from the runtime config
- `ddns-watcher` logging `IP unchanged` until a DDNS update happens

If DNS is not ready when the stack starts, `ddns-init` now keeps retrying instead of failing the stack immediately.

When the DDNS target changes, expected watcher flow is:

1. detect new IP
2. re-render the runtime config
3. call `docker restart ddns-openvpn-proxy`

## Runtime artifacts

- `state/ddns/last-ip`
- `state/openvpn/current.ovpn` (OpenVPN)
- `state/wireguard/wg0.conf` (WireGuard)

These are intentionally ignored by git.

## Troubleshooting

### Gluetun fails at startup

Check that the runtime config exists:

- OpenVPN: `state/openvpn/current.ovpn`
- WireGuard: `state/wireguard/wg0.conf`

Verify the source config contains the expected hostname field:

- OpenVPN: `remote` line
- WireGuard: `Endpoint` line

### ddns-init keeps retrying forever

That usually means one of two things:

- the DDNS hostname cannot be resolved from the container
- the source config or referenced files are mounted incorrectly

If you want a hard failure instead of infinite retry, set `DDNS_INIT_MAX_ATTEMPTS` to a non-zero value.

### Watcher never detects changes

Check DNS resolution from the watcher container:

```bash
docker compose exec ddns-watcher sh
```

Then verify the hostname resolves and inspect `state/ddns/last-ip`.

### The target machine tries to build an image

It should not. The compose file uses `WATCHER_IMAGE`, not `build:`. Run `docker compose config` and confirm both `ddns-init` and `ddns-watcher` point at the same pulled image.

### The target machine is not amd64

The published watcher image is `linux/amd64` only. If your host is `arm64`, either change the publish workflow to multi-arch or deploy on an amd64 machine.

### Proxy port is reachable but traffic does not pass

That usually means the HTTP proxy is up but the tunnel is not healthy. Inspect Gluetun logs first.

### Proxy authentication fails

If you enabled `HTTPPROXY_USER` and `HTTPPROXY_PASSWORD`, confirm your client is sending credentials to the proxy. For curl, use `-U USER:PASSWORD`.

### SOCKS5 proxy testing

Test the SOCKS5 proxy:

```bash
curl --socks5 127.0.0.1:1080 https://ifconfig.me
```

If you enabled SOCKS5 authentication:

```bash
curl --socks5 127.0.0.1:1080 -U USER:PASSWORD https://ifconfig.me
```

### Docker socket exposure

The watcher needs `/var/run/docker.sock` so it can restart Gluetun. That is a privileged capability. Keep this stack on a host you control and do not expose the watcher container externally.

### WireGuard-specific: Gluetun reports "Endpoint is not an IP"

This means the rendered WireGuard config still contains a hostname in the `Endpoint` line. Check that `ddns-init` ran successfully and that `state/wireguard/wg0.conf` contains an IP address. If the file looks correct, restart the stack:

```bash
docker compose down --remove-orphans
docker compose up -d
```
