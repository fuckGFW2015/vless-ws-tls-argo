#!/usr/bin/env bash
set -euo pipefail

die() { echo -e "\033[0;31m✖ $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[0;32m→ $*\033[0m"; }

[ "$(id -u)" -ne 0 ] && die "请使用 root 运行"

clear
echo "1) 安装 / 修复 (2096 端口)"
echo "2) 卸载"
read -rp "请选择: " ACTION

[ "$ACTION" = "2" ] && {
  systemctl disable --now xray cloudflared 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared.service /usr/local/bin/cloudflared
  rm -rf /usr/local/etc/xray /etc/xray /root/.cloudflared
  info "已卸载"; exit 0
}

read -rp "域名: " DOMAIN
read -rp "CF Token: " CF_TOKEN

info "安装依赖..."
apt update -y && apt install -y curl wget jq openssl qrencode haveged
systemctl enable --now haveged

ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
wget -q -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
chmod +x /usr/local/bin/cloudflared
! command -v xray >/dev/null && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 证书（安全权限）
CERT_DIR="/etc/xray"
mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERT_DIR/priv.key" -out "$CERT_DIR/cert.pem" \
  -subj "/CN=$DOMAIN" -batch >/dev/null 2>&1
chmod 600 "$CERT_DIR/priv.key"
chmod 644 "$CERT_DIR/cert.pem"

# Xray 配置
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
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

systemctl restart xray

# Cloudflared 配置（使用 config.yml）
CRED_DIR="/root/.cloudflared"
mkdir -p "$CRED_DIR"
cat > "$CRED_DIR/config.yml" <<EOF
ingress:
  - hostname: $DOMAIN
    service: https://localhost:$XRAY_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel (2096)
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel run --token-file <(echo "$CF_TOKEN")
Restart=on-failure
User=root
WorkingDirectory=$CRED_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart cloudflared

# 健康检查
sleep 4
systemctl is-active xray || die "Xray 启动失败"
systemctl is-active cloudflared || die "Cloudflared 启动失败"

# 输出结果
info "✅ 部署成功！"
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=$(printf '%s' "$WS_PATH" | jq -sRr @uri)&sni=${DOMAIN}#CF_2096"
echo -e "\033[1;36m$VLESS_URI\033[0m"
command -v qrencode >/dev/null && qrencode -t ansiutf8 -m 1 "$VLESS_URI"
