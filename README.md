# OpenVPN DDNS SOCKS5 Gateway

This project gives you a **SOCKS5 proxy that sends traffic through OpenVPN** with a deployment model that is ready to use on day one. It is built as a thin composition layer around a maintained upstream runtime that already combines **OpenVPN + microsocks**.

## Platform requirement

This project targets a **Linux Docker host** with `/dev/net/tun` available. That requirement matters because the upstream VPN runtime needs direct TUN access.

The design target is simple: **keep a hostname in your OpenVPN client config, including a DDNS hostname, and browse through SOCKS5 over that tunnel**.

## Why this refactor exists

The previous version of this repository tried to solve DDNS by rewriting the `remote` line in `.ovpn` files and restarting OpenVPN with ad hoc shell scripts. That approach was brittle, over-engineered, and already had a broken restart path.

This refactor removes that custom lifecycle entirely:

- **Upstream runtime:** [`binhex/arch-privoxyvpn`](https://github.com/binhex/arch-privoxyvpn)
- **Composition only:** this repo now focuses on Docker Compose, validation, tests, and documentation

## Scope

What this project does now:

- Runs **OpenVPN** using your own custom `.ovpn` client configuration
- Preserves **hostname-based server addressing**, including DDNS hostnames
- Exposes a **SOCKS5 proxy** on port `1080` by default
- Keeps a clean path for future WireGuard work **without implementing WireGuard now**

What it deliberately does **not** do:

- It does not rewrite hostnames to IPs
- It does not implement a custom DDNS watcher
- It does not claim live session migration when a DDNS A record changes

For OpenVPN, the right model is: **keep the hostname in `remote`, reconnect when needed, and let the client resolve the hostname naturally**.

For this project, the practical reconnect contract is even simpler:

- keep the DDNS hostname in the `.ovpn` `remote` line
- set `resolv-retry infinite`
- set `keepalive` (or `ping`/`ping-restart`) so the client notices a dead tunnel quickly

That solves **disconnect -> reconnect -> re-resolve DDNS**, which is the real requirement here.

## Architecture

```text
client app
   │
   ▼
binhex/arch-privoxyvpn
   ├── OpenVPN client
   └── microsocks (SOCKS5)
            │
            ▼
your OpenVPN server (hostname or DDNS hostname)
```

This is intentionally thin:

- the **VPN engine** comes from a maintained upstream project
- the **SOCKS5 runtime** comes from the same maintained upstream image
- this repo owns only the **compose contract, validation, docs, and tests**

See [docs/architecture.md](docs/architecture.md) for the design rationale.

## Quick start

### 1. Prepare your OpenVPN client files

Copy the example profile and replace the placeholders with your own files:

```bash
mkdir -p config/openvpn
cp examples/openvpn/custom.ovpn config/openvpn/custom.ovpn
```

If your `.ovpn` file references files like `ca.crt`, `client.crt`, `client.key`, or `auth-user-pass`, place them in the same `./config/openvpn/` directory unless your config uses inline blocks.

Keep **exactly one** `.ovpn` file in `./config/openvpn/`. The upstream runtime expects one active profile, and this repo validates that contract explicitly.

### 2. Keep the server address as a hostname

Your `remote` line should use a hostname, not a hard-coded IP, for the DDNS use case:

```ovpn
remote vpn.example.com 1194 udp
```

That hostname can be a DDNS record.

For fast recovery after the server IP changes, keep these directives in your `.ovpn` file:

```ovpn
resolv-retry infinite
keepalive 10 60
```

`resolv-retry infinite` helps on reconnect. `keepalive 10 60` is what makes OpenVPN detect a dead tunnel and actually trigger that reconnect.

### 3. Configure the stack

```bash
cp .env.example .env
```

Fill in these values as needed:

- `OPENVPN_CONFIG_DIR=./config`
- `SOCKS5_PORT=1080`
- `SOCKS5_USER` and `SOCKS5_PASSWORD`
- `LAN_NETWORK=<your-lan-cidr>`
- optional `OPENVPN_USER` and `OPENVPN_PASSWORD` if your config expects env-provided credentials

Use this helper if you need a starting point for `LAN_NETWORK`:

```bash
scripts/detect-lan-network.sh
```

### 4. Validate before starting

```bash
make validate
```

This checks:

- exactly one `.ovpn` file exists under `./config/openvpn/`
- at least one `remote` line is present
- common referenced files exist
- the Docker Compose stack renders correctly

### 5. Start the stack

```bash
make up
```

### 6. Watch the logs

```bash
make logs
```

### 7. Test the SOCKS5 proxy

```bash
curl --socks5-hostname 127.0.0.1:1080 \
  --proxy-user 'socks5:change-me' \
  https://ifconfig.me
```

Authentication is enabled by default. Change the example credentials in `.env` before real use.

## Operational notes

### DDNS behavior

This project is designed for **hostname-based OpenVPN configs**.

That means:

- use a hostname in `remote`
- let OpenVPN resolve the hostname
- understand that **existing sessions do not magically switch IPs mid-flight**
- after a DDNS change, recovery happens on reconnect boundaries

So if you care about quicker recovery after the IP changes, your `.ovpn` should include reconnect detection such as:

```ovpn
keepalive 10 60
```

or the equivalent explicit form:

```ovpn
ping 10
ping-restart 60
```

This is cleaner and more maintainable than pinning the hostname to a resolved IP in a wrapper script.

### LAN access to the SOCKS5 port

The upstream image protects the container with firewall rules. To reach the SOCKS5 port from your machine, set `LAN_NETWORK` in `.env` to your host LAN CIDR.

### Future WireGuard support

The current repo is **OpenVPN-only by design**, but the chosen upstream runtime already supports WireGuard in a separate mode. Adding that later would require a separate operator contract, validation path, and documentation.

## Repository layout

```text
.
├── docker-compose.yml
├── .env.example
├── examples/openvpn/
├── docs/
├── scripts/
└── tests/
```

## Validation and testing

Available commands:

```bash
make validate
make smoke
```

- `make validate` checks config and Compose rendering
- `make smoke` runs a runtime contract smoke test that proves the chosen upstream accepts a hostname-based `.ovpn` profile, brings up `tun0`, and can open the upstream SOCKS listener in the local fixture

See [docs/testing.md](docs/testing.md) for details.

## Troubleshooting

### The stack starts but traffic does not pass

Check the VPN logs first:

```bash
docker compose logs vpn
```

Then verify your `remote` hostname and any cert/key/auth files referenced by the `.ovpn` file under `./config/openvpn/`.

If the VPN server is behind DDNS and its IP changed recently, also verify that your `.ovpn` includes `resolv-retry infinite` plus either `keepalive` or `ping-restart`. Without that, OpenVPN may not notice a dead tunnel quickly enough.

### I used an IP address instead of a hostname

That will still work as a plain OpenVPN client config, but it defeats the DDNS use case. The validator warns about this because your stated use case is a floating-IP server.

### My config uses `auth-user-pass`

Both of these are supported:

- put the auth file in `./config/openvpn/` and reference it from your `.ovpn` file
- or set `OPENVPN_USER` and `OPENVPN_PASSWORD` if your upstream config path expects env-based credentials

The env-based credential path is supported by the upstream runtime, but the bundled automated smoke test focuses on certificate-style local fixtures.

### I have more than one `.ovpn` file

Do not leave multiple profiles in `./config/openvpn/`. This repository and the upstream runtime both assume one active OpenVPN profile per stack instance.

## Documentation

- [Architecture](docs/architecture.md)
- [Operations](docs/operations.md)
- [Testing](docs/testing.md)

## License

MIT
