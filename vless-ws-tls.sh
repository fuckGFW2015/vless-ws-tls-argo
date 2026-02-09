#!/usr/bin/env bash
set -euo pipefail

# 颜色定义
info() { echo -e "\033[0;32m→ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }
die() { echo -e "\033[0;31m✖ $*\033[0m" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] && die "请使用 root 运行"

# 1. 基础安装
info "正在安装核心依赖..."
apt update -y && apt install -y curl wget jq openssl qrencode haveged
systemctl enable --now haveged >/dev/null 2>&1

# 2. 交互输入
read -rp "请输入域名 (如 vargo.xxx.xxx): " DOMAIN
read -rp "请输入 CF Token: " CF_TOKEN

# 3. 下载/修复 Cloudflared
info "安装 Cloudflared..."
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
wget -q -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
chmod +x /usr/local/bin/cloudflared

# 4. 安装/配置 Xray
info "配置 Xray (端口: 2096)..."
! command -v xray >/dev/null && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 生成证书并强制放开权限 (核心修复)
CERT_DIR="/etc/xray"
mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$CERT_DIR/priv.key" -out "$CERT_DIR/cert.pem" -subj "/CN=$DOMAIN" -batch >/dev/null 2>&1
# 关键权限：确保 nobody 用户能读
chown -R nobody:nogroup "$CERT_DIR"
chmod -R 755 "$CERT_DIR"

# 写入配置
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/vargo$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 4)"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 2096,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": { "clients": [{"id": "$UUID"}], "decryption": "none" },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{ "certificateFile": "$CERT_DIR/cert.pem", "keyFile": "$CERT_DIR/priv.key" }]
      },
      "wsSettings": { "path": "$WS_PATH" }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

# 5. 启动服务
info "启动服务中..."
systemctl restart xray
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel run --protocol grpc --token $CF_TOKEN
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cloudflared

# 6. 自动化健康检查 (带有重试机制)
info "🔎 执行健康检查 (最多等待 10 秒)..."
for i in {1..10}; do
    if ss -tulpn | grep -q ":2096 "; then
        CHECK_PORT="OK"
        break
    fi
    sleep 1
done

XRAY_S=$(systemctl is-active xray || echo "inactive")
CF_S=$(systemctl is-active cloudflared || echo "inactive")

echo "----------------------------------------"
[ "$XRAY_S" == "active" ] && echo -e "✅ Xray 进程: 在线" || warn "❌ Xray 进程: 离线"
[ "${CHECK_PORT:-}" == "OK" ] && echo -e "✅ 2096 监听: 成功" || warn "❌ 2096 监听: 失败 (请检查日志)"
[ "$CF_S" == "active" ] && echo -e "✅ Argo 隧道: 在线" || warn "❌ Argo 隧道: 离线"
echo "----------------------------------------"

# 7. 节点信息
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=$(printf '%s' "$WS_PATH" | jq -sRr @uri)&sni=${DOMAIN}#Argo_2096"
info "🎉 部署尝试完成！"
echo -e "\033[1;36m$VLESS_URI\033[0m"
qrencode -t ansiutf8 -m 1 "$VLESS_URI"
