# OpenConnect backend

`VPN_TYPE=openconnect`、stack file `docker-compose.openconnect.yml`。適用於
Cisco AnyConnect／ocserv、Juniper Network Connect、Palo Alto GlobalProtect、Pulse
Connect Secure、F5 BIG-IP、FortiGate SSL VPN、Array Networks。

成熟度：**Beta**。helper 契約、Compose 契約與 container 啟動行為有自動測試；真實
gateway 的連線需要依 [testing.md](../testing.md) 的驗收清單在 staging 完成。

## 上游元件

| 元件 | 版本 | 責任 |
| --- | --- | --- |
| [openconnect-proxy](https://github.com/wazum/openconnect-proxy) | `wazum/openconnect-proxy:2.1.0`（OpenConnect v9.12，amd64／arm64） | tunnel、tunnel gate、tinyproxy HTTP `:8888`、microsocks SOCKS5 `:8889` |

## 為什麼需要 helper

OpenConnect 本身接受 hostname，但：

1. 建立連線後 IP 改變時，內建的 reconnect 不保證重新解析 DNS；
2. 使用 `--servercert` pin 或 `cafile` 時，TLS 驗證必須對 hostname 進行，不能直接
   改連 IP。

helper 因此在 runtime profile 附加 `resolve=HOST:IP`：OpenConnect 連到 DDNS 解析
到的 IP，仍以 HOST 驗證憑證與送出 SNI。A record 改變時 watcher 重啟 container，
OpenConnect 以新的 `resolve=` 重新連線。

## Profile

`VPN_CONFIG_DIR/VPN_CONFIG_FILE`（預設 `./config/openconnect/client.conf`）是
OpenConnect 的 `--config` 格式：每行一個 long option、不加 `--`：

```text
protocol=anyconnect
servercert=pin-sha256:REPLACE_WITH_THE_GATEWAY_CERTIFICATE_PIN
no-dtls
```

規則（詳見 [spec.md §5.3](../spec.md)）：

- gateway 用 `.env` 的 `OPENCONNECT_SERVER`／`OPENCONNECT_PORT`，因為 OpenConnect
  的 config 格式無法表示 URL；
- 不得含 `config`、`resolve`、`user`、`passwd-on-stdin`、`cookie-on-stdin`、
  `background`、`interface`、`script-tun`，這些由 stack 管理；
- `cafile`、`certificate`、`sslkey`、`mca-certificate`、`mca-key` 的相對路徑以
  profile 目錄為基準，檔案必須存在；
- 未知選項會讓 OpenConnect 啟動失敗（fail-fast）。

取得 gateway 憑證 pin：

```bash
openconnect --servercert=x https://vpn.example.com 2>&1 | grep 'pin-sha256'
```

## `.env`

```dotenv
VPN_TYPE=openconnect
COMPOSE_FILE=docker-compose.openconnect.yml
VPN_CONFIG_DIR=./config/openconnect
VPN_CONFIG_FILE=client.conf

OPENCONNECT_SERVER=vpn.example.com
OPENCONNECT_PORT=443
OPENCONNECT_USER=alice
OPENCONNECT_PASSWORD=replace-with-the-vpn-password
# 需要 TOTP 時：
#OPENCONNECT_TOTP_SECRET=BASE32SECRET
# 額外 CLI 旗標（會接在 --config 之後）：
#OPENCONNECT_OPTIONS=--authgroup=Employees
```

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `OPENCONNECT_SERVER` | 空（必填） | gateway hostname，同時是預設的 DDNS hostname |
| `OPENCONNECT_PORT` | `443` | gateway port |
| `OPENCONNECT_USER` / `OPENCONNECT_PASSWORD` | 空 | 成對；兩者皆空表示只用憑證登入 |
| `OPENCONNECT_TOTP_SECRET` | 空 | base32 TOTP secret，image 會在每次連線產生 code |
| `OPENCONNECT_OPTIONS` | 空 | 追加給 `openconnect` 的旗標 |
| `OPENCONNECT_RECONNECT_DELAY` | `30` | OpenConnect 程序結束後的重試間隔（秒） |
| `OPENCONNECT_IMAGE` | `wazum/openconnect-proxy:2.1.0` | image pin |
| `VPN_CONTAINER_NAME` | `ddns-openconnect-proxy` | restart target |

## Runtime 行為

- `ddns-init` render `/state/runtime/vpn.conf`（原 profile＋`non-inter`＋
  `resolve=HOST:IP`）與 `/state/runtime/vpn.env`（`DDNS_VPN_URL=https://HOST:PORT`）。
- `openconnect` container 的 entrypoint 先 `. /state/runtime/vpn.env`，把
  `OPENCONNECT_URL` 與 `--config=/state/runtime/vpn.conf` 交給上游 entrypoint。
- container 需要 `NET_ADMIN` 與 `/dev/net/tun`，**不**使用 `privileged`。
- **Tunnel gate**：`tun0` 未 UP 前，`:8888`／`:8889` 的連線被 iptables REJECT
  （TCP RST）。watcher 的就緒探測 `tcp://openconnect:8888` 因此只有在 tunnel
  建立後才成功。
- healthcheck：`tun0` UP、預設 route 走 `tun0`、兩個 listener 存在。
- **透明與無痕**：上游 image 的 tinyproxy 會加 `Via: 1.1 tinyproxy`、記錄每條連線，
  且 `MaxClients 10`（瀏覽器很快用完）；microsocks 未加 `-q` 時會記錄每個目的地。
  stack 在 container layer 上改為 `DisableViaHeader Yes`、`LogLevel Error`、
  `MaxClients 100`，並以 wrapper 讓 microsocks 帶 `-q` 啟動；重複 restart 仍是冪等。

## 限制

- **只能 loopback**：上游 image 的 tinyproxy 與 microsocks 沒有認證。
  `PROXY_BIND_ADDRESS` 必須是 `127.0.0.1`；validator 與 helper 都會拒絕其他值。
  需要 LAN 存取時，請在 host 上以 SSH tunnel 或其他認證層轉發。
- host 端 `SOCKS5_PROXY_PORT` 對應 container 的 `8889`（不是 `1080`）。
- Tunnel gate 只保護 proxy port；container 內其他程序在 tunnel 斷線時仍可經
  docker bridge 對外，因此不要在此 container 內執行其他工作負載。
- 互動式 MFA（非 TOTP）無法在 container 內完成；`non-inter` 會讓連線失敗並進入
  重試。
- 只用憑證登入（`OPENCONNECT_USER` 空）未經真實驗證。

## 驗證

```bash
make validate
make up
curl -x http://127.0.0.1:8888 https://ifconfig.me
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
docker compose logs -f openconnect ddns-watcher
```

Tunnel 未建立時 `curl` 會收到 connection reset；這是 gate 的預期行為，請看
`openconnect` log 找認證或憑證錯誤。
