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
- `HTTPPROXY_USER` and `HTTPPROXY_PASSWORD` if you want HTTP proxy authentication
- `HTTPPROXY_STEALTH=off` unless you specifically need stealth mode
- `SOCKS5_PROXY_PORT=1080`
- `SOCKS5_USER` and `SOCKS5_PASSWORD` if you want SOCKS5 authentication; set both or neither
- `VPROXY_IMAGE=ghcr.io/0x676e67/vproxy:latest`
- `GLUETUN_CONTAINER_NAME=ddns-openvpn-proxy`

The HTTP and SOCKS5 proxies are enabled simultaneously. Their credentials are
independent, so reusing the same values is optional rather than required.

For two authenticated proxies:

```dotenv
HTTP_PROXY_PORT=8888
HTTPPROXY_USER=http-user
HTTPPROXY_PASSWORD=replace-with-a-strong-http-password

SOCKS5_PROXY_PORT=1080
SOCKS5_USER=socks-user
SOCKS5_PASSWORD=replace-with-a-strong-socks-password
```

For an unauthenticated SOCKS5 listener, leave both SOCKS5 values empty. Never
set only one: `make validate-compose` rejects that configuration, and the
sidecar also exits instead of silently opening an unauthenticated proxy if the
preflight validation is bypassed.

```dotenv
SOCKS5_USER=
SOCKS5_PASSWORD=
```

The Compose port mappings bind to all host interfaces by default. Use host and
network firewall rules in addition to proxy authentication, especially if the
host has a public address. Do not expose either proxy without authentication to
the public Internet.

## Pull and start

Deploy after the `publish-watcher` workflow finishes for the commit you want to run.

```bash
docker compose pull
docker compose up -d
```

Verify that all long-running services are running:

```bash
docker compose ps gluetun vproxy ddns-watcher
```

`vproxy` may briefly start after Gluetun because `depends_on` controls startup
order, not VPN health. If it is repeatedly restarting, inspect its logs before
testing the listener.

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
- `vproxy` remaining in the running state with its SOCKS5 listener on `:1080`
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

### Test both proxies

Use the same destination for both tests. Once the VPN is healthy, both commands
should report the VPN exit address:

```bash
curl -x http://127.0.0.1:8888 https://ifconfig.me
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
```

For authenticated listeners:

```bash
curl -x http://127.0.0.1:8888 -U HTTP_USER:HTTP_PASSWORD https://ifconfig.me
curl --socks5-hostname 127.0.0.1:1080 -U SOCKS_USER:SOCKS_PASSWORD https://ifconfig.me
```

Prefer `--socks5-hostname` over `--socks5`: it asks the SOCKS5 server to resolve
the destination hostname and avoids a client-side DNS lookup outside the proxy
path.

To connect from another machine, replace `127.0.0.1` with the Docker host's IP
address and allow only the required source network through the host firewall.

### HTTP proxy port is reachable but traffic does not pass

That usually means the HTTP proxy is up but the tunnel is not healthy. Inspect Gluetun logs first.

### Proxy authentication fails

If you enabled `HTTPPROXY_USER` and `HTTPPROXY_PASSWORD`, confirm your client is sending credentials to the proxy. For curl, use `-U USER:PASSWORD`.

### SOCKS5 sidecar is restarting

Read the sidecar log:

```bash
docker compose ps vproxy
docker compose logs vproxy
```

If the log reports that `SOCKS5_USER` and `SOCKS5_PASSWORD` must both be set or
both be empty, correct `.env` and recreate the sidecar:

```bash
docker compose up -d --force-recreate vproxy
```

This failure is intentional and fail-closed. It prevents a typo in one
credential from producing an unauthenticated proxy.

### SOCKS5 sidecar is running but port 1080 is unreachable

Confirm the rendered Compose contract:

```bash
docker compose config | grep -E 'network_mode: service:gluetun|target: 1080|FIREWALL_INPUT_PORTS'
```

The output must show that `vproxy` shares `service:gluetun`, TCP container port
`1080` is published, and Gluetun permits `FIREWALL_INPUT_PORTS: "1080"`. The
firewall setting is required because Gluetun cannot automatically discover a
listener launched by a sidecar.

Then confirm the listener and check both relevant logs:

```bash
docker compose exec gluetun sh -c 'netstat -lnt 2>/dev/null | grep :1080'
docker compose logs gluetun vproxy
```

`SOCKS5_PROXY_PORT` is the host-side port only. If you set it to `2080`, clients
connect to host port `2080`, while `vproxy` and Gluetun's firewall continue to
use container port `1080`.

### SOCKS5 UDP does not work

This deployment publishes TCP only and supports SOCKS5 `CONNECT`. It does not
publish the dynamically allocated UDP listener used by SOCKS5 `UDP ASSOCIATE`.
Applications that require UDP through SOCKS5 are outside the current supported
contract.

### Docker socket exposure

The watcher needs `/var/run/docker.sock` so it can restart Gluetun. That is a privileged capability. Keep this stack on a host you control and do not expose the watcher container externally.

### WireGuard-specific: Gluetun reports "Endpoint is not an IP"

This means the rendered WireGuard config still contains a hostname in the `Endpoint` line. Check that `ddns-init` ran successfully and that `state/wireguard/wg0.conf` contains an IP address. If the file looks correct, restart the stack:

```bash
docker compose down --remove-orphans
docker compose up -d
```
