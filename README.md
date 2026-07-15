# DDNS VPN Proxy

以純 Docker Compose 部署的 DDNS-aware OpenVPN／WireGuard HTTP／SOCKS5 proxy。
專案不含 Dockerfile、不建置自有 image；遠端主機只要放入 VPN profile，便能直接
`docker compose up`。

Gluetun 的 custom provider 要求 OpenVPN `remote` 或 WireGuard `Endpoint` 在建立
firewall 前就是 IP，無法直接使用 DDNS hostname。本專案只補上這個缺口：解析
hostname、產生 Gluetun 可讀的 runtime profile，並在 A record 或 profile／憑證改變
時安全重啟 Gluetun，等 tunnel 恢復健康後再重啟共享其 network namespace 的 vproxy。
VPN、kill switch、連線健康檢查、HTTP proxy 與 SOCKS5 都交給成熟的上游服務。

![DDNS VPN Proxy architecture](docs/assets/architecture.svg)

## 特色

- **零 build**：只拉取有版本標籤的 Gluetun、Docker CLI、vproxy 與 Docker
  Socket Proxy image。
- **可直接部署**：`cp .env.example .env` 後執行 `docker compose up -d --wait`。
- **先準備、後啟動**：`ddns-init` 成功解析並產生 profile 前，Gluetun 不會啟動。
- **不中斷優先**：暫時 DNS 失敗時保留現有 tunnel，不覆寫 profile、不重啟 VPN。
- **雙 VPN 協定**：以 `VPN_TYPE=openvpn|wireguard` 選擇協定，共用相同 DDNS、原子
  寫入與安全 restart lifecycle。
- **自動恢復**：DDNS IP、`.ovpn`、`wg0.conf` 或 OpenVPN 引用的憑證／金鑰改變後，
  原子更新 runtime profile，依序重啟 Gluetun、等待 healthy、重啟 vproxy。
- **不因 DNS round-robin 抖動**：舊 IP 仍在 A record 集合內時繼續使用；只有
  舊 IP 消失才切換。
- **縮小 Docker socket 權限**：watcher 不直接掛載 socket；精確 HAProxy allowlist
  只允許內部網路的 ping 與指定 Gluetun／vproxy container restart，其他 container
  以及 start、stop、kill、remove、inspect 與其餘 Docker API 全部拒絕。
- **安全預設**：HTTP 與 SOCKS5 port 只綁定 `127.0.0.1`；所有非 VPN container 先
  `cap_drop: ALL`，只有 bind-mount readers 加回 `DAC_READ_SEARCH`，全部啟用
  `no-new-privileges`。
- **雙 proxy**：Gluetun 內建 HTTP proxy `:8888`，vproxy 提供 SOCKS5 `:1080`；
  兩者皆由同一個 VPN network namespace 出口。

## 支援範圍

| 項目 | 支援內容 |
| --- | --- |
| VPN | OpenVPN custom profile 或 WireGuard single-peer profile，IPv4 endpoint |
| DDNS | 單一 hostname，可回傳一個或多個 IPv4 A record |
| Profile | 一個啟用中的 OpenVPN `remote`，或一個 WireGuard `[Peer]`／`Endpoint` |
| Proxy | HTTP CONNECT、SOCKS5 TCP CONNECT |
| 平台 | Linux Docker Engine、Compose v2、`/dev/net/tun` |
| 架構 | 上游 image 支援的 amd64、arm64 等平台 |

IPv6 endpoint、OpenVPN multi-remote、WireGuard multi-peer 與 SOCKS5 UDP ASSOCIATE
不在目前契約內。這個範圍刻意保持小而明確，避免表面支援實際不可靠的 failover。

## 五分鐘部署

### 1. 準備環境

需要 Linux 主機、Docker Engine、Docker Compose v2，以及可用的 `/dev/net/tun`：

```bash
docker version
docker compose version
test -c /dev/net/tun
```

### 2. 放入 VPN profile

OpenVPN：

```bash
mkdir -p config/openvpn
cp /path/to/your-provider.ovpn config/openvpn/client.ovpn
cp /path/to/ca.crt config/openvpn/       # profile 有引用時才需要
cp /path/to/client.key config/openvpn/   # profile 有引用時才需要
```

Profile 必須保留 DDNS hostname，且只有一個啟用中的 `remote`：

```ovpn
client
proto udp
remote vpn.example.com 1194 udp
resolv-retry infinite
ping 10
ping-restart 60
persist-key
persist-tun
```

相對路徑可以保留。helper 會驗證檔案存在，並在 runtime profile 中轉成 container
內的絕對路徑：

```ovpn
ca ca.crt
cert client.crt
key client.key
```

若 profile 有 `auth-user-pass`，請在 `.env` 設定 Gluetun 使用的 credentials；Gluetun
會覆寫 directive 中的 file path：

```dotenv
OPENVPN_USER=vpn-user
OPENVPN_PASSWORD=replace-with-the-vpn-password
```

WireGuard 則放入一份只有一個 `[Peer]` 的標準 config：

```bash
mkdir -p config/wireguard
cp /path/to/wg0.conf config/wireguard/wg0.conf
chmod 600 config/wireguard/wg0.conf
```

```ini
[Interface]
PrivateKey = replace-with-client-private-key
Address = 10.0.0.2/32

[Peer]
PublicKey = replace-with-server-public-key
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
```

Gluetun 的 `WIREGUARD_CONF_SECRETFILE` 只匯入 key、address、public key、preshared key
與 endpoint；`AllowedIPs`、keepalive、MTU 與 implementation 由 `.env` 的
`WIREGUARD_*` 變數控制。

### 3. 建立設定

```bash
cp .env.example .env
```

OpenVPN 本機部署可保留預設：

```dotenv
VPN_TYPE=openvpn
VPN_CONFIG_DIR=./config/openvpn
VPN_CONFIG_FILE=client.ovpn
PROXY_BIND_ADDRESS=127.0.0.1
```

WireGuard 改成：

```dotenv
VPN_TYPE=wireguard
VPN_CONFIG_DIR=./config/wireguard
VPN_CONFIG_FILE=wg0.conf
WIREGUARD_ALLOWED_IPS=0.0.0.0/0
WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL=25s
```

若要讓 LAN 其他主機連線，請先設定兩組 proxy credentials，再將 bind address 改成
LAN interface 或 `0.0.0.0`：

```dotenv
PROXY_BIND_ADDRESS=0.0.0.0

HTTPPROXY_USER=http-user
HTTPPROXY_PASSWORD=replace-with-a-long-random-password

SOCKS5_USER=socks-user
SOCKS5_PASSWORD=replace-with-another-long-random-password
```

`make validate-compose` 會拒絕「公開綁定但沒有完整 credentials」的設定。仍應使用
host firewall 只允許可信來源網段。即使跳過 Make 直接啟動，`ddns-init` gate 也只會
收到 credential-presence boolean，並在公開 bind 缺少 authentication 時 fail-closed。

### 4. 驗證並啟動

有 Make 的主機：

```bash
make validate
make up
```

只使用 Compose 也可以；`ddns-init` 本身就是啟動 gate：

```bash
docker compose pull
docker compose up -d --wait --wait-timeout 180
```

此流程只會 pull image，不會 build：

```bash
docker compose config | grep -n 'build:'
# 正常結果：沒有輸出
```

### 5. 驗證 proxy

```bash
docker compose ps
docker compose logs --tail=50 ddns-init gluetun ddns-watcher vproxy

curl -x http://127.0.0.1:8888 https://ifconfig.me
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
```

有啟用 authentication 時：

```bash
curl -x http://127.0.0.1:8888 \
  -U 'http-user:http-password' https://ifconfig.me

curl --socks5-hostname 127.0.0.1:1080 \
  -U 'socks-user:socks-password' https://ifconfig.me
```

兩個結果都應是 VPN 出口 IP。使用 `--socks5-hostname` 可讓目的 hostname 由 proxy
端解析，避免 client 端 DNS lookup 繞過 proxy。

## DDNS 變更時會發生什麼

![DDNS detection and recovery flow](docs/assets/ddns-recovery.svg)

1. watcher 每 `DDNS_POLL_SECONDS` 秒解析一次 DDNS，並計算 profile（以及 OpenVPN
   引用檔案）的 SHA-256 fingerprint。
2. DNS 查詢失敗時只記錄 warning，保留現有 tunnel，下一輪再試。
3. IP 與 fingerprint 都未改變時只更新 heartbeat，不重啟。
4. 有變化時先在 named volume 內寫入暫存檔，再用 atomic rename 取代 runtime
   profile。
5. watcher 經 `docker-socket-proxy` 呼叫 Gluetun restart，再輪詢 Gluetun 自己的 health
   endpoint。
6. Gluetun 恢復 healthy 後 restart vproxy，並從 Gluetun service address 確認 `:1080`
   listener 已出現在新的 network namespace。
7. 兩個 restart 都成功後才提交新的 `last-ip` 與 fingerprint；任一步失敗都保留舊
   狀態，下一輪完整重試。
8. vproxy healthcheck 同時驗證 SOCKS listener、Gluetun health、VPN interface 與 route。

## 常用操作

```bash
make help
make status
make logs
make restart
make down       # 保留 runtime state volume
make clean      # 同時刪除可重新產生的 runtime state
make check      # Compose、行為測試與真實 container 契約測試
```

等價的 Compose 指令可參考 [操作手冊](docs/operations.md)。

## Production checklist

- 使用真實 provider profile，移除範例憑證 placeholder。
- `.env` 不進版控；proxy 對外開放時兩組 authentication 都要完整設定。
- 使用 host firewall 限制 `8888/tcp` 與 `1080/tcp` 的來源。
- 保留版本固定的 image tag；升級時先跑 `make check`，再 `docker compose pull`。
- 監控 `gluetun`、`vproxy`、`ddns-watcher` 的 Docker health status。
- 收集 `level=ERROR`、`level=WARN`、`restarting VPN` 與 container restart 記錄。
- 確認 Docker daemon socket 只有 `docker-socket-proxy` 掛載，且 `docker-api` network
  沒有 published port。
- 定期測試錯誤 credentials 會被拒絕，並比對 HTTP／SOCKS5 的出口 IP。

## 文件

- [架構與設計決策](docs/architecture.md)
- [部署、升級與故障排除](docs/operations.md)
- [測試策略與驗收範圍](docs/testing.md)
- [可編輯架構圖](docs/assets/architecture.drawio)
- [可編輯恢復流程圖](docs/assets/ddns-recovery.drawio)

## 上游元件

| 元件 | 預設版本 | 責任 |
| --- | --- | --- |
| [Gluetun](https://github.com/qdm12/gluetun) | `v3.41.1` | OpenVPN／WireGuard、kill switch、health、HTTP proxy |
| [Docker CLI](https://hub.docker.com/_/docker) | `29.6.1-cli-alpine3.24` | 執行 POSIX DDNS helper 與 restart client |
| [vproxy](https://github.com/0x676e67/vproxy) | `v2.5.5` | SOCKS5 proxy |
| [Docker Socket Proxy](https://github.com/Tecnativa/docker-socket-proxy) | `v0.4.2` | 限制 Docker API 權限 |

版本集中在 `.env`，可明確 review 後升級，不使用 `latest` 或其他 moving tag。

## License

[MIT](LICENSE)
