# Changelog

本專案遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號依
[Semantic Versioning](https://semver.org/lang/zh-TW/)。契約的正式定義在
[docs/spec.md](docs/spec.md)。

## [Unreleased]

### Changed — 小主機效率與透明／無痕

- **Gluetun HTTP proxy 固定 stealth**：原預設 `HTTPPROXY_STEALTH=off` 會對每個明文
  HTTP request 加上 `X-Forwarded-For: <client IP>`，洩漏 client 位址並暴露 proxy。
  現在固定 `on` 且 `HTTPPROXY_LOG=off`，不可覆寫；`.env` 殘留的
  `HTTPPROXY_STEALTH=off` 會被忽略並由 validator 提示。
- **OpenConnect proxy 透明化**：tinyproxy 不再加 `Via: 1.1 tinyproxy`、不記錄連線、
  `MaxClients` 由 10 提高到 100；microsocks 以 `-q` 執行，不再記錄每個目的地。
- **預設不記錄目的地**：`VPROXY_LOG` 與 `SINGBOX_LOG_LEVEL` 預設由 `info` 改為
  `warn`（`info` 每條連線寫入 3 行含目的地的 log）。既有 `.env` 需自行改值。
- **Gluetun 減少外部查詢與記憶體**：新增 `BLOCK_MALICIOUS`、`PUBLICIP_ENABLED`
  （預設皆 `off`），固定 `VERSION_INFORMATION=off`、`STORAGE_FILEPATH=`（不再把
  7 MB `servers.json` 寫入 container layer）。單核實測啟動後 RSS 87.5 → 76.8 MiB
  （尚未計入連線後下載的 blocklist）。
- **Healthcheck 節奏**：Gluetun image 內建 5s healthcheck（每次 exec 24 MB binary）
  改為 30s；vproxy 10s → 30s、docker-socket-proxy 10s → 60s、watcher 30s → 60s、
  sing-box 30s → 60s；全部以 `start_interval` 維持啟動速度。Gluetun stack 每分鐘
  `runc exec` 由約 26 次降為 6 次。
- **docker-socket-proxy**：HAProxy 移除 master-worker（`-W`）、`nbthread 1`、
  `maxconn 32`；單核實測 11.3 → 8.4 MiB。
- 需求提高為 Docker Engine 25+、Docker Compose v2.24+（`start_interval`）。

### Added

- 正式規格文件 `docs/spec.md`：術語、backend／adapter 模型、設定契約、runtime
  state、生命週期狀態機、CLI、log、安全與相容性政策、擴充流程。
- **OpenConnect backend**（`docker-compose.openconnect.yml`、`VPN_TYPE=openconnect`）：
  支援 AnyConnect／ocserv、GlobalProtect、Pulse、F5、Fortinet、Array，使用
  `wazum/openconnect-proxy:2.1.0`；helper 以 `resolve=HOST:IP` 讓 OpenConnect 連到
  DDNS 解析結果並仍以 hostname 驗證憑證。Loopback-only（上游 image 的 proxy 無
  authentication）。
- **sing-box backend**（`docker-compose.singbox.yml`、`VPN_TYPE=singbox`）：支援
  Shadowsocks、VMess、VLESS、Trojan、Hysteria2、TUIC、ShadowTLS、AnyTLS、SSH 等
  sing-box outbound，使用官方 `ghcr.io/sagernet/sing-box:v1.14.2`。proxy-only 模式，
  無 TUN、無 NET_ADMIN、read-only root；stack 管理 inbound、DNS 與預設路由，HTTP／
  SOCKS5 authentication 與 Gluetun backend 一致。
- Protocol adapter 架構：`scripts/adapters/<VPN_TYPE>.sh` 各自實作
  `adapter_validate`／`adapter_fingerprint`／`adapter_render`；核心
  `scripts/ddns-vpn.sh` 與協定無關。
- Backend 通用 restart chain：`VPN_CONTAINER_NAME`＋`VPN_HEALTH_PROBE`
  （`http://`／`tcp://`），可選 `SIDECAR_CONTAINER_NAME`＋`SIDECAR_HEALTH_PROBE`。
- Docker socket proxy 的 restart-only policy 改由 `RESTART_TARGETS` 動態產生，
  支援單一或多個 restart target。
- 測試：`tests/helper.sh` 48 案例（含 OpenConnect／sing-box）、
  `tests/compose-validation.sh` 22 案例、`tests/container-contract.sh` 涵蓋三個
  backend，sing-box 以本機 Shadowsocks server 做真實資料路徑驗證。
- 範例：`examples/openconnect/client.conf`、`examples/sing-box/config.json`。
- `CHANGELOG.md`、`make shellcheck`。

### Changed

- Helper 入口改為 `scripts/ddns-vpn.sh`；Compose 改掛載整個 `scripts/` 目錄到
  `/opt/ddns`。`scripts/ddns-openvpn.sh` 保留為 deprecated shim。
- 共用 service 定義移到 `compose/core.yml`，各 backend stack 以 `extends` 取用。
- 環境變數正規化：`VPN_CONTAINER_NAME`、`VPN_RESTART_TIMEOUT_SECONDS`、
  `VPN_HEALTH_TIMEOUT_SECONDS` 為 canonical 名稱；`GLUETUN_CONTAINER_NAME`、
  `GLUETUN_RESTART_TIMEOUT_SECONDS`、`GLUETUN_HEALTH_TIMEOUT_SECONDS`、
  `OPENVPN_CONFIG_DIR`、`OPENVPN_CONFIG_FILE` 仍接受為 alias。
- `ddns-watcher` 對 `vproxy` 的 depends_on 由 `service_healthy` 改為
  `service_started`：VPN 開機時無法連線（例如停機期間 DDNS 已改變）也能讓 watcher
  啟動並在下一輪修正 IP。
- `scripts/validate-compose.sh` 依 `VPN_TYPE` 選擇 stack file 驗證，並檢查
  `COMPOSE_FILE` 與 `VPN_TYPE` 一致。
- `make logs` 改為追蹤所有 service；`make test` 改呼叫 `tests/run.sh` 總入口。
- `.gitignore` 忽略整個 `config/` 與本機 AI 工具目錄。
- 文件全面改寫：README、architecture、operations、testing，新增
  `docs/backends/`。

### Removed

- `docs/testing.md` 中的圖表產生工具輸出記錄。

## [1.0.0] - 2026-07-16

初始 Compose-only 架構：Gluetun（OpenVPN／WireGuard）、vproxy SOCKS5 sidecar、
restart-only Docker socket proxy、POSIX DDNS helper、fail-safe compatibility watcher。
