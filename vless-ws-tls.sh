#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# VLESS + WS + TLS + Cloudflare Tunnel (2096 端口版)
# ======================================================

die() { echo -e "\033[0;31m✖ $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[0;32m→ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }

if [ "$(id -u)" -ne 0 ]; then die "请使用 root 运行"; fi

# 1. 菜单界面
clear
echo -e "\033[1;36m"
echo "╔══════════════════════════════════════════╗"
echo "║   VLESS + Argo 2096 (含自动化检查)   ║"
echo "╚══════════════════════════════════════════╝"
echo -e "\033[0m"
echo "1) 安装 / 修复部署"
echo "2) 卸载全部组件"
echo "3) 退出"
read -rp "请选择操作 (1/2/3): " ACTION

if [ "$ACTION" = "2" ]; then
    info "正在卸载..."
    systemctl disable --now xray cloudflared 2>/dev/null || true
    rm -rf /usr/local/etc/xray /etc/xray /usr/local/bin/cloudflared /etc/systemd/system/cloudflared.service
    info "✅ 卸载完成！"; exit 0
fi

[[ "$ACTION" != "1" ]] && exit 0

# 2. 参数获取
read -rp "请输入域名: " DOMAIN
read -rp "请输入 CF Token: " CF_TOKEN

# 3. 安装依赖与核心组件
info "安装依赖..."
apt update -y && apt install -y curl wget jq openssl qrencode haveged
systemctl enable --now haveged >/dev/null 2>&1

info "下载/修复 Cloudflared..."
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
wget -q -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
chmod +x /usr/local/bin/cloudflared

if ! command -v xray >/dev/null; then
    info "安装 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# 4. 证书管理 (修正 24.04 权限问题)
CERT_DIR="/etc/xray"
mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERT_DIR/priv.key" -out "$CERT_DIR/cert.pem" \
  -subj "/CN=$DOMAIN" -batch >/dev/null 2>&1
chown -R nobody:nogroup "$CERT_DIR"
chmod -R 644 "$CERT_DIR"

# 5. Xray 配置 (2096 端口)
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 8)"
XRAY_PORT=2096

mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $XRAY_PORT,
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

# 6. 启动服务
systemctl restart xray
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel run --token $CF_TOKEN
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cloudflared

# ========================
# 核心功能：自动化健康检查
# ========================
info "🔎 正在执行系统健康检查..."
sleep 5  # 等待服务初始化

# 检查进程状态
XRAY_STATUS=$(systemctl is-active xray)
CF_STATUS=$(systemctl is-active cloudflared)

# 检查 2096 端口监听 (最关键)
PORT_CHECK=$(ss -tulpn | grep -w "$XRAY_PORT" || true)

echo "----------------------------------------"
if [ "$XRAY_STATUS" = "active" ] && [ -n "$PORT_CHECK" ]; then
    echo -e "✅ Xray 状态: \033[0;32m运行中 (端口 $XRAY_PORT 已开启)\033[0m"
else
    echo -e "❌ Xray 状态: \033[0;31m异常 (端口未监听，请检查证书权限)\033[0m"
    exit 1
fi

if [ "$CF_STATUS" = "active" ]; then
    echo -e "✅ Argo 状态: \033[0;32m运行中\033[0m"
else
    echo -e "❌ Argo 状态: \033[0;31m异常 (请检查 Token 是否有效)\033[0m"
    exit 1
fi
echo "----------------------------------------"

# 7. 输出结果
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=$(printf '%s' "$WS_PATH" | jq -sRr @uri)&sni=${DOMAIN}#Argo_2096"
info "✅ 部署成功！"
echo -e "\033[1;36m$VLESS_URI\033[0m"
qrencode -t ansiutf8 -m 1 "$VLESS_URI"
