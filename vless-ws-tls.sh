#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# VLESS + WebSocket + TLS + Cloudflare Tunnel 修复版
# ======================================================

die() { echo -e "\033[0;31m✖ $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[0;32m→ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }

if [ "$(id -u)" -ne 0 ]; then
  die "请使用 root 用户运行本脚本"
fi

clear
echo -e "\033[1;36m修复版管理器启动中...\033[0m"

# ========================
# 交互部分
# ========================
read -rp "请输入你的域名（如：example.com）: " DOMAIN
[[ -z "$DOMAIN" ]] && die "域名不能为空！"

echo "请输入 CF Tunnel Token（以 eyJ 开头）"
while true; do
  read -rp "Token: " CF_TOKEN
  [[ -n "$CF_TOKEN" && "$CF_TOKEN" == eyJ* ]] && break
  warn "Token 格式错误，请重新输入。"
done

# ========================
# 安装依赖
# ========================
info "安装/检查依赖..."
if [ -f /etc/debian_version ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt update -y && apt install -y curl wget jq openssl qrencode haveged
elif [ -f /etc/redhat-release ]; then
  yum install -y epel-release
  yum install -y curl wget jq openssl qrencode haveged
fi

# 启动 haveged 增加系统熵，防止 openssl/xray 卡死
systemctl enable --now haveged 2>/dev/null || true

# ========================
# 安装 Xray & Cloudflared
# ========================
if ! command -v xray >/dev/null; then
  info "安装 Xray..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

if ! command -v cloudflared >/dev/null; then
  info "下载 cloudflared..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) FILE="cloudflared-linux-amd64" ;;
    aarch64|arm64) FILE="cloudflared-linux-arm64" ;;
    *) die "不支持的架构: $ARCH" ;;
  esac
  VERSION=$(curl -sI "https://github.com/cloudflare/cloudflared/releases/latest" | grep -i 'location:' | sed 's/.*tag\///; s/\r$//')
  wget -q -O "/usr/local/bin/cloudflared" "https://github.com/cloudflare/cloudflared/releases/download/${VERSION}/${FILE}"
  chmod +x /usr/local/bin/cloudflared
fi

# ========================
# 生成自签名证书 (修复点)
# ========================
CERT_DIR="/etc/xray"
mkdir -p "$CERT_DIR"
# 无论证书是否存在都强制生成，防止损坏的证书导致 Xray 无法启动
info "正在生成自签名证书 (RSA 2048)..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERT_DIR/priv.key" \
  -out "$CERT_DIR/cert.pem" \
  -subj "/C=US/ST=State/L=City/O=Org/CN=$DOMAIN" \
  -batch >/dev/null 2>&1 || die "OpenSSL 生成证书失败，请检查 openssl 是否安装正确"

chmod 600 "$CERT_DIR"/*.key "$CERT_DIR"/*.pem
info "✅ 证书生成成功"

# ========================
# 配置 Xray (修复路径获取)
# ========================
UUID=$(cat /proc/sys/kernel/random/uuid)
# 修复此处随机字符串获取方式，防止卡死
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 8)"
XRAY_PORT=44300

mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $XRAY_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": ""}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "$CERT_DIR/cert.pem",
          "keyFile": "$CERT_DIR/priv.key"
        }]
      },
      "wsSettings": {
        "path": "$WS_PATH"
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

systemctl daemon-reload
systemctl enable --now xray

# ========================
# 配置 Cloudflare Tunnel
# ========================
CRED_DIR="/root/.cloudflared"
mkdir -p "$CRED_DIR"
echo "$CF_TOKEN" > "$CRED_DIR/cf-token"

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
Description=Cloudflare Tunnel
After=network-online.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel run --token-file $CRED_DIR/cf-token
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=$CRED_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared

# 验证启动状态
info "等待服务启动 (5s)..."
sleep 5
if ! systemctl is-active --quiet xray || ! systemctl is-active --quiet cloudflared; then
  die "❌ 启动失败。请运行 'journalctl -u cloudflared' 查看原因。"
fi

# ========================
# 生成链接
# ========================
REMARK="${DOMAIN//./_}_VLESS"
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=$(printf '%s' "$WS_PATH" | jq -sRr @uri)&sni=${DOMAIN}#${REMARK}"

clear
echo -e "\033[1;32m🎉 部署成功！\033[0m"
echo -e "\033[1;36m链接：\033[0m $VLESS_URI"
echo
qrencode -t ansiutf8 -m 1 "$VLESS_URI"
