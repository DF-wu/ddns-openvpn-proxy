# Operations

## Prepare the source config

Place your OpenVPN profile and any referenced files under `config/openvpn/`.

Example:

```bash
mkdir -p config/openvpn
cp examples/openvpn/custom.ovpn config/openvpn/client.ovpn
```

The source profile should keep the hostname-based remote line:

```ovpn
remote vpn.example.com 1194
```

## Configure the stack

```bash
cp .env.example .env
```

Set at least these values:

- `WATCHER_IMAGE`
- `GLUETUN_IMAGE`
- `GLUETUN_CONTAINER_NAME`
- `DDNS_HOSTNAME` if you do not want it parsed from the source profile

Recommended values:

- `WATCHER_IMAGE=ghcr.io/df-wu/ddns-openvpn-proxy-watcher:latest`
- `DDNS_POLL_SECONDS=60`
- `DDNS_COOLDOWN_SECONDS=15`
- `HTTP_PROXY_PORT=8888`
- `GLUETUN_CONTAINER_NAME=ddns-openvpn-proxy`

## Pull and start

```bash
docker compose pull
docker compose up -d
```

To stop the stack:

```bash
docker compose down --remove-orphans
```

## Logs

```bash
docker compose logs -f gluetun ddns-watcher
```

You should see:

- `ddns-init` logging the resolved IP and rendered config path
- `gluetun` starting from `/gluetun/state/openvpn/current.ovpn`
- `ddns-watcher` logging `IP unchanged` until a DDNS update happens

When the DDNS target changes, expected watcher flow is:

1. detect new IP
2. re-render the runtime config
3. call `docker restart ddns-openvpn-proxy`

## Runtime artifacts

- `state/ddns/last-ip`
- `state/openvpn/current.ovpn`

These are intentionally ignored by git.

## Troubleshooting

### Gluetun fails at startup

Check that `state/openvpn/current.ovpn` exists and that the source config contains at least one valid `remote` line.

### Watcher never detects changes

Check DNS resolution from the watcher container:

```bash
docker compose exec ddns-watcher sh
```

Then verify the hostname resolves and inspect `state/ddns/last-ip`.

### The target machine tries to build an image

It should not. The compose file uses `WATCHER_IMAGE`, not `build:`. Run `docker compose config` and confirm both `ddns-init` and `ddns-watcher` point at the same pulled image.

### Proxy port is reachable but traffic does not pass

That usually means the HTTP proxy is up but the tunnel is not healthy. Inspect Gluetun logs first.

### Docker socket exposure

The watcher needs `/var/run/docker.sock` so it can restart Gluetun. That is a privileged capability. Keep this stack on a host you control and do not expose the watcher container externally.
