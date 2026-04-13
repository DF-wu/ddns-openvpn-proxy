# Architecture

## Design goal

This repository exists to provide a **SOCKS5 proxy that sends traffic through an OpenVPN tunnel**, while keeping the OpenVPN server address compatible with a **hostname or DDNS hostname**.

The key engineering decision is to **reuse a mature upstream runtime** instead of maintaining a fragile custom VPN lifecycle in shell.

## Chosen building block

### Upstream runtime: binhex/arch-privoxyvpn

We use `binhex/arch-privoxyvpn` in **custom OpenVPN mode with built-in microsocks**.

Why:

- it is actively maintained
- it accepts custom OpenVPN config files without forcing the remote host to be an IP address
- it already includes a SOCKS5 server, so we do not have to maintain a proxy sidecar
- it still leaves room for future WireGuard work without forcing WireGuard into this version

## Why we removed the old shell lifecycle

The previous prototype:

- resolved the hostname to an IP before launch
- rewrote the OpenVPN `remote` line at runtime
- tried to restart OpenVPN through a non-existent `restart-vpn` path
- mixed daemonized processes with a late-starting supervisor

That design was brittle and unnecessary.

The refactor removes all of that.

## DDNS model

This project does **not** implement a custom DDNS watcher.

Instead, it relies on the correct abstraction:

1. keep a hostname in the `.ovpn` `remote` line
2. let OpenVPN resolve that hostname
3. rely on reconnect behavior when the server endpoint changes
4. make reconnect happen promptly with `keepalive` or `ping-restart`

That model is simpler, easier to reason about, and better aligned with how OpenVPN is supposed to be used.

## Compose topology

The stack is now a single primary runtime container.

That means:

- OpenVPN and SOCKS5 live in the same upstream runtime image
- this repo only needs to mount config and set a small set of environment variables
- the public SOCKS5 port is mapped from container port `9118` to host port `1080` by default

## Future WireGuard extension point

Future WireGuard support should extend the **runtime contract**, not resurrect the old custom shell lifecycle.

That future work should add:

- a separate validation path
- separate documentation
- separate runtime tests

This repo intentionally does not pretend OpenVPN and WireGuard are interchangeable.
