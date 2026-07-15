# 部署、維運與故障排除

## 需求

- Linux host
- Docker Engine 24 或更新版本
- Docker Compose v2.20 或更新版本
- `/dev/net/tun`
- 可存取 Docker Hub 與 GHCR
- 建議使用 `make`，但不是必要條件

檢查：

```bash
docker version
docker compose version
test -c /dev/net/tun && echo 'TUN ready'
```

rootless Docker、Docker Desktop 與非標準 socket path 沒有納入目前 production 契約。

## 目錄配置

建議 deployment 目錄：

```text
ddns-openvpn-proxy/
├── .env
├── docker-compose.yml
├── scripts/
│   └── ddns-openvpn.sh
└── config/
    └── openvpn/
        ├── client.ovpn
        ├── ca.crt
        ├── client.crt
        └── client.key
```

整個 `config/openvpn` 會 read-only mount 到 `/source`。`client.ovpn` 引用的相對路徑
都以這個目錄為基準。

## 準備 profile

### Inline certificate profile

如果 `.ovpn` 已包含 `<ca>`、`<cert>`、`<key>` block，只需一個檔案：

```bash
mkdir -p config/openvpn
install -m 600 /path/provider.ovpn config/openvpn/client.ovpn
```

### External file profile

```bash
mkdir -p config/openvpn
install -m 600 /path/provider.ovpn config/openvpn/client.ovpn
install -m 600 /path/ca.crt config/openvpn/ca.crt
install -m 600 /path/client.crt config/openvpn/client.crt
install -m 600 /path/client.key config/openvpn/client.key
```

Profile 可保留相對路徑：

```ovpn
ca ca.crt
cert client.crt
key client.key
```

### Username/password authentication

若 provider profile 使用：

```ovpn
auth-user-pass
```

在 `.env` 設定：

```dotenv
OPENVPN_USER=vpn-username
OPENVPN_PASSWORD=replace-with-the-vpn-password
```

Gluetun custom provider 會把 `auth-user-pass` 覆寫到 container 內部 auth file，因此
不要依賴 directive 的 `credentials.txt` path。只設定 user 或 password 其中一個會被
Compose validator 拒絕。

不要把 `config/`、`.env` 或 credentials 加入 git。專案 `.gitignore` 已忽略常見路徑，
但部署端仍應設定正確的檔案權限與備份政策。

## 環境變數

先建立 `.env`：

```bash
cp .env.example .env
chmod 600 .env
```

### 一般與 OpenVPN

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `TZ` | `Asia/Taipei` in example | log timezone；helper timestamp 固定 UTC |
| `COMPOSE_PROJECT_NAME` | `ddns-openvpn-proxy` | Compose resource prefix |
| `OPENVPN_CONFIG_DIR` | `./config/openvpn` | host 上的 source 目錄 |
| `OPENVPN_CONFIG_FILE` | `client.ovpn` | source 目錄內的 profile 檔名 |
| `OPENVPN_USER` | 空 | profile 有 `auth-user-pass` 時必填 |
| `OPENVPN_PASSWORD` | 空 | 必須與 `OPENVPN_USER` 成對 |
| `DDNS_HOSTNAME` | 空 | 空白時從唯一 `remote` 讀取 |
| `OPENVPN_VERBOSITY` | `1` | Gluetun OpenVPN verbosity，範圍依上游 |

`DDNS_HOSTNAME` 適合 source profile 的 `remote` 暫時仍是舊值、但實際要監看的 hostname
不同時使用。Renderer 不論 source 原值為何，都會改寫唯一 `remote` 的 host 欄位。

### Polling 與 restart

| 變數 | 預設 | 驗證 |
| --- | --- | --- |
| `DDNS_POLL_SECONDS` | `60` | integer，最少 `10` |
| `DDNS_INIT_RETRY_SECONDS` | `5` | positive integer |
| `DDNS_RESOLVER` | 空 | 指定時必須是 IPv4 DNS server |
| `GLUETUN_CONTAINER_NAME` | `ddns-openvpn-proxy` | watcher restart target |
| `GLUETUN_RESTART_TIMEOUT_SECONDS` | `20` | positive integer |

`DDNS_OVERRIDE_IPS` 只供測試與診斷。production 必須留空；可接受以逗號或 whitespace
分隔的 IPv4 列表。

### Proxy

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `PROXY_BIND_ADDRESS` | `127.0.0.1` | host bind address |
| `HTTP_PROXY_PORT` | `8888` | host HTTP proxy TCP port |
| `SOCKS5_PROXY_PORT` | `1080` | host SOCKS5 TCP port |
| `HTTPPROXY` | `on` | Gluetun HTTP proxy switch |
| `HTTPPROXY_USER` | 空 | HTTP authentication user |
| `HTTPPROXY_PASSWORD` | 空 | HTTP authentication password |
| `HTTPPROXY_STEALTH` | `off` | Gluetun proxy stealth mode |
| `SOCKS5_USER` | 空 | SOCKS5 authentication user |
| `SOCKS5_PASSWORD` | 空 | SOCKS5 authentication password |
| `VPROXY_LOG` | `info` | vproxy log level |

### Log rotation

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `LOG_MAX_SIZE` | `10m` | 每個 Docker json log file 上限 |
| `LOG_MAX_FILE` | `3` | 每個 service 保留檔案數 |

所有 services 共用同一個 rotation policy，避免長期 DNS／VPN warning 填滿 host disk。

Authentication pair 必須「兩個都有」或「兩個都空」。非 loopback bind 時，Compose
validator 進一步要求 HTTP（若開啟）與 SOCKS5 都有 credentials。

### Images

| 變數 | 預設 |
| --- | --- |
| `GLUETUN_IMAGE` | `qmcgaw/gluetun:v3.41.1` |
| `DDNS_HELPER_IMAGE` | `docker:29.6.1-cli-alpine3.24` |
| `VPROXY_IMAGE` | `ghcr.io/0x676e67/vproxy:v2.5.5` |
| `SOCKET_PROXY_IMAGE` | `ghcr.io/tecnativa/docker-socket-proxy:v0.4.2` |

Validator 會拒絕 `latest`、`edge`、`master`、`main` moving tag。需要更強的 reproducibility
時，可將值改成 `image@sha256:...` digest。

## 部署

### 建議流程

```bash
make validate
make up
```

`make validate` 會：

1. render 完整 Compose model 並驗證權限、安全與 service 契約；
2. 用真正的 stock helper container 驗證 mounted profile。

`make up` 接著 pull images，然後等待 long-running services healthy。

### 純 Compose 流程

```bash
docker compose pull
docker compose up -d --wait --wait-timeout 180
```

不需要 Make、不需要 compiler、不需要 Docker Buildx，也不需要登入本專案自己的
container registry。

### 驗證零 build

```bash
docker compose config --format json | jq '.services[] | .build?'
# 每行都應為 null，或沒有輸出

find . -name Dockerfile -print
# 應沒有輸出
```

## 日常觀察

### Service status

```bash
docker compose ps --all
```

正常狀態：

| Service | 預期狀態 |
| --- | --- |
| `ddns-init` | `Exited (0)`；one-shot 成功是正常狀態 |
| `gluetun` | `Up ... (healthy)` |
| `vproxy` | `Up ... (healthy)` |
| `docker-socket-proxy` | `Up ... (healthy)` |
| `ddns-watcher` | `Up ... (healthy)` |

### Logs

```bash
make logs
```

或：

```bash
docker compose logs -f --tail=100 \
  gluetun vproxy ddns-watcher docker-socket-proxy
```

helper 使用可搜尋的 key-value 訊息：

```text
2026-07-15T01:23:45Z level=INFO rendered profile hostname=vpn.example.com ip=203.0.113.10 output=/state/openvpn/client.ovpn
2026-07-15T02:34:56Z level=WARN DNS lookup failed hostname=vpn.example.com; keeping current tunnel
2026-07-15T03:45:12Z level=INFO restarted Gluetun reason=address-change hostname=vpn.example.com old_ip=203.0.113.10 new_ip=203.0.113.20
```

IP 與 profile 都不變時不寫 INFO，避免每分鐘製造無價值 log；heartbeat 仍會更新。

### 檢視 runtime state

```bash
docker compose run --rm --no-deps --entrypoint sh ddns-init -c '
  printf "last-ip: "; cat /state/ddns/last-ip
  printf "fingerprint: "; cat /state/ddns/source.sha256
  printf "heartbeat: "; cat /state/ddns/watcher-heartbeat
  sed -n "1,40p" /state/openvpn/client.ovpn
'
```

runtime profile 含敏感路徑與可能的 inline certificate/key，不要貼到公開 issue。

## Proxy 驗證

### Loopback

```bash
curl --fail --show-error \
  -x http://127.0.0.1:8888 https://ifconfig.me

curl --fail --show-error \
  --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
```

### Authentication

```bash
curl --fail --show-error \
  -x http://HOST:8888 -U 'USER:PASSWORD' https://ifconfig.me

curl --fail --show-error \
  --socks5-hostname HOST:1080 -U 'USER:PASSWORD' https://ifconfig.me
```

務必再測一次錯誤 password，預期 request 被拒絕。兩個 proxy 的正確請求都應顯示
相同 VPN 出口 IP。

## LAN／Internet exposure

安全順序：

1. 先填入 HTTP 與 SOCKS5 兩組完整 credentials；
2. 將 `PROXY_BIND_ADDRESS` 設為特定 LAN address，只有必要時才用 `0.0.0.0`；
3. `make validate-compose`；
4. host firewall 只允許可信 source CIDR；
5. 啟動後測試匿名與錯誤 credentials 確實被拒絕。

範例 UFW 規則：

```bash
sudo ufw allow from 192.168.50.0/24 to any port 8888 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 1080 proto tcp
```

不要只依賴 proxy password 直接暴露到公開 Internet。HTTP Basic 與 SOCKS5 username/
password 都不是 transport encryption；若需跨不可信網路，應在外層使用 VPN、SSH
tunnel 或其他加密 transport。

## 設定與憑證輪替

source 目錄是 bind mount。替換 `.ovpn`、certificate、key 或 credentials 後，不必
手動 restart；watcher 最晚在一個 polling interval 內偵測 fingerprint 改變並重啟
Gluetun。

建議使用同 filesystem 的 atomic replace：

```bash
install -m 600 /path/new-client.crt config/openvpn/client.crt.new
mv config/openvpn/client.crt.new config/openvpn/client.crt
```

修改後觀察：

```bash
docker compose logs -f ddns-watcher gluetun
```

## 強制重新解析與重連

一般情況不需要。診斷時可執行：

```bash
docker compose run --rm --no-deps ddns-init init
docker compose restart gluetun
```

第一行重新 render 並提交 state；第二行讓 Gluetun 立即讀取。這會造成短暫中斷。

## 升級

1. 在 branch 或 staging 更新 `.env` 的 version tag。
2. 閱讀四個上游 release notes。
3. 執行 `make check`。
4. 在 target host pull 並 recreate。

```bash
make check
docker compose pull
docker compose up -d --force-recreate --wait --wait-timeout 180
```

不要使用 `docker compose up --build`；repository 沒有 build context。

### Rollback

把 `.env` image tag 改回已知正常版本：

```bash
docker compose pull
docker compose up -d --force-recreate --wait --wait-timeout 180
```

`vpn-state` 與 source profile 向後相容，rollback 不需要資料 migration。

## Host reboot

long-running services 使用 `restart: unless-stopped`，Docker daemon 重啟後會自動恢復。
`vpn-state` 保留最後 profile；watcher 啟動後會再次解析 DNS 和 fingerprint。如果 host
停機期間 DDNS 已改變，最多一個 polling interval 內會 render 並重啟 Gluetun。

## 停止與移除

保留 runtime state：

```bash
make down
```

連衍生 state volume 一起刪除：

```bash
make clean
```

source `config/openvpn` 不會被刪除。

## 故障排除

### `ddns-init` 是 Exited

先看 exit code：

```bash
docker compose ps --all ddns-init
docker compose logs ddns-init
```

`Exited (0)` 正常；非 0 才是失敗。

### 找不到 profile

```text
level=ERROR OpenVPN profile not found: /source/client.ovpn
```

確認 `.env` 的 host directory 與 filename：

```bash
ls -la config/openvpn
docker compose config | grep -A5 '/source'
```

### 多個 remote 被拒絕

```text
expected exactly one active remote directive ... found 2
```

Gluetun custom profile 只採用第一個 remote。本專案 fail-fast，不假裝額外 remote 有
failover。建立一份只保留目標 DDNS hostname 的 deployment profile。

### Relative reference 不存在

```text
ca references an unreadable file: /source/ca.crt
```

將檔案放進 `OPENVPN_CONFIG_DIR`，修正 profile 路徑與大小寫。container 不會看到該
目錄以外的 host file。

### Init 一直重試 DNS

```bash
docker compose logs -f ddns-init
```

確認 hostname：

```bash
docker compose run --rm --no-deps ddns-init validate
```

如需指定 resolver，在 `.env` 設定 IPv4：

```dotenv
DDNS_RESOLVER=1.1.1.1
```

接著 recreate init／stack。不要把 `DDNS_OVERRIDE_IPS` 當成 production 解法；它會
完全繞過 DNS。

### Watcher 偶爾記錄 DNS warning

單次 warning 不會中斷 tunnel，通常不需人工處理。若長期持續：

- 檢查 host／Docker DNS；
- 檢查指定 resolver 的 UDP/TCP 53 是否可達；
- 確認 DDNS record 仍有 IPv4 A record；
- 觀察 Gluetun health 是否同時惡化。

### Gluetun 不健康

```bash
docker compose logs --tail=200 gluetun
docker inspect --format '{{json .State.Health}}' ddns-openvpn-proxy | jq
```

常見原因：錯誤憑證、provider server 不可達、cipher 不相容、host firewall、TUN
device、或 DDNS 新 IP 尚未提供 OpenVPN service。

### Watcher 無法 restart

```bash
docker compose ps docker-socket-proxy ddns-watcher
docker compose logs docker-socket-proxy ddns-watcher
```

檢查：

- `/var/run/docker.sock` 存在且 Docker daemon 可用；
- socket proxy healthy；
- `GLUETUN_CONTAINER_NAME` 與 Gluetun `container_name` 相同；
- `ddns-watcher` 同時加入 default 與 `docker-api` networks；
- SELinux/AppArmor 是否阻擋 socket proxy。

### SOCKS5 container restarting

```bash
docker compose logs vproxy
```

最常見是只設定了 `SOCKS5_USER` 或 `SOCKS5_PASSWORD` 其中一個。補齊兩者，或兩者
都清空，再 recreate。

### Port 可連線但沒有流量

listener healthy 不代表 VPN healthy。先看 Gluetun：

```bash
docker compose ps gluetun vproxy
docker compose logs --tail=200 gluetun
```

也確認 Gluetun environment 保留 `FIREWALL_INPUT_PORTS: "1080"`；否則 SOCKS5
sidecar listener 會被 Gluetun firewall 阻擋。

### Port 已被使用

```text
Bind for 127.0.0.1:8888 failed: port is already allocated
```

修改 host-side port：

```dotenv
HTTP_PROXY_PORT=18888
SOCKS5_PROXY_PORT=11080
```

container 內仍固定使用 `8888` 與 `1080`。
