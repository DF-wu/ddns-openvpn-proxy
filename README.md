# DDNS-aware Gluetun OpenVPN Proxy

This repository packages one deployable pattern:

- use the official `qmcgaw/gluetun` image for OpenVPN
- use a small watcher image from GHCR for DDNS rendering and restart logic
- deploy with pulled images, environment variables, and local OpenVPN files only

The source `.ovpn` stays hostname-based. The watcher renders `state/openvpn/current.ovpn` with the current IPv4, then restarts Gluetun when that IP changes.

## What you deploy

- `gluetun` from the official upstream image
- `ddns-init` from the watcher image to render the first runtime config
- `ddns-watcher` from the same watcher image to poll DDNS and restart Gluetun

## Quick start

1. Put your OpenVPN files under `./config/openvpn/`.
2. Copy the env file.

```bash
cp .env.example .env
```

3. Adjust `.env`.
4. Validate the local config.

```bash
make validate
```

5. Pull the images.

```bash
docker compose pull
```

6. Start the stack.

```bash
docker compose up -d
```

7. Watch logs.

```bash
docker compose logs -f gluetun ddns-watcher
```

8. Test the HTTP proxy.

```bash
curl -x http://127.0.0.1:8888 https://ifconfig.me
```

## Required local files

Keep exactly one source `.ovpn` file under `./config/openvpn/` unless you set `OPENVPN_SOURCE_CONFIG` explicitly. Any referenced cert/key/auth files should live beside it unless they are inlined.

The source profile should keep the hostname-based `remote` line:

```ovpn
remote vpn.example.com 1194
```

The watcher writes the rendered runtime profile to:

```text
./state/openvpn/current.ovpn
```

## Key environment variables

- `WATCHER_IMAGE=ghcr.io/df-wu/ddns-openvpn-proxy-watcher:latest`
- `GLUETUN_IMAGE=qmcgaw/gluetun:latest`
- `GLUETUN_CONTAINER_NAME=ddns-openvpn-proxy`
- `OPENVPN_CONFIG_DIR=./config`
- `STATE_DIR=./state`
- `DDNS_HOSTNAME=vpn.example.com`
- `DDNS_POLL_SECONDS=60`
- `DDNS_COOLDOWN_SECONDS=15`
- `HTTP_PROXY_PORT=8888`

## How recovery works

1. `ddns-init` resolves the hostname and renders `state/openvpn/current.ovpn`.
2. `gluetun` starts from that rendered config.
3. `ddns-watcher` polls the hostname.
4. When the IPv4 changes, it rewrites the runtime config and restarts the Gluetun container.

```text
docker restart ddns-openvpn-proxy
```

## Runtime requirements

- Linux host with `/dev/net/tun`
- Docker and Docker Compose
- `/var/run/docker.sock` mounted into `ddns-watcher`

## CI and publishing

- `CI` runs `make validate-repo` and `make smoke`
- `publish-watcher` builds and publishes the watcher image to GHCR
- the publish workflow only runs on `main` when watcher-related files change
- the watcher image is built for `linux/amd64` to keep CI fast and cheap

## Repository commands

```bash
make validate
make smoke
```

## Documentation

- [Architecture](docs/architecture.md)
- [Operations](docs/operations.md)
- [Testing](docs/testing.md)
