# 架構與設計決策

本文件解釋「為什麼這樣設計」。契約本身（必須／不得）定義在 [spec.md](spec.md)。

## 問題定義

成熟的 VPN client runtime 各有一個共同的缺口：它們把 endpoint 當成靜態資料。

- **Gluetun custom provider** 在建立 firewall 前不允許可能外洩的 DNS 查詢，因此
  OpenVPN `remote` 與 WireGuard `Endpoint` 必須先是 IP
  （[extractRemote](https://github.com/qdm12/gluetun/blob/v3.41.1/internal/openvpn/extract/extract.go)、
  [WireGuard config source](https://github.com/qdm12/gluetun/blob/v3.41.1/internal/configuration/sources/files/wireguard.go)）。
- **OpenConnect** 接受 hostname，但 session 建立後 IP 改變時不保證重新解析；憑證
  pin 也要求以 hostname 驗證。
- **sing-box** 會自行解析 outbound 的 hostname，但 UDP-based 傳輸的長連線在 IP
  改變後不會主動重連，且解析走哪個 DNS 需要明確控制。

DDNS server 的需求相反：來源設定必須保留 hostname，IP 改變後必須讓 runtime 重新
讀取新的解析結果。本專案的責任只限於這個 adapter lifecycle。

## 系統全貌

![DDNS VPN Proxy architecture](assets/architecture.svg)

```text
.env ──► docker-compose[.<backend>].yml ──extends──► compose/core.yml
                                                    ├── ddns-init
                                                    ├── ddns-watcher
                                                    └── docker-socket-proxy
              scripts/ddns-vpn.sh ──sources──► scripts/adapters/<VPN_TYPE>.sh
```

### 兩層抽象

| 層 | 位置 | 變動點 | 不變點 |
| --- | --- | --- | --- |
| **Adapter**（協定） | `scripts/adapters/*.sh` | 如何驗證 profile、抓 endpoint、算 fingerprint、render | validate → resolve → render → restart → commit 的生命週期 |
| **Backend**（runtime） | `docker-compose*.yml` | 哪個 image 建 tunnel、proxy 怎麼提供、就緒探測是什麼 | helper、socket proxy、state volume、hardening 規則 |

Adapter 與 backend 是多對一：`openvpn`／`wireguard` 都由 gluetun backend 服務。
Helper 只需要 backend 的兩個事實：restart target 與就緒探測（`VPN_HEALTH_PROBE`），
以及可選的 sidecar。這讓 restart chain 對所有 backend 完全相同。

### 元件與邊界

| Service | 上游 image | Lifecycle | 單一責任 |
| --- | --- | --- | --- |
| `ddns-init` | `docker:29.6.1-cli-alpine3.24` | one-shot | 啟動前驗證、解析、首次原子 render |
| `ddns-watcher` | 同上 | long-running | DNS／profile 監看與 restart chain |
| `docker-socket-proxy` | `ghcr.io/tecnativa/docker-socket-proxy:v0.4.2` | long-running | 把 Docker API 縮到精確的 restart target |
| `gluetun` | `qmcgaw/gluetun:v3.41.1` | long-running | OpenVPN／WireGuard、firewall、health、HTTP proxy |
| `vproxy` | `ghcr.io/0x676e67/vproxy:v2.5.5` | long-running | Gluetun namespace 內的 SOCKS5 |
| `openconnect` | `wazum/openconnect-proxy:2.1.0` | long-running | OpenConnect tunnel、tunnel-gated HTTP／SOCKS5 |
| `singbox` | `ghcr.io/sagernet/sing-box:v1.14.2` | long-running | proxy-protocol outbound、mixed inbound |

沒有任何 service 使用 `build:`。`ddns-init` 與 `ddns-watcher` 掛載同一份
`scripts/` 目錄，以 `init`／`watch` 子命令分離 lifecycle。

### 為什麼是多個 stack file 而不是 Compose profiles

Compose profiles 會讓「沒有設定 profile 的既有 `.env`」啟動一個沒有 VPN 的殘缺
stack；`depends_on` 也不能跨 profile。獨立的 stack file 讓 `docker-compose.yml`
維持完全向後相容，每個 backend 的拓樸可以獨立 review，validator 也能對每個檔案
斷言精確的 service 集合。共用部分透過 `extends` 取自 `compose/core.yml`，避免
複製 helper 與 socket proxy 的 hardening。

## 開機時序

```text
docker compose up
       │
       ▼
  ddns-init ── load adapter, validate profile + referenced files + environment
       │       resolve all IPv4 A records (retry forever on DNS failure)
       │       render /state/runtime/vpn.conf[, vpn.env] atomically
       │       write last-ip + fingerprint
       ▼
  exits 0
       │  depends_on: service_completed_successfully
       ▼
 VPN container ─ read resolved runtime profile, establish tunnel
       │         (gluetun: also HTTP proxy; vproxy joins its namespace)
       ▼
ddns-watcher ─── poll indefinitely
```

設定錯誤讓 init 以 code `64` 結束；DNS 暫時不可用則持續重試。兩者刻意分開，避免
把永久設定錯誤誤當成暫時網路錯誤。

## Steady-state 與恢復流程

![DDNS detection and recovery flow](assets/ddns-recovery.svg)

每輪 watcher 取得三份證據：hostname 當前所有有效 IPv4 A record、已提交的
`last-ip`、source profile 與被引用檔案的 SHA-256 fingerprint。狀態轉移見
[spec §7.2](spec.md)。

### 為何不在 DNS 暫時失敗時重啟

現有 VPN session 可能仍正常；已建立的 tunnel 不需要 hostname。覆寫或重啟只會把
控制面的短暫故障放大成資料面的中斷，因此採 stale-but-working 優先。

### 多 A record 的穩定選擇

DNS 回應順序不保證穩定。規則是：去重排序；`last-ip` 仍在集合內就沿用；否則取
排序後第一筆。這不會把 answer order 誤判為 endpoint 變更，仍能在舊 IP 被移除時
切換。

### 原子寫入與 commit 順序

runtime profile 與狀態檔都先用 `mktemp` 在目標目錄建立、`chmod 600`，再以 `mv`
取代。暫存檔與目標在同一 filesystem，rename 是 atomic；backend 不會看到半份設定。
只有整條 restart chain 成功才 commit。

### Restart chain 與就緒探測

```text
restart VPN container → wait VPN_HEALTH_PROBE
  → [sidecar] restart sidecar → wait SIDECAR_HEALTH_PROBE
  → commit last-ip + fingerprint
```

「就緒」對每個 backend 意義不同，所以探測由 stack file 宣告，helper 只認
`http://`（`wget --spider`）與 `tcp://`（`nc -z`）兩種形式：

| Backend | 探測 | 為什麼這代表就緒 |
| --- | --- | --- |
| gluetun | `http://gluetun:9999` | Gluetun health server 只在 tunnel 通時回 2xx |
| openconnect | `tcp://openconnect:8888` | 上游 tunnel gate 在 `tun0` UP 前以 RST 拒絕 proxy 連線 |
| singbox | Clash API `/proxies/vpn/delay?url=…` | 實際經 `vpn` outbound 抓 URL，證明資料路徑 |

### 為什麼 watcher 不再等 vproxy healthy 才啟動

舊版 watcher `depends_on: vproxy: service_healthy`。若開機時 DDNS 已指向舊 IP
（例如停機期間改變），Gluetun 永遠不健康、vproxy 永遠不健康、watcher 永遠不啟動，
沒有人會再解析 DNS。改成 `service_started` 後 watcher 的第一輪就能修正 IP；若
sidecar 還不存在，restart 失敗、不提交、下一輪重試，自我修復。

### Network namespace lifecycle（gluetun backend）

`network_mode: service:gluetun` 只規定 vproxy 啟動時加入哪個 namespace；Gluetun 被
單獨 restart 後 Docker 不會同步重建 vproxy。watcher 因此在 Gluetun 就緒後明確
restart vproxy，並從 Gluetun service address 確認 `:1080` 出現在新 namespace。
vproxy healthcheck 同時驗證 SOCKS listener、Gluetun `:9999`、VPN interface 與預設
route，舊 namespace 只剩 loopback 時不可能通過。

## Backend 設計筆記

### Gluetun（openvpn、wireguard）

Renderer 只改寫唯一的 `remote`／`Endpoint` host；OpenVPN 的相對檔案引用改成
`/source` 下的絕對路徑。`auth-user-pass` 的檔案路徑不納入 render／fingerprint，
因為 Gluetun 會覆寫成內部 auth file。WireGuard 的 key 只存在檔案，經
`WIREGUARD_CONF_SECRETFILE` 讀取；`AllowedIPs`、keepalive、MTU 由 `.env` 提供，
因為 Gluetun 不從檔案匯入。

### OpenConnect

上游 image 由 env 驅動（`OPENCONNECT_URL`、`OPENCONNECT_OPTIONS`），而 container
env 在 restart 時不會改變。解法是把可變的部分放進 volume：helper render 一個
OpenConnect `--config` 檔（附加 `resolve=HOST:IP`、`non-inter`）與一個 `vpn.env`
（gateway URL），container 的 entrypoint 在每次啟動時 source 它們再交給上游
entrypoint。`resolve=` 讓 OpenConnect 連到 DDNS 解析結果、仍以 hostname 驗證憑證。

上游的 tinyproxy／microsocks 沒有認證，所以此 backend 被 validator 與 helper 雙重
限制為 loopback-only，直到有可靠的認證方案。以 vproxy 取代上游 proxy 需要自行實作
kill switch（tunnel gate 只保護上游的兩個 port），在沒有真實驗證前不納入。

### sing-box

選擇 **proxy-only** 而非 TUN 模式：不需要 `NET_ADMIN`／`/dev/net/tun`，也不需要
kill switch，因為沒有 direct outbound、`route.final=vpn`，流量無路可漏。Stack 擁有
inbound／DNS／route，profile 只描述 outbound，這樣 proxy 認證與 leak 政策由 `.env`
與 validator 統一管理，而不是散落在使用者的 JSON 裡。

Helper 以 awk 對整份 JSON 做 `"server": "HOST"` 的字串替換（不需要 jq，stock
image 沒有），格式化或 minified 都可；正確性由 container 啟動前的 `sing-box check`
把關。sing-box 合併多檔時依檔名排序、字母序最前者優先，所以 managed 檔命名
`00-managed.json`。

## Runtime 資料模型

見 [spec §6](spec.md)。`vpn-state` 可以刪除重建；真正需要備份的是
`VPN_CONFIG_DIR` 指向的來源資料。

## Docker API 安全邊界

```text
ddns-watcher ── DOCKER_HOST=tcp://docker-socket-proxy:2375 ──► internal docker-api network
                                                                       │
                                                             docker-socket-proxy
                                                               ├── GET/HEAD /_ping
                                                               ├── POST /containers/<RESTART_TARGETS[i]>/restart
                                                               └── deny everything else
```

policy 由 `docker/socket-proxy-haproxy.cfg.tmpl` 與 `RESTART_TARGETS` 在 tmpfs
render；不使用上游 `CONTAINERS`／`ALLOW_RESTARTS` 粗粒度旗標（上游的 restart 群組
包含 stop 與 kill，`CONTAINERS + POST` 會開放其他 container 的 POST endpoint）。
stack file 保證 `RESTART_TARGETS` 與 helper 的 target 一致，validator 斷言之。

## Container hardening

見 [spec §10.3](spec.md)。設計原則：只有真正建 tunnel 的 container 拿
`NET_ADMIN` 與 TUN；bind-mount reader 只加回 `DAC_READ_SEARCH`（container UID 0 在
drop `DAC_OVERRIDE` 後讀不到 host UID 擁有的 `0600`／`0700` 檔案）；helper 用
POSIX sh 與 stock image 既有工具，不在啟動時 `apk add`。

## 已排除的替代方案

| 方案 | 為什麼不 |
| --- | --- |
| 只用 Gluetun hostname | custom provider 在啟動前拒絕非 IP remote／endpoint |
| 自建 watcher image | 增加 registry、multi-arch、SBOM、簽署與發布 lifecycle；stock CLI image 已有全部工具 |
| 啟動時 `apk add` | 每次啟動依賴 package mirror，增加供應鏈變數 |
| watcher 直接掛 Docker socket | 等同 host root；socket proxy 把能力縮到可自動驗證的範圍 |
| 單一 compose 檔＋profiles | 破壞既有 `.env` 的向後相容，`depends_on` 不能跨 profile |
| sing-box TUN 模式 | 需要 `NET_ADMIN`、自行處理 route 與 kill switch；proxy-only 已滿足需求且更小 |
| IKEv2／L2TP／SSTP backend | 見 [spec §13.1](spec.md) |

## 明確限制

- 只支援 IPv4 A record。
- 每種協定只支援一個 endpoint；fail-fast 而非假 failover。
- 輪詢週期最低 10 秒；DDNS 改變會造成一次 container restart 與短暫中斷。
- proxy credentials 以環境變數傳入 VPN container，可被具有 Docker inspect 權限的
  人看到。
- socket proxy 降低但無法完全消除 Docker socket 風險。
