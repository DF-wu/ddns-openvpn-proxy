# DDNS-aware Gluetun OpenVPN Proxy

This repository does one thing: run a custom **OpenVPN client inside Gluetun**, expose Gluetun's built-in **HTTP proxy**, and automatically recover when your DDNS hostname resolves to a new IP.

The source `.ovpn` stays hostname-based. A small sidecar renders `state/openvpn/current.ovpn` with the current IPv4, and when that IP changes it **restarts the Gluetun container** so OpenVPN reconnects using the updated runtime config.

## What this repository does

- keeps the source `.ovpn` readable and DDNS-friendly
- renders a runtime `.ovpn` with the current IPv4 target
- starts Gluetun from that rendered config
- polls the DDNS hostname for IP changes
- restarts Gluetun when the rendered remote IP changes
- exposes an HTTP proxy on port `8888`

## Quick start

1. Put your OpenVPN files under `./config/openvpn/`.
2. Copy the env file and adjust values.

```bash
cp .env.example .env
```

3. Validate the config.

```bash
make validate
```

4. Start the stack.

```bash
make up
```

5. Watch logs.

```bash
make logs
```

6. Use the HTTP proxy.

```bash
curl -x http://127.0.0.1:8888 https://ifconfig.me
```

## Required files

Keep exactly one source `.ovpn` file under `./config/openvpn/` unless you explicitly point `OPENVPN_SOURCE_CONFIG` at another file. Any referenced cert/key/auth files should live beside it unless they are inlined.

The source config keeps the hostname:

```ovpn
remote vpn.example.com 1194
```

The watcher resolves that hostname and writes the runtime file to:

```text
./state/openvpn/current.ovpn
```

## Key environment variables

- `OPENVPN_CONFIG_DIR=./config`
- `STATE_DIR=./state`
- `DDNS_HOSTNAME=vpn.example.com` (optional; if blank, parsed from the `.ovpn` remote line)
- `DDNS_POLL_SECONDS=60`
- `DDNS_COOLDOWN_SECONDS=15`
- `HTTP_PROXY_PORT=8888`
- `GLUETUN_IMAGE=qmcgaw/gluetun:latest`
- `GLUETUN_CONTAINER_NAME=ddns-openvpn-proxy`

## How the DDNS refresh works

1. `ddns-init` resolves the hostname and renders `state/openvpn/current.ovpn`.
2. `gluetun` starts from that rendered config.
3. `ddns-watcher` keeps polling the hostname.
4. When the IPv4 address changes, it re-renders the config and restarts the Gluetun container:

```text
docker restart ddns-openvpn-proxy
```

That makes Gluetun start again from the updated `state/openvpn/current.ovpn`, which is the whole point of this repository.

## Runtime requirements

- Linux host with `/dev/net/tun`
- Docker and Docker Compose
- `/var/run/docker.sock` mounted into `ddns-watcher` so it can restart Gluetun

## Commands

```bash
make validate
make up
make down
make logs
make smoke
```

## Documentation

- [Architecture](docs/architecture.md)
- [Operations](docs/operations.md)
- [Testing](docs/testing.md)
