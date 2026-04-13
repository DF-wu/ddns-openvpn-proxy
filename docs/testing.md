# Testing

## Fast validation

Use this before every run:

```bash
make validate
```

That runs:

- OpenVPN config validation
- Docker Compose rendering validation

If `./.env` exists, validation uses your real operator inputs. If it does not exist, validation falls back to the example values bundled with the repository.

## Runtime contract smoke test

```bash
make smoke
```

What it does:

1. generates a temporary OpenVPN server fixture using `kylemanna/openvpn`
2. generates a client config whose `remote` host is a hostname, not an IP
3. starts the local OpenVPN server fixture so Docker DNS can resolve `openvpn-server`
4. starts the upstream `binhex/arch-privoxyvpn` stack from this repository
5. checks that the runtime accepts the hostname-based `.ovpn` contract instead of rejecting it as IP-only
6. checks that the tunnel interface is actually created
7. starts the upstream microsocks helper for the local fixture and checks that the SOCKS listener really opens

This test is intentionally conservative. It validates the runtime contract that matters most for this repository: **a custom `.ovpn` file with a hostname remote is accepted by the chosen upstream image and can bring up the OpenVPN tunnel**.

For a full real-world acceptance test on your target host, run the documented `curl --socks5-hostname ...` command after `make up`.

## Failure-path tests

This repository ships lightweight executable failure tests through the validator:

- missing OpenVPN config
- missing `remote` line
- missing referenced files

Run one manually like this:

```bash
scripts/validate-openvpn-config.sh ./tests/fixtures/invalid/missing-remote.ovpn
```
