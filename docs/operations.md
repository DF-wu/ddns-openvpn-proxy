# Operations Guide

## Prerequisites

- Docker Engine
- Docker Compose v2
- a Linux host or VM with `/dev/net/tun`
- access to an OpenVPN server
- a custom OpenVPN client config under `./config/openvpn/*.ovpn`

## Files expected in `./config/openvpn/`

At minimum:

- one `.ovpn` client profile

Only keep **one** `.ovpn` profile in this directory for each stack instance.

Sometimes also:

- `ca.crt`
- `client.crt`
- `client.key`
- `ta.key`
- `auth.txt`

If your `.ovpn` file uses inline `<ca>`, `<cert>`, or `<key>` blocks, you may only need the `.ovpn` file itself.

## Start the stack

```bash
make validate
make up
```

## Stop the stack

```bash
make down
```

## Read logs

```bash
make logs
```

Or inspect the service directly:

```bash
docker compose logs vpn
```

## Validate SOCKS5 access

```bash
curl --socks5-hostname 127.0.0.1:1080 \
  --proxy-user "$SOCKS5_USER:$SOCKS5_PASSWORD" \
  https://ifconfig.me
```

## Updating your DDNS record

No repo change is required.

Keep your `.ovpn` file pointing to a hostname such as:

```ovpn
remote vpn.example.com 1194 udp
```

For fast reconnect behavior after the DDNS target changes, also keep these directives in the client config:

```ovpn
resolv-retry infinite
keepalive 10 60
```

When the A record changes, the OpenVPN client will observe the new endpoint on reconnect boundaries.

## LAN access to the SOCKS5 port

The upstream image protects the container with firewall rules. To reach the SOCKS5 port from your machine, set `LAN_NETWORK` in `.env` to your local CIDR.

Helper:

```bash
scripts/detect-lan-network.sh
```

## Common mistakes

### Hard-coding an IP in `remote`

That works as a plain OpenVPN client configuration, but it defeats the DDNS requirement.

### Mounting the wrong path

The upstream runtime expects your OpenVPN files under `/config/openvpn/`, which means this repo expects them under `./config/openvpn/` on the host.

### Expecting live session migration on DNS change

DDNS helps a reconnect land on the right host. It does not turn an existing OpenVPN session into a live-moving connection.
