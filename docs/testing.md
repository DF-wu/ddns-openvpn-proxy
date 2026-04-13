# Testing

## Validation

Run the repository checks first:

```bash
make validate
```

This validates:

- the OpenVPN source profile contract
- referenced files for non-inlined directives
- Docker Compose rendering with example inputs

## Smoke test

```bash
make smoke
```

The smoke test is intentionally lightweight. It does not require a real VPN server. Instead it verifies the DDNS-specific behavior this repository owns:

- the renderer rewrites a hostname-based `remote` to the current IP
- the renderer rewrites relative certificate/key/auth paths to absolute container paths
- the watcher detects an IP change
- the watcher restarts the Gluetun container name it was configured with

## What is not covered automatically

- a full tunnel bring-up against a real OpenVPN server
- host-specific `/dev/net/tun` behavior
- firewall behavior outside the compose stack

Those checks should be done manually on the target Linux Docker host after `make up`.
