# DDNS VPN Proxy 規格

本文件是本專案的正式契約（normative specification）。README 與其他文件是說明性
的；若有衝突，以本文件為準。文中「必須」「不得」「應」對應 RFC 2119 的 MUST、
MUST NOT、SHOULD。

## 1. 目的與範圍

### 1.1 問題

成熟的 VPN client runtime（Gluetun 的 custom provider、OpenConnect 的憑證驗證、
sing-box 的 outbound）在啟動時需要一個**已解析的 IPv4 endpoint**，或在 endpoint IP
改變後不會自行重新連線。自架 VPN server 常只有 DDNS hostname，且 IP 會在不通知
client 的情況下改變。

### 1.2 本專案負責

1. 驗證 operator 提供的 VPN profile 與環境設定，錯誤時在啟動前失敗。
2. 解析 DDNS hostname，產生 backend 可直接使用的 **runtime profile**。
3. 監看 A record 與 profile／憑證的變化，在變化時以固定順序安全重啟 backend，
   並只在整條 restart chain 成功後提交狀態。
4. 以最小權限完成上述工作：helper 不持有 secrets、不直接掛載 Docker socket。

### 1.3 本專案不負責

VPN 協定本身、kill switch、tunnel health、HTTP／SOCKS5 proxy 實作，全部交給
version-pinned 的上游 image。本專案不建置任何 image。

### 1.4 明確不支援

- IPv6 endpoint（只解析 A record）。
- OpenVPN multi-remote、WireGuard multi-peer、多個 DDNS hostname 的 failover。
- Hot reload：endpoint 改變一律以 container restart 處理。
- SOCKS5 UDP ASSOCIATE。
- rootless Docker、Docker Desktop、非標準 socket path。

## 2. 術語

| 術語 | 定義 |
| --- | --- |
| **VPN type** | `VPN_TYPE` 的值，決定使用哪個 profile adapter：`openvpn`、`wireguard`、`openconnect`、`singbox` |
| **Backend** | 實際建立 tunnel 並提供 proxy 的 runtime container 組合：`gluetun`、`openconnect`、`singbox` |
| **Stack file** | 定義一個 backend 完整拓樸的 Compose 檔：`docker-compose.yml`（gluetun）、`docker-compose.openconnect.yml`、`docker-compose.singbox.yml` |
| **Adapter** | `scripts/adapters/<VPN_TYPE>.sh`，實作特定 profile 格式的驗證、fingerprint 與 render |
| **Helper** | `scripts/ddns-vpn.sh` 與其 lib／adapters，在 stock `docker:cli` image 內執行的 POSIX sh 程式 |
| **Source profile** | operator 放在 `VPN_CONFIG_DIR/VPN_CONFIG_FILE` 的原始設定，保留 DDNS hostname |
| **Runtime profile** | helper 從 source profile 產生、已將 hostname 換成 IP 的檔案：`/state/runtime/vpn.conf`（部分 backend 另有 `vpn.env`） |
| **Endpoint host** | adapter 從 source profile 或環境取出的 VPN server hostname |
| **DDNS hostname** | 實際被監看的 hostname；預設等於 endpoint host，可由 `DDNS_HOSTNAME` 覆寫 |
| **Restart chain** | 變更後的固定重啟順序：VPN container → 就緒探測 → （可選）sidecar → 就緒探測 |
| **Sidecar** | 與 VPN container 共用 network namespace 的第二個 container（目前只有 gluetun backend 的 vproxy） |

## 3. 系統模型

```text
                 .env  ──►  stack file (docker-compose*.yml)
                                │  extends
                                ▼
                        compose/core.yml
                 ┌──────────────┼──────────────────┐
                 ▼              ▼                  ▼
            ddns-init      ddns-watcher     docker-socket-proxy
            (one-shot)     (long-running)   (restart-only API)
                 │              │                  ▲
                 │  render      │  watch/restart   │ RESTART_TARGETS
                 ▼              ▼                  │
            vpn-state volume ──────────► VPN container [+ sidecar]
              /state/runtime/vpn.conf         (backend)
```

### 3.1 VPN type 與 backend 對應

| `VPN_TYPE` | Backend | Stack file | Source profile 格式 | Proxy auth |
| --- | --- | --- | --- | --- |
| `openvpn` | gluetun | `docker-compose.yml` | OpenVPN client profile | 是 |
| `wireguard` | gluetun | `docker-compose.yml` | wg-quick single-peer profile | 是 |
| `openconnect` | openconnect | `docker-compose.openconnect.yml` | OpenConnect `--config` options file | 否（loopback-only） |
| `singbox` | singbox | `docker-compose.singbox.yml` | sing-box JSON（只含 outbounds） | 是 |

每個 stack file 必須在 helper 環境設定 `VPN_BACKEND`。helper 必須在 `VPN_TYPE`
所屬 backend 與 `VPN_BACKEND` 不同時以 exit 64 結束。

### 3.2 Service 集合

| Service | 來源 | 存在於 | 責任 |
| --- | --- | --- | --- |
| `ddns-init` | `compose/core.yml` | 所有 stack | 啟動前 validate、resolve、首次 render、seed state |
| `ddns-watcher` | `compose/core.yml` | 所有 stack | 週期性 resolve／fingerprint，觸發 restart chain |
| `docker-socket-proxy` | `compose/core.yml` | 所有 stack | 只允許 `/_ping` 與 `RESTART_TARGETS` 的 restart |
| `gluetun` | `docker-compose.yml` | gluetun | OpenVPN／WireGuard、firewall、health、HTTP proxy |
| `vproxy` | `docker-compose.yml` | gluetun | SOCKS5 sidecar（`network_mode: service:gluetun`） |
| `openconnect` | `docker-compose.openconnect.yml` | openconnect | OpenConnect tunnel、tunnel-gated HTTP／SOCKS5 |
| `singbox` | `docker-compose.singbox.yml` | singbox | sing-box outbound 與 stack 管理的 mixed inbound |

任何 service 不得使用 `build:`。repository 不得含 `Dockerfile`。

## 4. 設定契約

### 4.1 選擇 backend

- `VPN_TYPE`（預設 `openvpn`）是唯一的協定選擇來源。
- 非預設 backend 應在 `.env` 設定 `COMPOSE_FILE`，讓 `docker compose` 與 `make`
  使用對應 stack file。`scripts/validate-compose.sh` 必須在 `COMPOSE_FILE` 與
  `VPN_TYPE` 不一致時失敗。
- `VPN_CONFIG_DIR`（host 目錄）與 `VPN_CONFIG_FILE`（目錄內檔名）指定 source
  profile；profile 引用的所有檔案必須在同一目錄內。

### 4.2 通用變數

| 變數 | 預設 | 驗證 | 說明 |
| --- | --- | --- | --- |
| `DDNS_HOSTNAME` | 空 | 合法 hostname，不得為 IPv4 | 覆寫被監看的 hostname |
| `DDNS_RESOLVER` | 空 | IPv4 | 指定時以 `nslookup` 查詢該 server，否則 `getent ahostsv4` |
| `DDNS_POLL_SECONDS` | `60` | 整數 ≥ 10 | watcher 輪詢間隔 |
| `DDNS_INIT_RETRY_SECONDS` | `5` | 整數 ≥ 1 | init 階段 DNS 失敗重試間隔 |
| `DDNS_OVERRIDE_IPS` | 空 | 逗號／空白分隔的 IPv4 | 僅供測試診斷，完全繞過 DNS |
| `PROXY_BIND_ADDRESS` | `127.0.0.1` | — | host 端 bind address |
| `HTTP_PROXY_PORT` / `SOCKS5_PROXY_PORT` | `8888` / `1080` | — | host 端 port |
| `HTTPPROXY` | `on` | `on`／`off` | HTTP proxy 開關（gluetun、singbox） |
| `HTTPPROXY_USER` / `HTTPPROXY_PASSWORD` | 空 | 成對 | HTTP proxy 認證 |
| `SOCKS5_USER` / `SOCKS5_PASSWORD` | 空 | 成對 | SOCKS5 認證 |
| `VPN_CONTAINER_NAME` | 依 stack | `[A-Za-z0-9_.-]+`，不以 `-` 開頭 | restart chain 第一個 target |
| `VPN_RESTART_TIMEOUT_SECONDS` | `20` | 整數 ≥ 1 | `docker container restart --timeout` |
| `VPN_HEALTH_TIMEOUT_SECONDS` | `120` | 整數 ≥ 1 | 每個就緒探測的等待上限 |
| `LOG_MAX_SIZE` / `LOG_MAX_FILE` | `10m` / `3` | — | 所有 service 的 json-file rotation |
| `*_IMAGE` | 見 `.env.example` | 不得為 `latest`／`edge`／`master`／`main` | 上游 image pin |

### 4.3 Backend 專屬變數

**gluetun**：`OPENVPN_USER`、`OPENVPN_PASSWORD`（成對；profile 含 `auth-user-pass`
時必填）、`OPENVPN_VERBOSITY`、`WIREGUARD_ALLOWED_IPS`（非空）、
`WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL`、`WIREGUARD_MTU`（576..65535）、
`WIREGUARD_IMPLEMENTATION`（`auto`／`userspace`／`kernelspace`）、
`VPROXY_CONTAINER_NAME`（sidecar，必須與 `VPN_CONTAINER_NAME` 不同）、`VPROXY_LOG`
（預設 `warn`）、`BLOCK_MALICIOUS`（預設 `off`）、`PUBLICIP_ENABLED`（預設 `off`）。
`HTTPPROXY_STEALTH` 不再可設定（固定 `on`，見 §10.5）。

**openconnect**：`OPENCONNECT_SERVER`（必填，hostname）、`OPENCONNECT_PORT`
（預設 443）、`OPENCONNECT_USER`／`OPENCONNECT_PASSWORD`（成對）、
`OPENCONNECT_TOTP_SECRET`、`OPENCONNECT_OPTIONS`、`OPENCONNECT_RECONNECT_DELAY`。

**singbox**：`SINGBOX_DNS_SERVER`（預設 `1.1.1.1`）、`SINGBOX_LOG_LEVEL`（預設 `warn`）、
`SINGBOX_HEALTH_URL`、`SINGBOX_HEALTH_PROBE`。

### 4.4 Legacy alias

下列名稱仍被接受，新部署不應使用：

| Legacy | Canonical |
| --- | --- |
| `GLUETUN_CONTAINER_NAME` | `VPN_CONTAINER_NAME` |
| `GLUETUN_RESTART_TIMEOUT_SECONDS` | `VPN_RESTART_TIMEOUT_SECONDS` |
| `GLUETUN_HEALTH_TIMEOUT_SECONDS` | `VPN_HEALTH_TIMEOUT_SECONDS` |
| `GLUETUN_HEALTHCHECK_URL` | `VPN_HEALTH_PROBE` |
| `OPENVPN_CONFIG_DIR` / `OPENVPN_CONFIG_FILE` | `VPN_CONFIG_DIR` / `VPN_CONFIG_FILE` |
| `OPENVPN_SOURCE_CONFIG` / `OPENVPN_RENDERED_CONFIG` | `VPN_SOURCE_CONFIG` / `VPN_RENDERED_CONFIG` |
| `scripts/ddns-openvpn.sh` | `scripts/ddns-vpn.sh` |

### 4.5 Proxy 曝露政策

- 認證 pair 必須「兩者皆設」或「兩者皆空」。
- `PROXY_BIND_ADDRESS` 不是 `127.0.0.1` 時：SOCKS5 必須有認證；`HTTPPROXY=on` 時
  HTTP 也必須有認證。
- backend 不支援 proxy 認證時（openconnect），`PROXY_BIND_ADDRESS` 必須是
  `127.0.0.1`。
- 以上規則由 `scripts/validate-compose.sh`（rendered model）與 helper `validate`
  （只看 `*_CONFIGURED` 布林）各自獨立執行；跳過 Make 直接 `docker compose up`
  仍會 fail-closed。

## 5. Profile 契約

### 5.1 OpenVPN（`openvpn`）

- 恰好一個未註解的 `remote HOST [PORT] [PROTO]`；PORT 1..65535；PROTO 為 `udp`／
  `tcp`。
- `ca`、`cert`、`key`、`tls-auth`、`tls-crypt`、`tls-crypt-v2`、`crl-verify`、`dh`、
  `pkcs12`、`secret`、`askpass`、`http-proxy-user-pass` 的檔案引用必須可讀；
  相對路徑以 profile 目錄為基準，render 時改為絕對路徑。含引號的路徑 fail-fast。
- 含 `auth-user-pass` 時 `OPENVPN_USER`／`OPENVPN_PASSWORD` 必填。
- Render：只改寫 `remote` 的 HOST；其餘逐行保留。
- Fingerprint：profile 與所有被引用檔案的 SHA-256。

### 5.2 WireGuard（`wireguard`）

- 恰好一個 `[Interface]`（含一個 `PrivateKey`、一個 `Address`）與一個 `[Peer]`
  （含一個 `PublicKey`、一個 `Endpoint = HOST:PORT`）。
- Render：只改寫 `[Peer]` 內 `Endpoint` 的 HOST，保留 port 與行尾註解。
- Fingerprint：profile 的 SHA-256。
- `AllowedIPs`、keepalive、MTU 由 `.env` 的 `WIREGUARD_*` 決定；Gluetun 不從檔案
  匯入這些欄位。

### 5.3 OpenConnect（`openconnect`）

- 格式：OpenConnect `--config` 檔（每行一個 long option，無前導 `--`；接受
  `key=value`、`key = value`、`key value`、bare flag；`#` 註解）。
- Gateway 由 `OPENCONNECT_SERVER`／`OPENCONNECT_PORT` 提供（OpenConnect 的 config
  格式無法表示 URL）。
- 不得出現：`config`、`resolve`、`user`、`passwd-on-stdin`、`cookie-on-stdin`、
  `background`、`interface`、`script-tun`。
- `protocol` 若出現，必須是 `anyconnect`／`nc`／`gp`／`pulse`／`f5`／`fortinet`／
  `array`。
- `cafile`、`certificate`、`sslkey`、`mca-certificate`、`mca-key` 為檔案引用（含
  `:` 的 URI 值如 `pkcs11:` 除外），必須可讀，render 時改為絕對路徑。
- Render 產生兩個檔案：`vpn.conf`（原檔加上 `non-inter` 與 `resolve=HOST:IP`）與
  `vpn.env`（`DDNS_VPN_HOST`、`DDNS_VPN_PORT`、`DDNS_VPN_IP`、`DDNS_VPN_URL`，單引號
  quoted）。
- Fingerprint：profile 與被引用檔案的 SHA-256。

### 5.4 sing-box（`singbox`）

- 格式：sing-box JSON；格式化或 minified 皆可。
- 必須含 `"outbounds"` 與一個 `"tag": "vpn"` 的 outbound；不得含 `"inbounds"`。
  含 `"dns"` 或 `"route"` 時記錄 WARN（stack 管理的值優先）。
- Endpoint host：所有 `"server"` 字串值中非 IPv4 者。恰好一個時自動採用；多於一個
  時必須以 `DDNS_HOSTNAME` 指定，且該值必須出現在其中。
- `certificate_path`、`key_path` 為檔案引用，必須可讀，render 時改為絕對路徑。
- Render：把每個 `"server": "HOST"` 改為 `"server": "IP"`。TLS outbound 必須自行
  設定 `tls.server_name`，否則憑證驗證會對 IP 失敗。
- Fingerprint：profile 與被引用檔案的 SHA-256。
- Runtime 合併：backend container 以 `sing-box -C DIR` 載入 `00-managed.json`
  （stack 產生：log、dns、inbounds、route.final、clash_api）與 `10-profile.json`
  （runtime profile）。sing-box 依檔名排序、字母序最前者的 scalar 優先，array 串接；
  因此 managed 值必須以 `00-` 前綴保證優先。啟動前必須通過 `sing-box check`。

## 6. Runtime state 契約

`vpn-state` named volume 只含衍生資料，可刪除重建：

```text
/state/
├── ddns/
│   ├── last-ip              # 最後成功提交的 IPv4
│   ├── source.sha256        # 最後成功提交的 fingerprint
│   └── watcher-heartbeat    # watcher 最近一輪的 epoch seconds
└── runtime/
    ├── vpn.conf             # backend 讀取的 runtime profile
    └── vpn.env              # 部分 backend 讀取的環境片段（目前：openconnect）
```

- 所有寫入必須先寫同目錄暫存檔、`chmod 600`、再 `mv -f`（atomic rename）。
- Helper 對 `/state` 可寫；VPN container 對 `/state` 必須 read-only。
- Source profile 只以 read-only bind mount 出現在 `/source`。

## 7. 生命週期與狀態機

### 7.1 init（`ddns-init`，one-shot）

```text
validate ──► resolve ──(fail)──► sleep DDNS_INIT_RETRY_SECONDS ──► resolve …
               │(ok)
               ▼
   select_ip ──► render ──► write last-ip ──► write fingerprint ──► exit 0
```

- 設定錯誤：立即 exit 64，不重試。
- DNS 失敗：無限重試（暫時故障與永久錯誤刻意分開）。
- VPN service 必須 `depends_on: ddns-init: service_completed_successfully`。

### 7.2 watch（`ddns-watcher`，每 `DDNS_POLL_SECONDS`）

每輪取得三份證據：目前所有合法 IPv4 A record、已提交的 `last-ip`、目前
fingerprint。

| 條件 | 動作 | 提交 |
| --- | --- | --- |
| DNS 失敗或無合法 IPv4 | WARN、更新 heartbeat、保留一切 | 否 |
| `last-ip` 仍在 A record 集合內且 fingerprint 相同且 runtime profile 存在 | 只更新 heartbeat | 否 |
| `last-ip` 消失（address-change）或 fingerprint 改變（profile-change） | render → restart chain | chain 全部成功才提交 |

Address selection：去重排序後，若 `last-ip` 仍在集合內則沿用，否則取排序後第一筆。
DNS round-robin 的順序變化不得觸發 restart。

### 7.3 Restart chain

```text
docker container restart VPN_CONTAINER_NAME
  ──► wait VPN_HEALTH_PROBE (≤ VPN_HEALTH_TIMEOUT_SECONDS)
  ──► [SIDECAR_CONTAINER_NAME 存在時] docker container restart SIDECAR
        ──► wait SIDECAR_HEALTH_PROBE
  ──► write last-ip + fingerprint
```

- Probe 格式：`http://HOST:PORT/PATH`（`wget --spider`，2xx 為就緒）或
  `tcp://HOST:PORT`（`nc -z`）。
- 任一步失敗：runtime profile 已安全寫入但**不提交**；下一輪完整重試。
- gluetun backend 必須設定 sidecar（vproxy 不會因 Gluetun restart 自動重建
  namespace）。

各 backend 的就緒語意：

| Backend | `VPN_HEALTH_PROBE` | 就緒代表 |
| --- | --- | --- |
| gluetun | `http://gluetun:9999` | Gluetun health server 回報 tunnel 可用 |
| openconnect | `tcp://openconnect:8888` | tunnel gate 已開（tun0 UP 前所有 proxy 連線被 RST） |
| singbox | `http://singbox:9090/proxies/vpn/delay?…` | Clash API 經 `vpn` outbound 成功抓取 URL |

### 7.4 healthcheck（`ddns-watcher`）

heartbeat 年齡必須 ≤ `DDNS_POLL_SECONDS × 3 + VPN_HEALTH_TIMEOUT_SECONDS + 30`。
DNS 失敗不代表 watcher 不健康。

## 8. CLI 契約

```text
ddns-vpn.sh validate     驗證 profile 與環境；成功印出 configuration valid
ddns-vpn.sh render IP    不查 DNS，直接以 IP render runtime profile
ddns-vpn.sh init         §7.1
ddns-vpn.sh watch        §7.2 無限迴圈；WATCH_ONCE=1 時只跑一輪
ddns-vpn.sh watch-once   驗證後執行一輪 §7.2（診斷／測試）
ddns-vpn.sh healthcheck  §7.4
```

Exit code：`0` 成功；`1` runtime 失敗（例如 restart chain 未完成）；`64`
設定或用法錯誤。

Helper 只依賴 stock `docker:cli` alpine image 已有的 `awk`、`sed`、`grep`、
`sha256sum`、`getent`、`nslookup`、`wget`、`nc`、`docker`，不得在啟動時安裝套件。

## 9. Log 契約

```text
<UTC ISO-8601> level=<INFO|WARN|ERROR> <message> key=value ...
```

穩定的訊息與 key（可供監控比對）：

- `initializing vpn_type= backend= hostname= profile=`
- `rendered profile vpn_type= hostname= ip= output=`
- `watching hostname= interval= backend=`
- `DNS lookup failed hostname=`（WARN）
- `restarted VPN stack vpn_type= reason=<address-change|profile-change> hostname=`
  `old_ip= new_ip= vpn= sidecar=`
- `failed to restart … will retry`、`did not become ready … will retry`（ERROR）

IP 與 fingerprint 都不變時不得產生 INFO log。

## 10. 安全契約

### 10.1 Secrets 流向

- `OPENVPN_*`、`OPENCONNECT_*` credentials、`HTTPPROXY_*`、`SOCKS5_*`、TOTP secret
  只注入對應的 VPN／sidecar container。
- Helper 只接收 `*_CONFIGURED` 布林。Compose validator 必須拒絕 helper 環境中出現
  任何 `*PASSWORD`、`*PRIVATE_KEY`、`*PRESHARED_KEY`、`*TOTP_SECRET` 或 credential
  user 名稱。
- WireGuard PrivateKey／PresharedKey 只存在於檔案，不得進入 Compose environment。

### 10.2 Docker API

- 只有 `docker-socket-proxy` 掛載 `/var/run/docker.sock`（read-only）。
- `docker-api` network 必須 `internal: true`，沒有 published port。
- HAProxy policy 由 `docker/socket-proxy-haproxy.cfg.tmpl` 與 `RESTART_TARGETS`
  在啟動時 render：只允許 `GET|HEAD /_ping` 與
  `POST /containers/<target>/restart`（精確 string match，去除版本前綴），其餘一律
  deny。不得使用上游 `CONTAINERS`／`POST`／`ALLOW_RESTARTS` 粗粒度旗標。
- `RESTART_TARGETS` 必須等於 VPN container name 加（若有）sidecar name。

### 10.3 Container hardening

| 控制 | 範圍 |
| --- | --- |
| `no-new-privileges:true` | 所有 service |
| `cap_drop: [ALL]` | 所有非 VPN service；singbox backend 的 VPN container 亦然 |
| `cap_add: [DAC_READ_SEARCH]` | 只有 bind-mount reader：init、watcher、socket proxy |
| `cap_add: [NET_ADMIN]` + `/dev/net/tun` | 只有 gluetun 或 openconnect container |
| `privileged` | 不得使用 |
| `read_only: true` | init、watcher、socket proxy、vproxy、singbox |
| Version-pinned image | 所有 service |
| json-file log rotation | 所有 service |

### 10.4 Leak 模型

| Backend | Tunnel 斷線時 | 機制 |
| --- | --- | --- |
| gluetun | 無流量外洩 | Gluetun firewall（kill switch） |
| openconnect | proxy 連線被 RST | 上游 tunnel gate（iptables REJECT on 8888/8889 直到 tun0 UP） |
| singbox | 連線失敗 | 無 TUN、無 direct outbound；`route.final=vpn`；client DNS 經 `vpn` detour |

### 10.5 透明與無痕

Proxy 對目的端必須透明，且預設不在 host 留下瀏覽紀錄。Compose validator 強制下列
不可覆寫的 invariant：

| Backend | 透明（不改寫 request） | 不記錄目的地 |
| --- | --- | --- |
| gluetun | `HTTPPROXY_STEALTH=on`（否則加 `X-Forwarded-For: <client IP>`） | `HTTPPROXY_LOG=off` |
| openconnect | tinyproxy `DisableViaHeader Yes`（上游 image 預設加 `Via: 1.1 tinyproxy`） | tinyproxy `LogLevel Error`；microsocks `-q` |
| singbox | mixed inbound 本身不改寫 header | — |

可調整但預設安靜的設定：`VPROXY_LOG`、`SINGBOX_LOG_LEVEL` 預設 `warn`（`info`
以下每條連線都記錄目的地）。Gluetun 另外預設 `BLOCK_MALICIOUS=off`（不改寫 DNS
答案、不下載 blocklist）、`PUBLICIP_ENABLED=off`（每次連線不向第三方 echo 服務查詢
出口 IP），並固定 `VERSION_INFORMATION=off`、`STORAGE_FILEPATH=`（不查詢 GitHub、
不把 7 MB `servers.json` 寫入 container layer）。

### 10.6 資源預算

目標 host 可小至 1 vCPU／1 GB。每次 Docker healthcheck 都是一次 `runc exec`，
因此所有常駐 service 必須覆寫 healthcheck：啟動後 `interval` ≥ 30s，並以
`start_interval` 在 `start_period` 內快速探測，讓 `up --wait` 與 `depends_on:
service_healthy` 不變慢。Gluetun image 內建 5s healthcheck 的 `test` 保留，只覆寫
節奏。`docker-socket-proxy` 以單一 HAProxy process（無 master-worker）、
`nbthread 1`、`maxconn 32` 執行。

## 11. Health model

| Service | 機制 |
| --- | --- |
| `ddns-init` | one-shot；`Exited (0)` 是正常 |
| `ddns-watcher` | §7.4 heartbeat |
| `docker-socket-proxy` | `GET /_ping` |
| `gluetun` | 上游 healthcheck 指令（節奏見 §10.6）；`HEALTH_RESTART_VPN=on` |
| `vproxy` | `:1080` listener、Gluetun `:9999`、VPN interface 存在、預設 route 走該 interface |
| `openconnect` | `tun0` UP、預設 route 走 `tun0`、`:8888` 與 `:8889` listening |
| `singbox` | 經 `:1080` mixed inbound（含認證）抓取 `SINGBOX_HEALTH_URL` |

## 12. 相容性政策

- **向後相容**：`docker-compose.yml` 仍是 gluetun stack；既有 `.env`（含 legacy
  alias）與 `vpn-state` volume 不需 migration。
- **Deprecated**：§4.4 的 alias 與 `scripts/ddns-openvpn.sh` 至少保留一個 major
  版本。
- **Frozen**：`compat/watcher/` 是給更早期部署（仍 pull
  `ghcr.io/df-wu/ddns-openvpn-proxy-watcher` image）的 fail-safe watcher。它不再新增
  功能，只在上游 base image 有安全問題時重新發布；`Containerfile` 命名是為了不觸犯
  §3.2「不得含 Dockerfile」的 Compose-only 規則。
- **版本**：`CHANGELOG.md` 依 Keep a Changelog；改變本文件的任何 MUST 都是
  breaking change。

## 13. 擴充契約：新增一種 VPN 連線方式

新增 `VPN_TYPE=<type>` 需要完成以下全部項目，缺一不得合併：

1. **Adapter** `scripts/adapters/<type>.sh`（POSIX sh，只用 §8 列出的工具），實作：

   | 函式 | 契約 |
   | --- | --- |
   | `adapter_backend` | 印出 backend id |
   | `adapter_display_name` | 印出人類可讀名稱 |
   | `adapter_validate` | 驗證 `$source_config` 與環境；設定 `endpoint_host`（必要）與 `endpoint_port`；錯誤時 `die` |
   | `adapter_fingerprint` | 印出涵蓋 profile 與所有被引用檔案的 SHA-256 |
   | `adapter_render IP` | 以 `install_rendered` 原子寫入 `$rendered_config`（及需要時 `$rendered_env`） |

   可用的全域：`source_config`、`rendered_config`、`rendered_env`、`state_dir`、
   `vpn_type`；可用的 helper：`die`、`log`、`is_uint`、`is_ipv4`、
   `validate_hostname`、`validate_port`、`validate_source_file`、
   `resolve_reference`、`require_readable_reference`、`install_rendered`、
   `file_sha256`、`hash_file_list`。

2. **Core 登記**：`scripts/ddns-vpn.sh` 的 `load_adapter` allowlist；若是新
   backend，另加入 `backend_known` 與 `backend_supports_proxy_auth`。

3. **Stack file** `docker-compose.<backend>.yml`：以 `extends` 取用
   `compose/core.yml` 的三個 service；VPN service 必須符合 §3.2、§6、§7.3、§10；
   helper 環境必須設定 `VPN_BACKEND`、`VPN_TYPE`、`VPN_SOURCE_CONFIG`、
   `VPN_CONTAINER_NAME`、`VPN_HEALTH_PROBE`（與可選的 `SIDECAR_*`）；
   `docker-socket-proxy` 的 `RESTART_TARGETS` 必須列出相同 target。

4. **Validator**：`scripts/validate-compose.sh` 的 type→backend 對應、
   `expected_services`、`validate_<backend>` 函式與 proxy 曝露規則。

5. **測試**：`tests/helper.sh` 至少涵蓋 validate 成功、render、address-change、
   profile-change、DNS failure、每個 fail-fast 規則；`tests/compose-validation.sh`
   涵蓋 stack 接受與拒絕案例；`tests/container-contract.sh` 以真實 image 驗證
   容器能在指定 hardening 下啟動並被 restart-only API 重啟。

6. **文件**：`docs/backends/<backend>.md`、本文件 §3.1／§4.3／§5／§7.3／§10.4／
   §11、`.env.example`、`examples/<type>/`、README 支援表、`CHANGELOG.md`。

### 13.1 評估過但未實作的方式

| 方式 | 狀態 | 原因 |
| --- | --- | --- |
| IKEv2／IPsec（strongSwan `strongx509/strongswan`） | 候選 | 需要 kernel xfrm 與 `NET_ADMIN`，無現成 proxy／gate；kill switch 依賴 trap policy，未經真實驗證前不納入 |
| L2TP／IPsec、PPTP、SSTP | 不納入 | 無維護中的 pinned client image；PPTP 不安全 |
| SoftEther client | 不納入 | 無可靠上游 image，設定模型與本專案 profile 契約差異大 |
| Tailscale／ZeroTier exit node | 不納入 | 由 coordination server 尋址，不存在 DDNS gap |
| OpenVPN multi-remote failover | 不納入 | Gluetun 只使用第一個 remote；假 failover 比 fail-fast 危險 |
