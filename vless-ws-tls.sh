#!/usr/bin/env bash
set -euo pipefail

die() { echo -e "\033[0;31m✖ $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[0;32m→ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }

if [ "$(id -u)" -ne 0 ]; then
  die "请使用 root 用户运行本脚本"
fi

clear
echo "╔══════════════════════════════════════════╗"
echo "║   VLESS+WS+TLS + CF Tunnel 最终修正版    ║"
echo "╚══════════════════════════════════════════╝"
echo "1) 安装 / 修复部署"
echo "2) 卸载全部组件"
echo "3) 退出"
read -rp "请选择操作 (1/2/3): " ACTION

if [ "$ACTION" = "2" ]; then
  info "正在卸载..."
  systemctl disable --now xray cloudflared 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared.service
  xray uninstall 2>/dev/null || true
  rm -rf /usr/local/etc/xray /etc/xray /root/.cloudflared /usr/local/bin/cloudflared
  info "✅ 卸载完成！"
  exit 0
fi

[[ "$ACTION" != "1" ]] && exit 0

read -rp "请输入域名: " DOMAIN
read -rp "请输入 CF Token: " CF_TOKEN

info "安装依赖..."
apt update -y && apt install -y curl wget jq openssl qrencode haveged
systemctl enable --now haveged 2>/dev/null || true

# 安装 Xray
if ! command -v xray >/dev/null; then
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# 安装 Cloudflared
if ! command -v cloudflared >/dev/null; then
  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  wget -q -O "/usr/local/bin/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
  chmod +x /usr/local/bin/cloudflared
fi

# 证书与权限
CERT_DIR="/etc/xray"
mkdir -p "$CERT_DIR"
info "生成自签名证书..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERT_DIR/priv.key" -out "$CERT_DIR/cert.pem" \
  -subj "/CN=$DOMAIN" -batch >/dev/null 2>&1
chown -R nobody:nogroup "$CERT_DIR"
chmod -R 644 "$CERT_DIR"

# 写入配置 (关键修正：增加 mkdir)
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 8)"
XRAY_PORT=44300

info "配置 Xray..."
mkdir -p /usr/local/etc/xray  # <--- 修复点在这里
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

# 启动服务
info "启动服务..."
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

sleep 3
REMARK="CF_Argo_$(echo $DOMAIN | cut -d'.' -f1)"
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=$(printf '%s' "$WS_PATH" | jq -sRr @uri)&sni=${DOMAIN}#${REMARK}"

clear
echo -e "\033[1;32m🎉 修复成功！\033[0m"
echo "$VLESS_URI"
echo
qrencode -t ansiutf8 -m 1 "$VLESS_URI"
