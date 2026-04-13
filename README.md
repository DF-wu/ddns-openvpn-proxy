# OpenVPN + SOCKS5 Proxy with DDNS Auto-Reconnect

基于 Alpine Linux 的轻量级 Docker image，支援 OpenVPN 连线并自动监控 DDNS hostname 的 IP 变化，当 IP 变动时自动重启 OpenVPN 连线。

## 功能特性

- **DDNS 自动监控**: 每 60 秒检查一次 DDNS hostname 的 IP 是否变化
- **自动重连**: 当 DDNS IP 变化时，自动停止并重新启动 OpenVPN
- **SOCKS5 代理**: 使用 Dante 提供 SOCKS5 代理服务（端口 1080）
- **轻量**: 基于 Alpine Linux，image 大小约 30MB
- **GitHub Actions 自动构建**: 推送到 GitHub Container Registry (GHCR)

## 架构

```
┌─────────────────────────────────────────────────────────┐
│                    Alpine Linux Container               │
│  ┌──────────────┐    ┌──────────────────────────────┐  │
│  │   OpenVPN    │◄───┤    DDNS Monitor (Bash)       │  │
│  │   (tun0)     │    │  • 每60秒解析 DDNS          │  │
│  └──────┬───────┘    │  • IP 变化 → 重启 OpenVPN    │  │
│         │            └──────────────────────────────┘  │
│  ┌──────┴───────┐                                      │
│  │    Dante     │ ← SOCKS5 Proxy (0.0.0.0:1080)       │
│  │   (SOCKS5)   │                                      │
│  └──────────────┘                                      │
└─────────────────────────────────────────────────────────┘
```

## 快速开始

### 1. 准备 OpenVPN 配置文件

```bash
mkdir vpn
cat > vpn/config.ovpn << 'OVPN'
client
dev tun
proto udp
remote your-ddns-hostname.com 1194 udp
resolv-retry infinite
nobind
persist-key
persist-tun

ca ca.crt
cert client.crt
key client.key

cipher AES-256-GCM
auth SHA256

verb 3
OVPN

# 放置证书文件
cp /path/to/your/ca.crt vpn/
cp /path/to/your/client.crt vpn/
cp /path/to/your/client.key vpn/
```

**注意**: OpenVPN 配置中的 `remote` 行必须包含 DDNS hostname。

### 2. 配置环境变量

```bash
cp .env.example .env
nano .env
```

修改以下必要配置：

```bash
# DDNS Hostname（必需）
DDNS_HOSTNAME=your-ddns-hostname.com

# GitHub Container Registry image 名称
IMAGE_NAME=ghcr.io/yourusername/openvpn-ddns-proxy:main
```

### 3. GitHub Actions 自动构建

推送到 GitHub 后，GitHub Actions 会自动构建 image：

```bash
git add .
git commit -m "Initial commit"
git push origin main
```

构建完成后，image 会推送到 `ghcr.io/你的用户名/openvpn-ddns-proxy:main`。

### 4. 启动服务

```bash
docker-compose up -d
```

### 5. 验证运行

```bash
# 查看日志
docker logs -f vpn-proxy

# 测试 SOCKS5 代理
curl --socks5 localhost:1080 https://ifconfig.me
```

## 环境变量说明

| 变量名 | 说明 | 默认值 | 必需 |
|--------|------|--------|------|
| `DDNS_HOSTNAME` | DDNS hostname，用于监控 IP 变化 | - | 是 |
| `IMAGE_NAME` | GitHub Container Registry image 名称 | - | 是 |
| `VPN_CONFIG_DIR` | OpenVPN 配置文件目录 | `./vpn` | 是 |
| `DDNS_CHECK_INTERVAL` | DDNS 检查间隔（秒） | `60` | 否 |
| `SOCKS_PORT` | SOCKS5 代理端口 | `1080` | 否 |
| `REMOTE_PORT` | OpenVPN 远程端口 | `1194` | 否 |
| `REMOTE_PROTO` | OpenVPN 协议（udp/tcp） | `udp` | 否 |

## DDNS 自动重连机制

本方案的 DDNS 监控逻辑：

1. **启动时**: 解析 DDNS hostname 取得当前 IP
2. **启动 OpenVPN**: 使用解析到的 IP 作为 remote 地址
3. **后台监控**: 每 60 秒重新解析 DDNS hostname
4. **IP 变化检测**: 如果新 IP 与当前 IP 不同
   - 停止现有 OpenVPN 进程
   - 使用新 IP 重新启动 OpenVPN
   - 记录日志

### 手动测试 DDNS 重连

```bash
# 1. 启动服务并确认连线正常
docker-compose up -d

# 2. 查看当前 DDNS IP
docker exec vpn-proxy dig +short your-ddns-hostname.com

# 3. 在你的 DNS 提供商处更改 DDNS 记录指向新 IP

# 4. 观察日志，确认检测到 IP 变化并重启
docker logs -f vpn-proxy | grep -E "(DDNS IP changed|Restarting OpenVPN)"

# 5. 验证代理仍然可用
curl --socks5 localhost:1080 https://ifconfig.me
```

## 日志查看

```bash
# 查看所有日志
docker logs vpn-proxy

# 实时跟踪日志
docker logs -f vpn-proxy

# 只看 DDNS 监控日志
docker logs vpn-proxy | grep "[DDNS]"

# 只看 OpenVPN 日志
docker logs vpn-proxy | grep "[openvpn]"
```

## 故障排除

### OpenVPN 无法启动

```bash
# 检查配置文件是否存在
docker exec vpn-proxy ls -la /config/

# 检查配置文件语法
docker exec vpn-proxy openvpn --config /config/config.ovpn --show-gateway

# 查看详细日志
docker logs vpn-proxy | grep -i error
```

### DDNS 无法解析

```bash
# 测试容器内 DNS 解析
docker exec vpn-proxy dig +short your-ddns-hostname.com

# 检查 DNS 设置
docker exec vpn-proxy cat /etc/resolv.conf
```

### SOCKS5 代理无法连接

```bash
# 检查 Dante 是否运行
docker exec vpn-proxy pgrep sockd

# 查看 Dante 日志
docker exec vpn-proxy cat /var/log/danted.log

# 测试本地连接
curl --socks5 127.0.0.1:1080 https://ifconfig.me
```

## 与现有方案的对比

| 特性 | Gluetun | hillnz/docker-openvpn-socks | 此方案 |
|------|---------|---------------------------|--------|
| DDNS 自动监控 | WireGuard 不支援 | 依赖 OpenVPN 内置重连 | 主动监控并立即重启 |
| 镜像大小 | ~50MB | ~100MB | ~30MB (Alpine) |
| 维护状态 | 非常活跃 | 功能停滞 (2021) | 完全可控 |
| SOCKS5 代理 | 有 | 有 | 有 |
| HTTP 代理 | 有 | 无 | 无（可扩展） |
| WireGuard 支持 | 有 | 无 | 无 |

## 进阶配置

### 添加 HTTP Proxy

如需 HTTP 代理，可以修改 `Dockerfile` 添加 Privoxy：

```dockerfile
RUN apk add --no-cache privoxy
COPY privoxy.conf /etc/privoxy/config
```

### 添加 WireGuard 支持

如需 WireGuard 支援，修改 `Dockerfile`：

```dockerfile
RUN apk add --no-cache wireguard-tools
```

并修改 `entrypoint.sh` 使用 `wg-quick` 而非 OpenVPN。

## 授权

MIT License
