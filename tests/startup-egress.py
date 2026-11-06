#!/usr/bin/env python3
"""Pinned-image SOCKS startup safety, confined to an owned internal network.

A barrier widens the pre-firewall scheduling window reproduced with throttled
Gluetun. The actual Compose health dependency must keep real vproxy unstarted.
A separate, deliberately ungated control proves that the local target is
reachable through SOCKS before the native Gluetun entrypoint is released.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import time

if not Path("/dev/net/tun").is_char_device():
    print("SKIP: native pinned Gluetun startup contract requires /dev/net/tun")
    sys.exit(0)

repo = Path(__file__).resolve().parent.parent
project = "ddns-egress-contract-" + str(os.getpid())
network = project + "-net"
owned = []
startup = None


def docker(*args, check=True):
    return subprocess.run(["docker", *args], capture_output=True, text=True,
                          check=check, timeout=45)


def until(predicate, description):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError("timed out: " + description)


with tempfile.TemporaryDirectory(prefix=project + "-") as directory:
    fixture = Path(directory)
    fixture.chmod(0o777)
    compose_file = fixture / "compose.json"

    def compose(*args):
        return ["docker", "compose", "-p", project, "-f", str(compose_file), *args]

    try:
        model = json.loads(docker("compose", "--env-file", str(repo / ".env.example"),
                                  "-f", str(repo / "docker-compose.yml"),
                                  "config", "--format", "json").stdout)
        vpn_image = model["services"]["gluetun"]["image"]
        proxy_image = model["services"]["vproxy"]["image"]
        for image in (vpn_image, proxy_image):
            if docker("image", "inspect", image, check=False).returncode != 0:
                docker("pull", image)
        docker("network", "create", "--internal", network)
        target = project + "-target"
        owned.append(target)
        docker("run", "-d", "--name", target, "--network", network,
               "--cap-add", "NET_ADMIN", "alpine:3.22", "sh", "-ec",
               "ip addr add 198.18.0.2/32 dev lo; while true; do "
               "printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 19\\r\\n"
               "Connection: close\\r\\n\\r\\nDIRECT_WITHOUT_VPN\\r\\n' "
               "| nc -l -p 8080; done")
        target_ip = docker("inspect", "-f",
                            "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                            target).stdout.strip()
        (fixture / "wg0.conf").write_text(
            "[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n"
            "Address = 10.0.0.2/32\n[Peer]\n"
            "PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n"
            "Endpoint = 127.0.0.1:51820\n")
        vpn = project + "-vpn"
        proxy = project + "-proxy"
        services = {
            "gluetun": {
                "image": vpn_image, "container_name": vpn, "cpus": 0.01,
                "networks": ["fixture"], "cap_add": ["NET_ADMIN"],
                "devices": ["/dev/net/tun:/dev/net/tun"],

                "volumes": [str(fixture) + ":/fixture"],
                "environment": {
                    "VPN_SERVICE_PROVIDER": "custom", "VPN_TYPE": "wireguard",
                    "WIREGUARD_CONF_SECRETFILE": "/fixture/wg0.conf",
                    "WIREGUARD_IMPLEMENTATION": "userspace", "BLOCK_MALICIOUS": "off",
                    "PUBLICIP_ENABLED": "off", "VERSION_INFORMATION": "off",
                    "STORAGE_FILEPATH": "", "FIREWALL_INPUT_PORTS": "1080,9999"},
                "entrypoint": ["/bin/sh", "-ec"],
                "command": ["ip route add 198.18.0.2/32 via " + target_ip +
                            "; touch /fixture/pre-firewall; "
                            "while [ ! -f /fixture/release-native ]; do sleep 0.1; done; "
                            "exec /gluetun-entrypoint"],
                "healthcheck": {"test": ["CMD-SHELL", "/gluetun-entrypoint healthcheck"],
                                "interval": "1s", "timeout": "1s", "start_period": "30s"}},
            "vproxy": {
                "image": proxy_image, "container_name": proxy,
                "network_mode": "service:gluetun",
                "depends_on": model["services"]["vproxy"]["depends_on"],
                "read_only": True, "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"],
                "entrypoint": ["/bin/sh", "-ec"],
                "command": ["exec /bin/vproxy run --bind 0.0.0.0:1080 socks5"]}}
        compose_file.write_text(json.dumps({"services": services,
            "networks": {"fixture": {"external": True, "name": network}}}))
        log = (fixture / "up.log").open("w")
        startup = subprocess.Popen(compose("up", "-d", "--wait", "--wait-timeout", "45"),
                                   stdout=log, stderr=subprocess.STDOUT)
        until(lambda: (fixture / "pre-firewall").exists(), "pre-firewall barrier")
        vpn_ip = json.loads(docker("inspect", vpn).stdout)[0]["NetworkSettings"]["Networks"][network]["IPAddress"]

        def request():
            return subprocess.run(["curl", "--noproxy", "", "-sS", "--max-time", "1",
                "--socks5", vpn_ip + ":1080", "http://198.18.0.2:8080/"],
                capture_output=True, text=True, timeout=3)

        # Give Compose time to start an incorrectly ungated proxy.
        leaked = False
        for _ in range(15):
            if "DIRECT_WITHOUT_VPN" in request().stdout:
                leaked = True
                break
            time.sleep(0.1)
        assert not leaked, "SOCKS forwarded traffic before the VPN firewall was initialized"
        info = json.loads(docker("inspect", proxy).stdout)[0]
        assert info["State"]["Status"] == "created", "proxy must remain gated on VPN health"
        assert not docker("logs", vpn).stdout.strip(), "native runtime unexpectedly crossed barrier"
        print("PASS: actual Compose keeps pinned vproxy unstarted before native VPN/firewall readiness", flush=True)

        control = project + "-ungated-control"
        owned.append(control)
        docker("run", "-d", "--name", control, "--network", "container:" + vpn,
               "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
               "--entrypoint", "/bin/sh", proxy_image, "-ec",
               "exec /bin/vproxy run --bind 0.0.0.0:1080 socks5")
        until(lambda: "DIRECT_WITHOUT_VPN" in request().stdout, "ungated positive egress control")
        docker("rm", "-f", control)
        owned.remove(control)
        print("PASS: ungated pinned-image control reaches local target without a VPN", flush=True)
        (fixture / "release-native").touch()
        until(lambda: bool(docker("logs", vpn).stdout.strip()), "native Gluetun startup")
        assert "DIRECT_WITHOUT_VPN" not in request().stdout, "unhealthy VPN admitted proxy traffic"
        assert json.loads(docker("inspect", proxy).stdout)[0]["State"]["Status"] == "created"
        print("PASS: proxy remains gated while the native pinned VPN is unhealthy", flush=True)
    except Exception:
        if compose_file.exists():
            print((fixture / "up.log").read_text() if (fixture / "up.log").exists() else "")
        raise
    finally:
        if startup is not None:
            startup.terminate()
            try:
                startup.wait(timeout=10)
            except subprocess.TimeoutExpired:
                startup.kill()
                startup.wait(timeout=10)
        if compose_file.exists():
            subprocess.run(compose("down", "--volumes", "--remove-orphans"),
                           capture_output=True, timeout=45)
        for name in reversed(owned):
            docker("rm", "-f", name, check=False)
        docker("network", "rm", network, check=False)
