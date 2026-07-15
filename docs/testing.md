# 測試策略與驗收範圍

## 一鍵檢查

```bash
make check
```

需要 Docker daemon、Docker Compose、`jq` 與網路連線。第一次執行會 pull 版本固定的
helper、socket proxy、ShellCheck test image（若另行執行 static check）及小型 Alpine
fixture image；不會 build 任何 image。

`make check` 依序執行：

1. Markdown 文件 lint；
2. rendered Compose contract validation；
3. POSIX shell DDNS behavior tests；
4. 真實 stock helper 與 restart-only Docker API container contract test。

## Compose contract validation

```bash
make validate-compose
```

`scripts/validate-compose.sh` 使用 `docker compose config --format json` 檢查實際 render
後的 model，不只檢查 YAML syntax。

### Service 與 image invariant

- service set 固定為 `ddns-init`、`gluetun`、`vproxy`、`docker-socket-proxy`、
  `ddns-watcher`；
- 任一 service 都不得有 `build`；
- init 與 watcher 必須使用相同 stock helper image；
- 不得重新出現 project-specific watcher image；
- image 不得使用 `latest`、`edge`、`master`、`main` moving tag；
- repository 不得存在 Dockerfile。

### Lifecycle 與 network invariant

- Gluetun 必須等待 init `service_completed_successfully`；
- init、watcher 與 Gluetun 必須使用相同的 `VPN_TYPE` 與 runtime profile path；
- vproxy 必須使用 `network_mode: service:gluetun`；
- Gluetun firewall 必須允許 internal `1080/tcp` 與 `9999/tcp`；
- vproxy healthcheck 必須驗證 Gluetun health、VPN interface 與 VPN route；
- watcher 必須等初始 vproxy healthy，且兩個 restart target 必須與 Compose 名稱相同；
- watcher 必須透過 `tcp://docker-socket-proxy:2375`；
- `docker-api` network 必須是 internal。

### Security invariant

- 只有 socket proxy 可以掛 `/var/run/docker.sock`；
- socket proxy 必須載入唯讀的精確 HAProxy policy，不得依賴上游 coarse-grained
  `CONTAINERS`／`ALLOW_RESTARTS` flags；
- 所有非 Gluetun service 必須 `cap_drop: [ALL]`；
- WireGuard PrivateKey／PresharedKey 不得出現在 Compose environment；
- 所有 service 必須 `no-new-privileges:true`；
- HTTP／SOCKS5 credentials 不可只設定一半；
- 非 loopback bind 時，所有已啟用的 proxy 都必須有完整 authentication。

如果 repository 有 `.env`，validator 會驗證該檔；否則驗證 `.env.example` 的安全預設。

## DDNS behavior tests

```bash
make test
```

`tests/run.sh` 是不需要 VPN server 或 Docker daemon 的 POSIX shell TAP-style suite。

| Case | 證明內容 |
| --- | --- |
| Valid profile | 正確的 single-remote profile 可通過 preflight |
| Renderer | hostname 轉 IPv4；relative reference 轉 absolute path |
| Multi-A init | DNS addresses 去重排序並 deterministic 選擇 |
| Resolver adapters | `getent` 與指定 `nslookup` output 都正確擷取 A record |
| Round-robin reorder | answer order 變化不會 restart |
| DNS failure | invalid/empty answer 保留 profile inode、last IP、hash，不 restart |
| Address change | atomic render、Gluetun → healthy → vproxy、commit new state |
| Referenced file change | 相同 IP 下 certificate fingerprint 仍觸發 full-stack restart |
| Restart/health failure | 不提交 new IP/hash，讓下一輪完整 retry |
| Namespace readiness | 新 Gluetun namespace 沒有 vproxy listener 時不 commit |
| Multiple remotes | fail-fast，避免假 failover |
| Missing reference | 啟動前拒絕缺少的 certificate/key |
| Invalid override | 診斷用 IP 也必須是合法 IPv4 |
| OpenVPN auth pair | `auth-user-pass` 必須有完整 Gluetun credentials |
| Direct Compose proxy gate | helper 本身拒絕 partial／public unauthenticated proxy |
| WireGuard validation | single interface／peer 與 required fields 才能通過 |
| WireGuard renderer | 只替換 Endpoint hostname，保留 key 與 port |
| WireGuard init/change | deterministic init、address change 與 profile change 都正確 restart |
| WireGuard invalid profiles | multi-peer、missing key、invalid port 都 fail-fast |
| WireGuard DNS failure | 保留現有 runtime profile，不 restart |

測試用 fake `docker` 只記錄參數，因此可準確斷言 state commit ordering，而不會改動
開發機上的 container。

`tests/compose-validation.sh` 另外驗證安全設定的 negative cases：public bind 無
credentials、三組 partial credential pair、moving image tag、未知 VPN type、錯誤
WireGuard MTU／implementation 都必須失敗；完整 authenticated public bind 與
WireGuard mode 必須成功。

## 真實 container contract

```bash
make test-container
```

`tests/container-contract.sh` 會建立隔離的暫時 Compose project，完成下列驗證：

1. `docker-socket-proxy:v0.4.2` 在 `read_only`、`cap_drop: ALL`、最小
   `DAC_READ_SEARCH`、tmpfs 與自訂 restart-only HAProxy policy 下能 healthy；
2. `docker:29.6.1-cli-alpine3.24` 在沒有額外 package 的情況下可讀取 restrictive umask
   checkout 的 `0700` mounted POSIX script，以及 host UID 擁有的 `0600` source profile；
3. stock helper 可 validate／init render OpenVPN 與 WireGuard，runtime file 保持 `0600`；
4. watcher 的 Docker client 可經 internal socket proxy restart 指定的 Gluetun 與
   vproxy fixtures；
5. 兩者 restart 後從 container 內讀到相同 network namespace identity；
6. 同一路徑不得 restart 非目標 container，呼叫目標的 inspect、stop、kill、pause
   與 remove 也必須全部收到拒絕；
7. vproxy 在 read-only、drop-all、no-new-privileges 下仍可建立 SOCKS5 listener，且
   stock image 具備 healthcheck 所需的 `wget`、`ip` 與 `grep`；
8. trap 清除暫時 container、networks 與 volumes。

這個測試特別保護 capability hardening 與 bind-mount mode 的交互作用。一般 host 上的
直接 shell test 無法發現 container root 在移除 `CAP_DAC_OVERRIDE` 後讀不到 `0700`
host file 的問題。

## Static analysis

CI 使用 ShellCheck 對所有 production／test shell scripts 執行 POSIX 模式：

```bash
shellcheck -s sh scripts/*.sh tests/*.sh
```

本機沒有 ShellCheck 時，可直接使用上游 image：

```bash
docker run --rm -v "$PWD:/mnt:ro" -w /mnt \
  koalaman/shellcheck:v0.11.0 \
  -s sh scripts/*.sh tests/*.sh
```

## 圖表驗證

文件圖表使用 YAML-first draw.io workflow 產生，release 檢查結果：

| Artifact | Structure | Node crossings | Edge crossings | Visual review |
| --- | --- | ---: | ---: | --- |
| `docs/assets/architecture.drawio` / `.svg` | XML passed | 0 | 0 | exported SVG inspected |
| `docs/assets/ddns-recovery.drawio` / `.svg` | XML passed | 0 | 0 | exported SVG inspected |

`.drawio` 是可編輯來源交付，`.svg` 是 GitHub 文件顯示格式。產生環境沒有 draw.io
Desktop，所以依工具 fallback 契約輸出 SVG，而非 300 dpi PNG。

## CI

`.github/workflows/ci.yml` 在 push 與 pull request 執行：

1. checkout；
2. 安裝 `jq`、`shellcheck`；
3. ShellCheck；
4. `make check`。

workflow paths 包含 Compose、environment example、scripts、tests、examples、Makefile、
README 與 docs。專案沒有 image publish workflow，因為 production 架構不建置自有
image。

## 真實 VPN 驗收

自動測試不攜帶使用者的 provider credentials，也不能連到真實 OpenVPN／WireGuard
server。
production target 首次部署後必須完成以下驗收。

### 1. Service health

```bash
docker compose ps --all
```

確認 init exited 0，其他四個 service healthy／running。

### 2. Tunnel establishment

```bash
docker compose logs --tail=200 gluetun
```

確認所選 VPN 已建立 tunnel；OpenVPN 沒有 certificate／authentication／cipher error，
WireGuard 沒有 key／address／route error，且兩者都沒有 firewall error。

### 3. HTTP 與 SOCKS5 data path

```bash
curl -x http://127.0.0.1:8888 https://ifconfig.me
curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me
```

兩者應回傳相同 VPN exit IP，且與 host 直接連線的 public IP 不同。

### 4. Authentication rejection

公開 bind 前，用缺少或錯誤 credentials 測試 HTTP 與 SOCKS5，確認匿名 request 不會
成功。

### 5. Live DDNS failover drill

在可控制的 staging hostname 上：

1. 記錄目前 `last-ip` 與 Gluetun container start time；
2. 將 A record 更新到另一台可用、提供相同協定與 credentials 的 VPN server；
3. 等待 DNS TTL 與一個 poll interval；
4. 確認 watcher 記錄 `reason=address-change`；
5. 確認 `last-ip` 更新、Gluetun 先 restart 並 healthy、vproxy 隨後 restart；
6. 比對兩個 container 的 network namespace identity，並確認兩個 proxy 恢復；
7. 記錄實際中斷時間，確認符合服務 SLO。

```bash
docker compose logs -f ddns-watcher gluetun
```

不要在唯一 production endpoint 上做第一次 failover drill。

### 6. DNS outage drill

在 staging 暫時指定不可達 resolver，確認 watcher 記錄 warning，但 Gluetun 不被
restart，既有 tunnel 仍傳輸。恢復 resolver 後應自行回到正常 polling。

### 7. Host reboot drill

重啟 target host，確認 Docker restart policy 恢復 long-running services；若停機期間
改變 DDNS，watcher 應在一個 interval 內 render，並依序 restart Gluetun 與 vproxy。

## 自動測試未涵蓋

- 真實 provider OpenVPN certificate／username／password 或 WireGuard key／address；
- `/dev/net/tun` 與 target kernel 的相容性；
- provider push routes、DNS 與 cipher negotiation；
- host firewall 與 upstream network ACL；
- 真實 HTTP CONNECT／SOCKS5 authentication through tunnel；
- DDNS provider TTL 與全球 resolver propagation；
- SELinux／AppArmor 的 host-specific socket policy；
- 長時間 soak、packet loss、bandwidth saturation 與 SLO measurement。

這些項目需要 staging／production 環境的真實驗收，不能用 narrow unit test 推論完成。
