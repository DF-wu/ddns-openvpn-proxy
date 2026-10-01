# 部署、維運與故障排除

## 需求

- Linux host、Docker Engine 24+、Docker Compose v2.20+
- Gluetun／OpenConnect backend：`/dev/net/tun`
- 可存取 Docker Hub 與 GHCR
- 建議 `make` 與 `jq`（`make validate-compose` 需要），非必要

```bash
docker version
docker compose version
test -c /dev/net/tun && echo 'TUN ready'
```

rootless Docker、Docker Desktop 與非標準 socket path 不在 production 契約內。

## 目錄配置

```text
ddns-openvpn-proxy/
├── .env
├── docker-compose.yml                 # Gluetun backend（預設）
├── docker-compose.openconnect.yml     # OpenConnect backend
├── docker-compose.singbox.yml         # sing-box backend
├── compose/core.yml                   # 共用 service（extends）
├── scripts/                           # helper：ddns-vpn.sh + lib/ + adapters/
├── docker/socket-proxy-haproxy.cfg.tmpl
└── config/                            # 不進版控
    ├── openvpn/      client.ovpn [+ ca.crt client.crt client.key]
    ├── wireguard/    wg0.conf
    ├── openconnect/  client.conf [+ ca.pem]
    └── sing-box/     config.json [+ ca.crt]
```

只有 `VPN_CONFIG_DIR` 選定的目錄會 read-only mount 到 `/source`；profile 引用的相對
路徑都以該目錄為基準。

## 選擇 backend

| 連線方式 | `.env` | 說明文件 |
| --- | --- | --- |
| OpenVPN | `VPN_TYPE=openvpn`（預設） | 本文件 |
| WireGuard | `VPN_TYPE=wireguard` | 本文件 |
| OpenConnect | `VPN_TYPE=openconnect` + `COMPOSE_FILE=docker-compose.openconnect.yml` | [backends/openconnect.md](backends/openconnect.md) |
| sing-box | `VPN_TYPE=singbox` + `COMPOSE_FILE=docker-compose.singbox.yml` | [backends/singbox.md](backends/singbox.md) |

`COMPOSE_FILE` 放在 `.env` 後，所有 `docker compose` 與 `make` 指令都會使用對應
stack；`scripts/validate-compose.sh` 會在 `COMPOSE_FILE` 與 `VPN_TYPE` 不一致時
拒絕。切換 backend 前先 `make down`（不同 backend 的 container 名稱不同，但共用
`vpn-state` volume 與 host port）。

## 準備 profile

### OpenVPN

Inline 憑證只需一個檔案；外部檔案放同一目錄，profile 可保留相對路徑：

```bash
mkdir -p config/openvpn
install -m 600 /path/provider.ovpn config/openvpn/client.ovpn
install -m 600 /path/ca.crt config/openvpn/ca.crt      # profile 有引用時
```

```ovpn
remote vpn.example.com 1194 udp
ca ca.crt
cert client.crt
key client.key
```

若 profile 使用 `auth-user-pass`，在 `.env` 設定 `OPENVPN_USER`／`OPENVPN_PASSWORD`；
Gluetun 會覆寫 directive 中的檔案路徑。只設定其中一個會被拒絕。

### WireGuard

```bash
mkdir -p config/wireguard
install -m 600 /path/wg0.conf config/wireguard/wg0.conf
```

必須有且只有一個 `[Interface]`（PrivateKey、Address）與一個 `[Peer]`（PublicKey、
hostname-based Endpoint）。`AllowedIPs`、keepalive、MTU、implementation 由 `.env`
的 `WIREGUARD_*` 控制，Gluetun 不從檔案匯入。

### OpenConnect 與 sing-box

見各自的 backend 文件；範例在 `examples/openconnect/client.conf` 與
`examples/sing-box/config.json`。

不要把 `config/`、`.env` 或 credentials 加入 git（`.gitignore` 已忽略）。

## 環境變數

```bash
cp .env.example .env
chmod 600 .env
```

完整定義與驗證規則在 [spec §4](spec.md)。以下依用途分組。

### 選擇與 profile

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `VPN_TYPE` | `openvpn` | `openvpn`、`wireguard`、`openconnect`、`singbox` |
| `COMPOSE_FILE` | 未設定（=`docker-compose.yml`） | 非預設 backend 的 stack file |
| `VPN_CONFIG_DIR` | `./config/openvpn` | host 上的 source 目錄 |
| `VPN_CONFIG_FILE` | `client.ovpn` | source 目錄內的 profile 檔名 |
| `DDNS_HOSTNAME` | 空 | 空白時使用 profile 的 endpoint host（OpenConnect：`OPENCONNECT_SERVER`） |

`DDNS_HOSTNAME` 適合 profile endpoint 暫時仍是舊值、但實際要監看的 hostname 不同
時使用；renderer 不論 source 原值為何都改寫唯一 endpoint（sing-box 除外：值必須
出現在 profile 內）。

### Backend 專屬

| 變數 | 預設 | 適用 |
| --- | --- | --- |
| `OPENVPN_USER` / `OPENVPN_PASSWORD` / `OPENVPN_VERBOSITY` | 空 / 空 / `1` | Gluetun OpenVPN |
| `WIREGUARD_ALLOWED_IPS` | `0.0.0.0/0` | Gluetun WireGuard |
| `WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL` | `0`（Go duration，如 `25s`） | Gluetun WireGuard |
| `WIREGUARD_MTU` | `1320`（576..65535） | Gluetun WireGuard |
| `WIREGUARD_IMPLEMENTATION` | `auto`（`userspace`、`kernelspace`） | Gluetun WireGuard |
| `OPENCONNECT_SERVER` / `OPENCONNECT_PORT` | 空（必填） / `443` | OpenConnect |
| `OPENCONNECT_USER` / `OPENCONNECT_PASSWORD` | 空 | OpenConnect（成對） |
| `OPENCONNECT_TOTP_SECRET` / `OPENCONNECT_OPTIONS` / `OPENCONNECT_RECONNECT_DELAY` | 空 / 空 / `30` | OpenConnect |
| `SINGBOX_DNS_SERVER` / `SINGBOX_LOG_LEVEL` | `1.1.1.1` / `info` | sing-box |
| `SINGBOX_HEALTH_URL` / `SINGBOX_HEALTH_PROBE` | Cloudflare 204 / Clash API URL | sing-box |

### Polling 與 restart

| 變數 | 預設 | 驗證 |
| --- | --- | --- |
| `DDNS_POLL_SECONDS` | `60` | 整數，最少 `10` |
| `DDNS_INIT_RETRY_SECONDS` | `5` | 正整數 |
| `DDNS_RESOLVER` | 空 | 指定時必須是 IPv4 DNS server |
| `VPN_CONTAINER_NAME` | 依 stack（`ddns-openvpn-proxy`、`ddns-openconnect-proxy`、`ddns-singbox-proxy`） | restart target |
| `VPROXY_CONTAINER_NAME` | `ddns-openvpn-vproxy` | Gluetun stack 的 sidecar target |
| `VPN_RESTART_TIMEOUT_SECONDS` | `20` | 正整數 |
| `VPN_HEALTH_TIMEOUT_SECONDS` | `120` | 每個就緒探測的等待上限 |

`DDNS_OVERRIDE_IPS` 只供測試與診斷，production 必須留空。舊名 `GLUETUN_CONTAINER_NAME`、
`GLUETUN_RESTART_TIMEOUT_SECONDS`、`GLUETUN_HEALTH_TIMEOUT_SECONDS`、
`OPENVPN_CONFIG_DIR`、`OPENVPN_CONFIG_FILE` 仍是 alias。

### Proxy

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `PROXY_BIND_ADDRESS` | `127.0.0.1` | host bind address；OpenConnect backend 只能是這個值 |
| `HTTP_PROXY_PORT` / `SOCKS5_PROXY_PORT` | `8888` / `1080` | host port |
| `HTTPPROXY` | `on` | HTTP proxy 開關（Gluetun、sing-box） |
| `HTTPPROXY_USER` / `HTTPPROXY_PASSWORD` | 空 | 成對 |
| `HTTPPROXY_STEALTH` | `off` | Gluetun 專用 |
| `SOCKS5_USER` / `SOCKS5_PASSWORD` | 空 | 成對 |
| `VPROXY_LOG` | `info` | vproxy log level |

非 loopback bind 時，SOCKS5 與（開啟的）HTTP 都必須有完整認證。

### Log rotation 與 images

`LOG_MAX_SIZE`（`10m`）、`LOG_MAX_FILE`（`3`）套用到所有 service。Image pin：
`DDNS_HELPER_IMAGE`、`SOCKET_PROXY_IMAGE`、`GLUETUN_IMAGE`、`VPROXY_IMAGE`、
`OPENCONNECT_IMAGE`、`SINGBOX_IMAGE`；validator 拒絕 `latest`、`edge`、`master`、
`main`。需要更強的 reproducibility 時可改成 `image@sha256:...`。

## 部署

```bash
make validate   # rendered Compose 契約 + 真實 helper container 驗證 profile
make up         # pull 並等待 long-running services healthy
```

純 Compose：

```bash
docker compose pull
docker compose up -d --wait --wait-timeout 180
```

確認零 build：

```bash
docker compose config --format json | jq '.services[] | .build?'   # 全為 null
find . -name Dockerfile -print                                      # 無輸出
```

## 日常觀察

```bash
docker compose ps --all
```

| Service | 預期狀態 |
| --- | --- |
| `ddns-init` | `Exited (0)` |
| VPN container（`gluetun`／`openconnect`／`singbox`） | `Up ... (healthy)` |
| `vproxy`（Gluetun stack） | `Up ... (healthy)` |
| `docker-socket-proxy` | `Up ... (healthy)` |
| `ddns-watcher` | `Up ... (healthy)` |

```bash
make logs                         # 所有 service
docker compose logs -f ddns-watcher
```

Helper log 為可搜尋的 key-value：

```text
2026-09-28T01:23:45Z level=INFO rendered profile vpn_type=openconnect hostname=vpn.example.com ip=203.0.113.10 output=/state/runtime/vpn.conf
2026-09-28T02:34:56Z level=WARN DNS lookup failed hostname=vpn.example.com; keeping current tunnel
2026-09-28T03:45:12Z level=INFO restarted VPN stack vpn_type=openconnect reason=address-change hostname=vpn.example.com old_ip=203.0.113.10 new_ip=203.0.113.20 vpn=ddns-openconnect-proxy sidecar=none
```

檢視 runtime state：

```bash
docker compose run --rm --no-deps --entrypoint sh ddns-init -c '
  printf "last-ip: "; cat /state/ddns/last-ip
  printf "fingerprint: "; cat /state/ddns/source.sha256
  printf "heartbeat: "; cat /state/ddns/watcher-heartbeat
  sed -n "1,40p" /state/runtime/vpn.conf
'
```

runtime profile 可能含金鑰，不要貼到公開 issue。

## Proxy 驗證

```bash
curl --fail -x http://127.0.0.1:8888 https://ifconfig.me
curl --fail --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
# 有認證時
curl --fail -x http://HOST:8888 -U 'USER:PASSWORD' https://ifconfig.me
curl --fail --socks5-hostname HOST:1080 -U 'USER:PASSWORD' https://ifconfig.me
```

務必再測一次錯誤 password，預期被拒絕。使用 `--socks5-hostname` 讓目的 hostname
在 proxy 端解析。

## LAN／Internet exposure

1. 填入 HTTP 與 SOCKS5 兩組完整 credentials（OpenConnect backend 不支援，保持
   loopback）；
2. `PROXY_BIND_ADDRESS` 設為特定 LAN address，只有必要時才 `0.0.0.0`；
3. `make validate-compose`；
4. host firewall 只允許可信 source CIDR；
5. 啟動後測試匿名與錯誤 credentials 確實被拒絕。

```bash
sudo ufw allow from 192.168.50.0/24 to any port 8888 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 1080 proto tcp
```

HTTP Basic 與 SOCKS5 認證都不是 transport encryption；跨不可信網路請外加 VPN 或
SSH tunnel。

## 設定與憑證輪替

替換 profile、憑證或金鑰後不必手動 restart；watcher 最晚一個 polling interval 內
偵測 fingerprint 改變並執行 restart chain。建議同 filesystem 的 atomic replace：

```bash
install -m 600 /path/new-client.crt config/openvpn/client.crt.new
mv config/openvpn/client.crt.new config/openvpn/client.crt
```

`.env` 的改變（credentials、`OPENCONNECT_SERVER`、`WIREGUARD_*` 等）需要
`docker compose up -d --force-recreate`，container environment 不會熱更新。

## 強制重新解析與重連

```bash
docker compose run --rm --no-deps ddns-init init
docker compose restart <vpn-service>        # gluetun / openconnect / singbox
# Gluetun stack 另外：
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q gluetun)")" = healthy ]; do sleep 2; done
docker compose restart vproxy
```

## 升級與 rollback

1. 在 branch 或 staging 更新 `.env` 的 image tag；閱讀上游 release notes。
2. `make check`。
3. `docker compose pull && docker compose up -d --force-recreate --wait --wait-timeout 180`。

Rollback 把 tag 改回已知正常版本後重做第 3 步；`vpn-state` 與 source profile
向後相容，不需要 migration。不要使用 `docker compose up --build`。

## Host reboot

long-running services 使用 `restart: unless-stopped`。`vpn-state` 保留最後
profile；watcher 啟動後重新解析 DNS 與 fingerprint。停機期間 DDNS 已改變時，最多
一個 polling interval 內 render 並執行 restart chain。

## 停止與移除

```bash
make down    # 保留 runtime state
make clean   # 連 vpn-state volume 一起刪除
```

`config/` 不會被刪除。

## 故障排除

### `ddns-init` 非 0 結束

```bash
docker compose logs ddns-init
```

`level=ERROR` 訊息就是原因。常見：

| 訊息 | 處理 |
| --- | --- |
| `... profile not found: /source/...` | 確認 `VPN_CONFIG_DIR`／`VPN_CONFIG_FILE`；`docker compose config \| grep -A5 /source` |
| `VPN_TYPE=... belongs to the X backend, but this stack is VPN_BACKEND=Y` | `COMPOSE_FILE` 與 `VPN_TYPE` 不一致 |
| `expected exactly one active remote directive` | 只保留目標 DDNS hostname 的 remote |
| `... references an unreadable file` | 把檔案放進 `VPN_CONFIG_DIR`，修正路徑與大小寫 |
| `invalid WireGuard profile` | 多個 Peer、缺少 PrivateKey／Address／PublicKey／Endpoint、port 不合法 |
| `OPENCONNECT_SERVER must be set` | 在 `.env` 設定 gateway hostname |
| `OpenConnect profile must not set '...'` | 移除 stack 管理的選項（見 backend 文件） |
| `sing-box profile must contain an outbound tagged "vpn"` | 把主要 outbound 的 `tag` 改為 `vpn` |
| `sing-box profile has several hostname-based "server" values` | 設定 `DDNS_HOSTNAME` |
| `... credentials are required when PROXY_BIND_ADDRESS is not 127.0.0.1` | 補齊認證或改回 loopback |
| `the openconnect backend has no proxy authentication` | OpenConnect 只能 loopback |

### Init 一直重試 DNS

```bash
docker compose logs -f ddns-init
docker compose run --rm --no-deps ddns-init validate
```

必要時在 `.env` 指定 `DDNS_RESOLVER=1.1.1.1` 後 recreate。不要把
`DDNS_OVERRIDE_IPS` 當 production 解法。

### Watcher 偶爾記錄 DNS warning

單次 warning 不會中斷 tunnel。長期持續時檢查 host／Docker DNS、指定 resolver 的
UDP／TCP 53、DDNS record 是否仍有 A record，以及 VPN container health 是否同時惡化。

### VPN container 不健康

```bash
docker compose logs --tail=200 <vpn-service>
docker inspect --format '{{json .State.Health}}' <container-name> | jq
```

| Backend | 常見原因 |
| --- | --- |
| gluetun | 錯誤憑證／key、server 不可達、cipher／route 不相容、TUN device、DDNS 新 IP 尚未提供服務 |
| openconnect | 認證失敗、`servercert` pin 不符、需要互動式 MFA、gateway 不接受 protocol；tunnel 未建立時 proxy port 會回 RST |
| singbox | `sing-box check` 失敗（看 log 第一行）、TLS `server_name` 未設定導致對 IP 驗證失敗、server 拒絕、`SINGBOX_HEALTH_URL` 不可達 |

### Watcher 無法 restart

```bash
docker compose ps docker-socket-proxy ddns-watcher
docker compose logs docker-socket-proxy ddns-watcher
```

檢查 `/var/run/docker.sock` 可用、socket proxy healthy、`VPN_CONTAINER_NAME`
（與 `VPROXY_CONTAINER_NAME`）與實際 `container_name` 相同、`ddns-watcher` 同時在
default 與 `docker-api` network、SELinux／AppArmor 是否阻擋。socket proxy log 中
`invalid restart target name` 或 `duplicate restart target name` 表示 `.env` 的
container 名稱不合法。

### SOCKS5 container restarting（Gluetun stack）

最常見是只設定了 `SOCKS5_USER` 或 `SOCKS5_PASSWORD` 其中一個。

### Port 可連線但沒有流量

先看 VPN container 與 sidecar 的 health 與 log。Gluetun stack 確認
`FIREWALL_INPUT_PORTS: "1080,9999"` 未被移除；sing-box 確認 `route.final` 沒有被
profile 的 `route` 覆蓋（stack 的值應優先，log 會有 WARN）。

### Port 已被使用

```dotenv
HTTP_PROXY_PORT=18888
SOCKS5_PROXY_PORT=11080
```

container 內的 port 固定（Gluetun `8888`／`1080`、OpenConnect `8888`／`8889`、
sing-box `8888`／`1080`）。
