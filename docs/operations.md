# Operations

## Prepare the source config

Place your OpenVPN profile and any referenced files under `config/openvpn/`.

Example:

```bash
mkdir -p config/openvpn
cp examples/openvpn/custom.ovpn config/openvpn/client.ovpn
```

Your source config should keep the hostname-based remote line, for example:

```ovpn
remote vpn.example.com 1194
```

## Configure the stack

```bash
cp .env.example .env
```

Recommended values:

- `DDNS_HOSTNAME`: set this explicitly if you want the watcher to ignore any alternate remote lines in the config
- `DDNS_POLL_SECONDS=60`: reasonable default for home DDNS
- `DDNS_COOLDOWN_SECONDS=15`: prevents restart bursts if DNS flaps
- `HTTP_PROXY_PORT=8888`
- `GLUETUN_CONTAINER_NAME=ddns-openvpn-proxy`

## Start and stop

```bash
make up
make down
```

## Logs

```bash
make logs
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

### Proxy port is reachable but traffic does not pass

That usually means the HTTP proxy is up but the tunnel is not healthy. Inspect Gluetun logs first.

### Docker socket exposure

The watcher needs `/var/run/docker.sock` so it can restart Gluetun. That is a privileged capability. Keep this stack on a host you control and do not expose the watcher container externally.
