# 測試策略與驗收範圍

## 一鍵檢查

```bash
make check
```

需要 Docker daemon、Docker Compose、`jq`、`curl` 與網路連線。依序執行：

1. Markdown lint（`README.md`、`CHANGELOG.md`、`docs/**`）；
2. rendered Compose 契約驗證（`scripts/validate-compose.sh`，依 `.env` 或
   `.env.example` 選定的 backend）；
3. 離線測試（`tests/run.sh`）：helper 行為、Compose 契約負面案例、frozen
   compatibility watcher；
4. 真實 container 契約（`tests/container-contract.sh`）：三個 backend。

`make shellcheck` 另外以 pinned ShellCheck image 檢查所有 shell script（CI 使用原生
ShellCheck）。

## Helper 行為測試

```bash
sh tests/helper.sh
```

POSIX sh TAP-style suite，不需要 VPN server 或 Docker daemon；`docker`、`getent`、
`nslookup`、`wget`、`nc` 以記錄參數的 fake 取代，因此可精確斷言 restart 順序與
state commit 時機。48 個案例涵蓋：

| 群組 | 證明內容 |
| --- | --- |
| 通用 | multi-A 去重排序與 deterministic 選擇；resolver adapter（getent、指定 nslookup）；round-robin 重排不 restart；DNS 失敗保留 profile inode、last-ip、fingerprint 且不 restart；address-change 原子 render → VPN restart → 就緒探測 → sidecar → commit；profile-change 在相同 IP 下 restart；restart／就緒／sidecar 任一失敗不 commit；未知 `VPN_TYPE`、backend 與 stack 不符、gluetun 缺 sidecar 都 fail-fast；deprecated `ddns-openvpn.sh` 與 `GLUETUN_*`／`OPENVPN_*` alias 仍可用 |
| OpenVPN | single-remote 通過；render 改 IP 與絕對路徑、mode 0600；multi-remote、缺引用檔、`auth-user-pass` 缺 credentials、partial／public proxy 都拒絕 |
| WireGuard | single interface／peer 通過；只換 Endpoint host；multi-peer、缺 PrivateKey、port 不合法拒絕；DNS 失敗保留 tunnel |
| OpenConnect | 通過；render 附加 `resolve=`／`non-inter`、`cafile` 絕對路徑、`vpn.env`；address-change 只 restart VPN container 並以 `tcp://openconnect:8888` 探測；CA 輪替 restart；缺 `OPENCONNECT_SERVER`、IPv4 server、port 不合法、stack 管理選項、未知 protocol、缺 cafile、partial credentials、非 loopback bind 都拒絕 |
| sing-box | 通過；只改寫 `"server"`（含 minified JSON）、`certificate_path` 絕對路徑；address-change 以 Clash API 探測；憑證輪替 restart；含 `inbounds`、缺 `vpn` tag、多個 hostname server 未指定 `DDNS_HOSTNAME`、`DDNS_HOSTNAME` 不在 profile 都拒絕；DNS 失敗保留；public bind 認證政策 |

## Compose 契約

```bash
make validate-compose            # 目前 .env（或 .env.example）
sh tests/compose-validation.sh   # 22 個跨 backend 案例
```

`scripts/validate-compose.sh` 用 `docker compose config --format json` 檢查
rendered model 而非 YAML 文字。通用 invariant（所有 stack）：

- 無 `build`、無 Dockerfile、無 moving tag、無自建 watcher image；
- service 集合恰好等於該 backend 的預期；helper 兩個 service 使用同一 image、
  同一 `/opt/ddns` script 目錄、同一 `/source` read-only mount、同一
  `VPN_BACKEND`／`VPN_TYPE`／`VPN_SOURCE_CONFIG`；
- VPN service `depends_on ddns-init: service_completed_successfully`，讀取
  read-only `vpn-state`；watcher depends_on VPN service 與 healthy socket proxy；
- `VPN_CONTAINER_NAME` 等於 VPN service 的 `container_name`；`RESTART_TARGETS`
  恰好等於 VPN container（加 sidecar）；`VPN_HEALTH_PROBE` 為 `http://`／`tcp://`；
- 只有 socket proxy 掛 docker.sock、`docker-api` internal、policy template
  read-only、無上游粗粒度旗標；
- 非 VPN service `cap_drop: ALL`；只有 bind-mount reader 加 `DAC_READ_SEARCH`；所有
  service `no-new-privileges`、json-file rotation；helper 環境不含任何 secret；
- 認證 pair 完整；非 loopback bind 時所有啟用的 proxy 都有認證。

Backend invariant：Gluetun（custom provider、runtime profile path、WireGuard key 不在
env、vproxy namespace／healthcheck、firewall ports）；OpenConnect（`NET_ADMIN`＋TUN
且非 privileged、tunnel gate 環境、entrypoint 讀取 `vpn.env`／`vpn.conf`、
healthcheck 內容、loopback-only）；sing-box（無 capability／TUN、read-only、tmpfs、
`sing-box check`、managed 檔名、healthcheck 路徑、Clash API 探測）。

`tests/compose-validation.sh` 的負面案例：public bind 無認證、三組 partial pair、
moving tag、未知 `VPN_TYPE`、WireGuard MTU／implementation、`COMPOSE_FILE` 與
`VPN_TYPE` 不符、OpenConnect 缺 server／partial credentials／public bind／錯誤
`VPN_TYPE`、sing-box public 無認證／moving tag。正面案例：authenticated public
bind、WireGuard、legacy alias 對應、OpenConnect loopback、sing-box loopback 與
authenticated public、單 container backend 只有一個 restart target。

## 真實 container 契約

```bash
make test-container
```

`tests/container-contract.sh` 建立隔離的暫時 Compose project（`ddns-contract-<pid>`），
不碰 operator 的 `.env` 與 state，trap 清除所有 container、network 與 volume：

### Gluetun backend

1. socket proxy 在 `read_only`、`cap_drop: ALL`、`DAC_READ_SEARCH`、tmpfs 與
   `RESTART_TARGETS` 產生的 policy 下 healthy；
2. stock `docker:cli` 在無額外套件下讀取 `0700` script 目錄與 `0600` profile，
   validate／init render OpenVPN 與 WireGuard，runtime file 為 `0600`；
3. watcher 的 Docker client 可經 socket proxy restart 指定的 Gluetun 與 vproxy
   fixture，restart 後兩者 network namespace 相同；
4. 非目標 restart、inspect、stop、kill、pause、remove 全部被拒；
5. vproxy 在 hardening 下建立 listener，且具備 healthcheck 需要的工具。

### OpenConnect backend

1. validate／init render `resolve=HOST:IP`、`non-inter`、`vpn.env`；
2. container 以 `NET_ADMIN`＋TUN、非 privileged 啟動；entrypoint source 了 `vpn.env`；
3. OpenConnect 確實嘗試連線 `resolve=` 指定的 IP（log
   `Failed to connect to 127.0.0.1:1`）；
4. tunnel 未建立時 `OPENCONNECT_PROXY_GATE` 有 REJECT 規則、`:8888` 拒絕連線、
   watcher 的 `tcp://openconnect:8888` 探測失敗；
5. 受限 API 可 restart、不可 inspect／stop。

host 沒有 `/dev/net/tun` 時第 2–5 項會跳過並印出說明。

### sing-box backend（端對端）

1. 在 project network 啟動一個 sing-box Shadowsocks server 與一個 HTTP target；
2. 以 `DDNS_OVERRIDE_IPS` 指向 server，`up --wait` 直到 healthcheck 經
   `:1080` mixed inbound（帶認證）→ Shadowsocks outbound → server → target 成功；
3. runtime profile 的 `"server"` 已是 server IP；container read-only、無 capability、
   非 privileged；
4. 從 host：未認證 HTTP 回 407；認證 HTTP 與 SOCKS5 回 204；錯誤 SOCKS5 密碼被拒；
5. watcher 的 Clash API 探測回 2xx；受限 restart 後資料路徑恢復；inspect／stop 被拒。

## Static analysis

CI 與 `make shellcheck` 對 `scripts/*.sh`、`scripts/lib/*.sh`、`scripts/adapters/*.sh`、
`tests/*.sh` 以 POSIX 模式、`compat/watcher/*.sh` 以 bash 模式執行 ShellCheck。

## CI

`.github/workflows/ci.yml` 在 push 與 pull request 執行 ShellCheck 與 `make check`；
paths 包含 Compose、`compose/`、`docker/`、`.env.example`、scripts、tests、examples、
Makefile 與所有文件。`publish-compat-watcher.yml` 只在 `compat/watcher/**` 改變時
重新發布 frozen compatibility image（見 [spec §12](spec.md)）。

## 圖表

`docs/assets/*.drawio` 是可編輯來源，`.svg` 是 GitHub 顯示格式。架構圖以 Gluetun
backend 為例；其他 backend 以單一 VPN container 取代 Gluetun＋vproxy，helper、
socket proxy 與 state volume 相同。

## 真實 VPN 驗收

自動測試不攜帶 provider credentials，也不連真實 VPN server。production target 首次
部署後必須完成：

1. **Service health**：`docker compose ps --all`，init exited 0，其餘 healthy。
2. **Tunnel establishment**：VPN container log 無認證／憑證／cipher／route／firewall
   錯誤。
3. **Data path**：HTTP 與 SOCKS5 都回傳相同 VPN 出口 IP，且與 host 直連不同。
4. **Authentication rejection**：公開 bind 前，缺少或錯誤 credentials 必須被拒。
5. **Live DDNS failover drill**（staging hostname）：記錄 `last-ip` 與 container
   start time → 將 A record 改到另一台相同協定的 server → 等 TTL＋一個 poll →
   確認 `reason=address-change`、`last-ip` 更新、restart chain 順序、proxy 恢復、
   實際中斷時間符合 SLO。
6. **DNS outage drill**：指定不可達 resolver，確認只有 WARN、tunnel 持續傳輸，恢復
   後回到正常 polling。
7. **Host reboot drill**：重啟 host，確認 restart policy 恢復服務；停機期間改變
   DDNS 時一個 interval 內完成 restart chain。

## 自動測試未涵蓋

- 真實 provider 的 OpenVPN／WireGuard／OpenConnect／sing-box server 與其認證；
- `/dev/net/tun` 與 target kernel 的相容性、provider push routes、cipher negotiation；
- host firewall、SELinux／AppArmor、DDNS provider TTL 與 resolver propagation；
- OpenConnect 只用憑證登入、互動式 MFA；
- 長時間 soak、packet loss、bandwidth 與 SLO 量測。
