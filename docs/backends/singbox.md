# sing-box backend

`VPN_TYPE=singbox`、stack file `docker-compose.singbox.yml`。適用於 sing-box
支援的所有 outbound：Shadowsocks、VMess、VLESS（含 Reality）、Trojan、Hysteria2、
TUIC、ShadowTLS、AnyTLS、SSH、HTTP／SOCKS upstream。

成熟度：**Beta**。helper 契約、Compose 契約與**真實資料路徑**（本機 Shadowsocks
server → mixed inbound → 認證 → outbound）有自動測試；真實 server 的連線需要在
staging 驗收。

## 上游元件

| 元件 | 版本 | 責任 |
| --- | --- | --- |
| [sing-box](https://sing-box.sagernet.org/) | `ghcr.io/sagernet/sing-box:v1.14.2`（官方，multi-arch） | outbound、mixed inbound（HTTP＋SOCKS5）、DNS、Clash API |

## 設計

sing-box 以 **proxy-only** 模式執行：沒有 TUN、沒有 `NET_ADMIN`、`cap_drop: ALL`、
read-only root。流量只會從 stack 管理的 inbound 進入並交給 `vpn` outbound；
沒有 direct outbound，所以 tunnel 斷線時連線失敗而不會外洩。

Stack 在啟動時產生 `00-managed.json` 並與 helper render 的 `10-profile.json` 一起
載入（`sing-box -C`）：

| 區塊 | 由誰提供 | 內容 |
| --- | --- | --- |
| `outbounds` | **你的 profile** | 至少一個 `"tag": "vpn"` 的 outbound，`server` 為 DDNS hostname |
| `inbounds` | stack | `:8888` 與 `:1080` 兩個 mixed inbound（各自同時接受 HTTP 與 SOCKS5），users 來自 `.env` |
| `dns` | stack | client 的域名查詢經 `vpn` outbound 送到 `SINGBOX_DNS_SERVER`（不外洩） |
| `route` | stack | `final: vpn`、`default_domain_resolver: local-dns` |
| `log` / `experimental.clash_api` | stack | log level、`:9090` Clash API（只在 Compose 內部網路，供 watcher 就緒探測） |

sing-box 依檔名排序合併多個設定檔，字母序最前者的 scalar 優先、array 串接；
`00-` 前綴保證 stack 的值優先。啟動前會執行 `sing-box check`，設定錯誤時
container 立即退出。

## Profile

`VPN_CONFIG_DIR/VPN_CONFIG_FILE`（預設 `./config/sing-box/config.json`）：

```json
{
  "outbounds": [
    {
      "type": "trojan",
      "tag": "vpn",
      "server": "vpn.example.com",
      "server_port": 443,
      "password": "REPLACE_WITH_YOUR_TROJAN_PASSWORD",
      "tls": { "enabled": true, "server_name": "vpn.example.com" }
    }
  ]
}
```

規則（詳見 [spec.md §5.4](../spec.md)）：

- 必須有 `"tag": "vpn"` 的 outbound；不得含 `"inbounds"`；`"dns"`／`"route"` 會被
  stack 的值覆蓋並記錄 WARN。
- helper 會把 `"server": "vpn.example.com"` 改成解析到的 IP。**使用 TLS 的 outbound
  必須明確設定 `tls.server_name`**（Reality 也是），否則憑證驗證會對 IP 失敗。
- profile 裡有多個 hostname 形式的 `"server"`（例如自訂 DNS server）時，必須以
  `DDNS_HOSTNAME` 指定要監看的那一個。
- `certificate_path`、`key_path` 相對路徑以 profile 目錄為基準。
- 可以有多個 outbound（例如 `vpn` 是 `selector`／`urltest` 而實際 server 在其他
  outbound），但被改寫的 `server` 只會是 DDNS hostname 那個；其他 server 若是
  hostname 需要 `DDNS_HOSTNAME`。

## `.env`

```dotenv
VPN_TYPE=singbox
COMPOSE_FILE=docker-compose.singbox.yml
VPN_CONFIG_DIR=./config/sing-box
VPN_CONFIG_FILE=config.json

HTTPPROXY_USER=http-user
HTTPPROXY_PASSWORD=replace-with-a-long-random-password
SOCKS5_USER=socks-user
SOCKS5_PASSWORD=replace-with-another-long-random-password
```

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `SINGBOX_DNS_SERVER` | `1.1.1.1` | 經 tunnel 使用的 UDP DNS server |
| `SINGBOX_LOG_LEVEL` | `info` | sing-box log level |
| `SINGBOX_HEALTH_URL` | `http://cp.cloudflare.com/generate_204` | container healthcheck 經 `:1080` inbound 抓取的 URL |
| `SINGBOX_HEALTH_PROBE` | Clash API delay URL | watcher 的就緒探測（見 spec §7.3） |
| `SINGBOX_IMAGE` | `ghcr.io/sagernet/sing-box:v1.14.2` | image pin |
| `VPN_CONTAINER_NAME` | `ddns-singbox-proxy` | restart target |
| `HTTPPROXY` | `on` | `off` 時不建立 `:8888` inbound |

Proxy 認證與公開綁定規則與 Gluetun backend 相同：非 loopback 綁定時兩組 credentials
都必須設定。

## Runtime 行為

- `ddns-init` 驗證並 render `/state/runtime/vpn.conf`。
- `singbox` container 產生 managed 設定、`sing-box check`、`sing-box run`。
- healthcheck：`http_proxy=http://127.0.0.1:1080`（含 SOCKS5 credentials 的
  `Proxy-Authorization`）以 `wget` 抓取 `SINGBOX_HEALTH_URL`，證明 inbound →
  outbound → server 的資料路徑可用。
- watcher 重啟 container 後，以 Clash API `/proxies/vpn/delay` 經 `vpn` outbound
  抓取 URL，成功才提交新的 IP。

## 限制

- 只改寫 `"server"` 欄位；其他含 hostname 的欄位（`server_name`、`sni`、
  Reality `server_name`）保持原樣，這正是 TLS 驗證需要的行為。
- UDP-based 傳輸（Hysteria2、TUIC、WireGuard outbound）在 IP 改變後需要 watcher
  重啟才會重連；TCP-based 傳輸在重啟前的新連線會失敗直到重啟完成。
- Clash API `:9090` 沒有 secret，但只在 Compose 內部網路可達；不要把其他 container
  加入此 stack 的 default network。
- SOCKS5 UDP ASSOCIATE 未納入契約（inbound 支援，但 host 只 publish TCP）。

## 驗證

```bash
make validate
make up
curl -x http://127.0.0.1:8888 -U 'http-user:PASSWORD' https://ifconfig.me
curl --socks5-hostname 127.0.0.1:1080 -U 'socks-user:PASSWORD' https://ifconfig.me
docker compose logs -f singbox ddns-watcher
```
