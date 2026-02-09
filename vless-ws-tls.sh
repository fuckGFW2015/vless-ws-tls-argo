#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# VLESS + WebSocket + TLS + Cloudflare Tunnel 管理器
# 功能：安装 / 卸载（无 Nginx）+ 自动生成 VLESS 链接 + 二维码
# ======================================================

die() { echo -e "\033[0;31m✖ $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[0;32m→ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }

if [ "$(id -u)" -ne 0 ]; then
  die "请使用 root 用户运行本脚本（sudo su -）"
fi

clear
echo -e "\033[1;36m"
echo "╔══════════════════════════════════════════╗"
echo "║   VLESS+WS+TLS + CF Tunnel 管理器        ║"
echo "║    （无 Nginx · 一键安装/卸载 · 带二维码）║"
echo "╚══════════════════════════════════════════╝"
echo -e "\033[0m"

echo -e "\033[1;34m1) 安装 VLESS + Cloudflare Tunnel\033[0m"
echo -e "\033[0;31m2) 卸载全部组件\033[0m"
echo -e "\033[1;33m3) 退出\033[0m"
echo

while true; do
  read -rp "请选择操作 (1/2/3): " ACTION
  case "$ACTION" in
    1|2|3) break ;;
    *) echo -e "\033[0;31m✖ 请输入 1、2 或 3。\033[0m" ;;
  esac
done

if [ "$ACTION" = "3" ]; then
  echo -e "\033[1;36m👋 已退出。\033[0m"
  exit 0
fi

# ========================
# 卸载函数
# ========================
uninstall_all() {
  info "开始卸载所有组件..."

  # 停止并移除服务
  systemctl disable --now xray cloudflared 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared.service
  systemctl daemon-reload

  # 移除二进制
  xray uninstall 2>/dev/null || true
  rm -f /usr/local/bin/cloudflared

  # 清理配置与证书
  rm -rf /usr/local/etc/xray
  rm -rf /root/.cloudflared
  rm -rf /etc/xray

  # 清理可能残留的日志（可选）
  journalctl --vacuum-time=1s --quiet 2>/dev/null || true

  info "✅ 所有组件已卸载完成。"
}

if [ "$ACTION" = "2" ]; then
  read -rp "确定要卸载所有组件吗？(y/N): " CONFIRM
  if [[ "${CONFIRM,,}" == "y" ]]; then
    uninstall_all
  else
    echo -e "\033[1;33mℹ 取消卸载。\033[0m"
  fi
  exit 0
fi

# ========================
# 安装流程（ACTION=1）
# ========================

read -rp "请输入你的域名（如：example.com）: " DOMAIN
[[ -z "$DOMAIN" ]] && die "域名不能为空！"

echo
echo "请提供 Cloudflare Tunnel Token（以 eyJ 开头）"
while true; do
  read -rp "Token: " CF_TOKEN
  [[ -n "$CF_TOKEN" && "$CF_TOKEN" == eyJ* ]] && break
  warn "Token 必须以 'eyJ' 开头，请重新输入。"
done

# 安装依赖（含 qrencode）
info "安装依赖..."
if [ -f /etc/debian_version ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt update -y && apt install -y curl wget jq openssl qrencode
elif [ -f /etc/redhat-release ]; then
  yum install -y epel-release
  yum install -y curl wget jq openssl qrencode
elif [ -f /etc/alpine-release ]; then
  apk add --no-cache curl wget jq openssl qrencode
else
  die "不支持的系统（仅支持 Debian/Ubuntu/CentOS/Alpine）"
fi

# 安装 Xray
if ! command -v xray >/dev/null; then
  info "安装 Xray..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
  info "Xray 已安装，跳过。"
fi

# 安装 cloudflared
if ! command -v cloudflared >/dev/null; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) FILE="cloudflared-linux-amd64" ;;
    aarch64|arm64) FILE="cloudflared-linux-arm64" ;;
    *) die "不支持的架构: $ARCH" ;;
  esac
  VERSION=$(curl -sI "https://github.com/cloudflare/cloudflared/releases/latest" | grep -i 'location:' | sed 's/.*tag\///; s/\r$//')
  wget -q -O "/usr/local/bin/cloudflared" "https://github.com/cloudflare/cloudflared/releases/download/${VERSION}/${FILE}"
  chmod +x /usr/local/bin/cloudflared
  info "✅ cloudflared 安装完成"
else
  info "cloudflared 已安装，跳过。"
fi

# 生成自签名证书
CERT_DIR="/etc/xray"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/cert.pem" ]; then
  info "生成自签名证书..."
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/C=US/ST=State/L=City/O=Org/CN=$DOMAIN" \
    -keyout "$CERT_DIR/priv.key" -out "$CERT_DIR/cert.pem" >/dev/null 2>&1
  chmod 600 "$CERT_DIR"/*.key "$CERT_DIR"/*.pem
fi

# 配置 Xray
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
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

systemctl enable --now xray

# 配置 Cloudflare Tunnel
CRED_DIR="/root/.cloudflared"
mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"

TOKEN_FILE="$CRED_DIR/cf-token"
printf '%s' "$CF_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

cat > "$CRED_DIR/config.yml" <<EOF
ingress:
  - hostname: $DOMAIN
    service: https://localhost:$XRAY_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
chmod 600 "$CRED_DIR/config.yml"

# systemd 服务
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel (VLESS, No Nginx)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel run --token-file $TOKEN_FILE
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=$CRED_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared

# 验证
sleep 5
if ! systemctl is-active --quiet xray || ! systemctl is-active --quiet cloudflared; then
  die "❌ 服务启动失败，请检查日志：journalctl -u xray 或 -u cloudflared"
fi

# ========================
# 生成 VLESS URI 和二维码
# ========================
ENCODED_PATH=$(printf '%s' "$WS_PATH" | jq -sRr @uri)
# 备注名：将 . 替换为 _，避免部分客户端解析问题
REMARK="${DOMAIN//./_}_VLESS_WS_CF"

VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${ENCODED_PATH}&sni=${DOMAIN}#${REMARK}"

echo
echo -e "\033[1;32m🎉 部署成功！\033[0m"
echo
echo "🌐 域名: $DOMAIN"
echo "🆔 用户ID: $UUID"
echo "🔗 路径: $WS_PATH"
echo

echo -e "\033[1;35m🔗 一键导入链接（VLESS URI）:\033[0m"
echo -e "\033[0;36m$VLESS_URI\033[0m"
echo

# 显示二维码
if command -v qrencode >/dev/null; then
  echo -e "\033[1;35m📱 终端二维码（手机扫码导入）:\033[0m"
  qrencode -t ansiutf8 -m 1 "$VLESS_URI"
else
  warn "qrencode 未找到，跳过二维码显示（可手动安装：apt install qrencode）"
fi

echo
echo "💡 重要：确保域名在 Cloudflare 中为橙色云（Proxied）！"
echo "🧹 如需卸载，请再次运行本脚本并选择【2】"
