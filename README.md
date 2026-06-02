# DDNS OpenVPN Proxy

A Docker Compose stack that solves the DDNS problem for VPN tunnels. It keeps your source config hostname-based, renders a runtime config with the current IPv4, and restarts the VPN client when that IP changes.

Supported protocols: **OpenVPN** (.ovpn) and **WireGuard** (.conf).

---

## The Problem

When a VPN server sits behind a dynamic DNS hostname, its IP can change without warning. Most VPN clients read the remote address once at startup and never look again. If the IP changes, the tunnel stays pointed at the old address until someone manually restarts the client.

This stack automates that whole cycle: detect, render, restart.

---

## Architecture

### Four-service pipeline

```
source config (hostname-based)
        │
        ▼
   ddns-init ── resolves hostname
        │       renders runtime config
        │       seeds last-ip file
        ▼
     gluetun ── reads runtime config
        │       establishes VPN tunnel
        │       exposes HTTP proxy on :8888
        ▼
    vproxy ──── shares gluetun network
        │       exposes SOCKS5 proxy on :1080
        ▼
 ddns-watcher ── polls hostname periodically
                compares with last-ip
                re-renders config on change
                restarts gluetun container
```

### Why four services instead of one

**Gluetun is already solved.** The `qmcgaw/gluetun` image handles OpenVPN, WireGuard, firewall rules, HTTP proxying, and health checks. Reimplementing any of that would be a bug farm. This stack treats Gluetun as a black-box tunnel service and adds only the DDNS orchestration it does not provide.

**Init and watcher are separate lifecycles.** `ddns-init` is a one-shot job that must finish before Gluetun starts. `ddns-watcher` is a long-running daemon that polls forever. Docker Compose can express this with `depends_on` conditions, but only if they are separate services.

**The watcher image is published, not built locally.** Both `ddns-init` and `ddns-watcher` run the same small Alpine-based image from GHCR. Your deployment machine only needs Docker, a `.env` file, and your source VPN config. No local build step, no Docker Compose `build:` blocks, no drift between CI and production.

### Why restart the whole container

Gluetun does not reliably reload a custom config in-process. A container restart is unambiguous: the new process reads the new file from a clean state. The restart cost is a few seconds of downtime, which is acceptable for most DDNS scenarios and far simpler than signal-based reloads.

### Why OpenVPN paths are normalized

OpenVPN configs often reference external files:

```ovpn
ca ca.crt
cert client.crt
key client.key
```

Gluetun copies the runtime config internally, so relative paths break. The renderer converts every relative `ca`, `cert`, `key`, `tls-auth`, `tls-crypt`, and `auth-user-pass` path to an absolute path under `/gluetun/source/openvpn/`. WireGuard does not need this because keys are inlined.

### Why IPv4 only

Gluetun's custom-config path only supports IPv4 endpoints for the protocols it wraps. IPv6 and dual-stack endpoints are out of scope.

---

## Quick Start

### 1. OpenVPN

Place your source profile under `config/openvpn/`. Keep exactly one `.ovpn` file there unless you set `OPENVPN_SOURCE_CONFIG` explicitly.

```bash
mkdir -p config/openvpn
cp examples/openvpn/custom.ovpn config/openvpn/client.ovpn
```

The source profile must keep the hostname in the `remote` line:

```ovpn
remote vpn.example.com 1194
```

Copy and edit the environment file:

```bash
cp .env.example .env
```

At minimum, set these:

```bash
VPN_TYPE=openvpn
DDNS_HOSTNAME=vpn.example.com   # optional if parsed from the remote line
HTTP_PROXY_PORT=8888
```

Validate everything before starting:

```bash
make validate-config
make validate-compose
```

Pull images and start:

```bash
docker compose pull
docker compose up -d
```

Test the proxy:

```bash
curl -x http://127.0.0.1:8888 https://ifconfig.me
```

If you enabled proxy auth:

```bash
curl -x http://127.0.0.1:8888 -U USER:PASSWORD https://ifconfig.me
```

Test the SOCKS5 proxy:

```bash
curl --socks5 127.0.0.1:1080 https://ifconfig.me
```

If you enabled SOCKS5 auth:

```bash
curl --socks5 127.0.0.1:1080 -U USER:PASSWORD https://ifconfig.me
```

### 2. WireGuard

Place your source profile under `config/wireguard/`:

```bash
mkdir -p config/wireguard
cp examples/wireguard/wg0.conf config/wireguard/wg0.conf
```

The source profile must keep the hostname in the `Endpoint` line:

```ini
[Peer]
Endpoint = vpn.example.com:51820
```

Set your environment:

```bash
VPN_TYPE=wireguard
DDNS_HOSTNAME=vpn.example.com   # optional if parsed from the Endpoint line
HTTP_PROXY_PORT=8888
```

Validate and start:

```bash
make validate-config
make validate-compose
docker compose pull
docker compose up -d
```

---

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `VPN_TYPE` | `openvpn` | Protocol: `openvpn` or `wireguard` |
| `TZ` | `UTC` | Timezone for container logs |
| `OPENVPN_CONFIG_DIR` | `./config` | Host directory mounted to `/gluetun/source` for OpenVPN files |
| `OPENVPN_SOURCE_CONFIG` | *(auto-detect)* | Explicit path to source `.ovpn` |
| `WIREGUARD_CONFIG_DIR` | `./config` | Host directory for WireGuard files, used by the validator only. Both protocols share the same Docker mount (`OPENVPN_CONFIG_DIR`). WireGuard configs are read from `./config/wireguard/` within the mounted directory. |
| `WIREGUARD_SOURCE_CONFIG` | *(auto-detect)* | Explicit path to source `.conf` |
| `STATE_DIR` | `./state` | Host directory for rendered runtime configs and DDNS state |
| `DDNS_HOSTNAME` | *(parsed from config)* | Hostname to monitor. Auto-detected from `remote` (OpenVPN) or `Endpoint` (WireGuard) |
| `DDNS_POLL_SECONDS` | `60` | How often the watcher resolves the hostname |
| `DDNS_COOLDOWN_SECONDS` | `15` | Sleep after a restart to avoid restart loops |
| `DDNS_INIT_RETRY_SECONDS` | `5` | Retry interval for the init service |
| `DDNS_INIT_MAX_ATTEMPTS` | `0` | Max init retries. `0` means retry forever |
| `DDNS_RESOLVER` | *(container default)* | Custom DNS resolver IP for hostname lookups |
| `DDNS_OVERRIDE_IP` | *(empty)* | **Test only.** Hardcodes the resolved IP |
| `HTTP_PROXY_PORT` | `8888` | Published port for Gluetun's HTTP proxy |
| `HTTPPROXY_USER` | *(empty)* | Proxy authentication username |
| `HTTPPROXY_PASSWORD` | *(empty)* | Proxy authentication password |
| `HTTPPROXY_STEALTH` | `off` | Hide proxy headers from upstream servers |
| `SOCKS5_PROXY_PORT` | `1080` | Published port for the vproxy SOCKS5 sidecar |
| `SOCKS5_USER` | *(empty)* | SOCKS5 proxy authentication username |
| `SOCKS5_PASSWORD` | *(empty)* | SOCKS5 proxy authentication password |
| `VPROXY_IMAGE` | `ghcr.io/0x676e67/vproxy:latest` | Image for the `vproxy` sidecar |
| `GLUETUN_CONTAINER_NAME` | `ddns-openvpn-proxy` | Name of the Gluetun container to restart |
| `WATCHER_IMAGE` | `ghcr.io/df-wu/ddns-openvpn-proxy-watcher:latest` | Image for `ddns-init` and `ddns-watcher` |
| `GLUETUN_IMAGE` | `qmcgaw/gluetun:latest` | Gluetun image |

### Auto-detection rules

If you leave `OPENVPN_SOURCE_CONFIG` or `WIREGUARD_SOURCE_CONFIG` blank, the stack looks for exactly one matching file in the configured source directory. For WireGuard, the file must contain a `[Interface]` section to distinguish it from plain `.conf` files.

If `DDNS_HOSTNAME` is blank, the stack parses the hostname from the primary `remote` line (OpenVPN) or `Endpoint` line (WireGuard) in the source config.

---

## File Layout

```
.
├── docker-compose.yml              # 4-service stack definition
├── .env.example                    # All tunable variables
├── Makefile                        # validate, smoke, up, down, logs
├── scripts/
│   ├── vpn-ddns-lib.sh            # Core library: dispatch + OpenVPN + WireGuard
│   ├── ddns-init.sh               # One-shot init entrypoint
│   ├── watch-ddns-and-restart.sh # Watcher daemon entrypoint
│   ├── render-vpn-config.sh      # One-time renderer
│   ├── validate-vpn-config.sh     # Generic validator (dispatches by VPN_TYPE)
│   ├── validate-openvpn-config.sh # OpenVPN-specific checks
│   ├── validate-wireguard-config.sh # WireGuard-specific checks
│   └── validate-compose.sh       # docker-compose.yml validation
├── watcher/
│   └── Dockerfile                  # Alpine-based watcher image
├── examples/
│   ├── openvpn/custom.ovpn        # Sample OpenVPN config
│   └── wireguard/wg0.conf         # Sample WireGuard config
└── tests/
    └── e2e/
        └── smoke.sh                # Parameterized smoke test for both protocols
```

---

## Design Decisions

### Separate watcher image

Building the watcher on every target machine invites drift. Publishing it to GHCR means the compose file references an immutable image digest. Your production host never runs `docker build`. The publish workflow only triggers when watcher-related files change, so the image stays current without wasteful rebuilds.

### Container restart instead of in-process reload

Gluetun's internals are complex. Rather than reverse-engineering which signals or API calls might trigger a config reload, we use the primitive that always works: `docker restart`. The watcher writes the new runtime config, then restarts the container. Gluetun comes back up reading the fresh file. This is simple, observable, and easy to reason about in logs.

### Dispatch table pattern

`vpn-ddns-lib.sh` uses a `case` statement to route calls to OpenVPN or WireGuard implementations based on `VPN_TYPE`:

```bash
vpn_render_config() {
  case "$vpn_type" in
    openvpn)   render_openvpn_config "$@" ;;
    wireguard) render_wireguard_config "$@" ;;
  esac
}
```

This keeps protocol-specific code isolated and makes adding a third protocol a matter of adding one branch and one implementation file.

### Stateful init with retries

`ddns-init` blocks the whole stack until the first runtime config is ready. If DNS is not yet resolvable, it retries instead of crashing. This prevents a race where Gluetun starts before its config exists. The retry policy is configurable: you can set a hard attempt limit, or leave it at `0` to retry forever.

---

## Extending to a New VPN Type

Suppose you want to add **L2TP/IPsec** support. Here is the minimal set of changes:

### 1. Implement the protocol functions in `scripts/vpn-ddns-lib.sh`

```bash
detect_l2tp_source_config() {
  # Find the source config file
}

get_l2tp_remote_host() {
  # Extract hostname from the config
}

render_l2tp_config() {
  # Write runtime config with resolved IP
}
```

### 2. Add dispatch branches

Update these three functions in `scripts/vpn-ddns-lib.sh`:

```bash
vpn_detect_source_config() {
  case "$vpn_type" in
    openvpn)   detect_source_config ;;
    wireguard) detect_wg_source_config ;;
    l2tp)      detect_l2tp_source_config ;;
  esac
}

vpn_get_remote_host() {
  case "$vpn_type" in
    openvpn)   get_remote_host "$1" ;;
    wireguard) get_wg_endpoint_host "$1" ;;
    l2tp)      get_l2tp_remote_host "$1" ;;
  esac
}

vpn_render_config() {
  case "$vpn_type" in
    openvpn)   render_openvpn_config "$@" ;;
    wireguard) render_wireguard_config "$@" ;;
    l2tp)      render_l2tp_config "$@" ;;
  esac
}
```

### 3. Add a validator

Create `scripts/validate-l2tp-config.sh`, then update `scripts/validate-vpn-config.sh` to dispatch to it when `VPN_TYPE=l2tp`.

### 4. Update `docker-compose.yml`

Add volume mounts and environment variables so Gluetun can read the rendered L2TP config. If Gluetun itself does not support the new protocol, you would swap the `gluetun` service image for one that does.

### 5. Update the watcher Dockerfile

If your new scripts require extra tools, add them to `watcher/Dockerfile`.

### 6. Add a smoke test branch

Update `tests/e2e/smoke.sh` to exercise the new protocol with a dummy config and assert that the renderer and restart logic work.

---

## Testing

### Validation

Check your local config before starting the stack:

```bash
make validate-repo       # Validate example configs (OpenVPN + WireGuard)
make validate-config     # Validate your own config
make validate-compose    # Validate docker-compose.yml rendering
make validate            # All of the above
```

### Smoke tests

The smoke tests do not need a real VPN server. They verify the DDNS-specific behavior this repository owns:

- The renderer rewrites a hostname-based endpoint to the current IP
- OpenVPN relative file paths are absolutized
- The watcher detects an IP change
- The watcher restarts the configured Gluetun container name

```bash
make smoke               # Run both smoke tests
make smoke-openvpn       # OpenVPN only
make smoke-wireguard     # WireGuard only
```

### What is not covered automatically

- Full tunnel bring-up against a real VPN server
- Host-specific `/dev/net/tun` behavior
- Firewall rules outside the compose stack

Test those manually on your target Linux Docker host after `docker compose up -d`.

---

## Troubleshooting

### Gluetun fails at startup

Check that the rendered runtime config exists:

```bash
ls -la state/openvpn/current.ovpn   # or state/wireguard/wg0.conf
```

If it is missing, `ddns-init` probably could not resolve the hostname. Check its logs:

```bash
docker compose logs ddns-init
```

### ddns-init keeps retrying forever

This means DNS resolution is failing or the source config is not mounted correctly. Two common causes:

1. The DDNS hostname is not resolvable from inside the container
2. The source config directory path in `.env` does not match the actual host path

If you want a hard failure instead of infinite retry, set `DDNS_INIT_MAX_ATTEMPTS` to a non-zero value.

### Watcher never detects changes

Exec into the watcher and test resolution manually:

```bash
docker compose exec ddns-watcher sh
getent ahostsv4 YOUR_HOSTNAME
```

Also check that `state/ddns/last-ip` contains the last known address.

### The target machine tries to build an image

It should not. The compose file uses `image:`, not `build:`. Run `docker compose config` and confirm both `ddns-init` and `ddns-watcher` point at the same pulled image.

### The target machine is not amd64

The published watcher image is `linux/amd64` only. If your host is ARM, either modify the publish workflow for multi-arch builds or deploy on an amd64 machine.

### Proxy port is reachable but traffic does not pass

The HTTP proxy is up, but the tunnel is not healthy. Inspect Gluetun logs first:

```bash
docker compose logs -f gluetun
```

### Proxy authentication fails

If you set `HTTPPROXY_USER` and `HTTPPROXY_PASSWORD`, your client must send credentials. For curl:

```bash
curl -x http://127.0.0.1:8888 -U USER:PASSWORD https://ifconfig.me
```

### Docker socket exposure

`ddns-watcher` mounts `/var/run/docker.sock` to restart Gluetun. This is a privileged capability. Keep this stack on a host you control and do not expose the watcher container externally.

---

## CI and Publishing

- **CI** runs `make validate-repo` and `make smoke` on every PR
- **publish-watcher** builds the watcher image and pushes it to GHCR on `main` when watcher-related files change
- The watcher image is built for `linux/amd64` to keep CI fast

Deploy only after `publish-watcher` succeeds for the commit you want to run.

If the GHCR package is private, log in first:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

---

## Runtime Requirements

- Linux host with `/dev/net/tun`
- Docker and Docker Compose
- `linux/amd64` host (for the published watcher image)
- `/var/run/docker.sock` accessible to `ddns-watcher`

## Known Limitations

- **IPv4 only.** Gluetun's custom-config path only supports IPv4 endpoints.
- **Single source profile.** Only one `.ovpn` or `.conf` file is auto-detected per source directory.
- **First peer only for WireGuard.** If your WireGuard config has multiple `[Peer]` sections, only the first `Endpoint` line is monitored for DDNS changes. All matching Endpoints with the same hostname are updated together, but different hostnames on different peers are not tracked.
- **Docker socket required.** The watcher needs access to `/var/run/docker.sock` to restart Gluetun.
- **Container restart on IP change.** The tunnel is torn down and rebuilt, causing a brief connectivity interruption.

---

## License

See [LICENSE](LICENSE).
