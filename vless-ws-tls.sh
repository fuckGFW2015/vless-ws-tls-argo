#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# VLESS + WS + TLS + Cloudflare Tunnel (HTTPS 增强版)
# 解决：证书读取权限、OpenSSL 卡死、UUID 自动生成
# ======================================================

die() { echo -e "\033[0;31m✖ $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[0;32m→ $*\033[0m"; }

if [ "$(id -u)" -ne 0 ]; then die "请使用 root 运行"; fi

# 1. 环境清理 (彻底清除旧配置防止冲突)
info "清理旧环境..."
systemctl disable --now xray cloudflared 2>/dev/null || true
rm -rf /etc/xray /usr/local/etc/xray

# 2. 获取输入
read -rp "请输入域名: " DOMAIN
read -rp "请输入 CF Token: " CF_TOKEN

# 3. 安装依赖 (引入 haveged 预热随机数池)
info "安装依赖..."
apt update -y && apt install -y curl wget jq openssl qrencode haveged
systemctl enable --now haveged 2>/dev/null || true

# 4. 安装 Xray
! command -v xray >/dev/null && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 5. 强制生成证书 (核心修复：使用 -batch 且权限全开)
CERT_DIR="/etc/xray"
mkdir -p "$CERT_DIR"
info "生成自签名证书 (HTTPS 核心)..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERT_DIR/priv.key" -out "$CERT_DIR/cert.pem" \
  -subj "/CN=$DOMAIN" -batch >/dev/null 2>&1

# 权限穿透：Ubuntu 24.04 必须让 nobody 拥有目录所有权
chown -R nobody:nogroup "$CERT_DIR"
chmod -R 755 "$CERT_DIR"

# 6. 配置 Xray (严格 HTTPS 模式)
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 8)"
XRAY_PORT=44300

mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $XRAY_PORT,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID"}],
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
      "wsSettings": {"path": "$WS_PATH"}
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

# 7. 启动服务 (注入 Root 权限尝试，确保端口开启)
info "启动 Xray 与 Tunnel..."
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

# 8. 结果输出与端口校验
sleep 5
clear
echo -e "\033[1;32m🎉 HTTPS 部署完成！\033[0m"
info "服务状态校验:"
if ss -tulpn | grep -q "$XRAY_PORT"; then
  echo -e "✅ Xray 监听成功 (Port: $XRAY_PORT)"
else
  warn "❌ 端口仍未开启！可能是证书权限被系统强行拦截。尝试运行: chown -R nobody:nogroup /etc/xray"
fi

REMARK="Argo_TLS_$(echo $DOMAIN | cut -d'.' -f1)"
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=$(printf '%s' "$WS_PATH" | jq -sRr @uri)&sni=${DOMAIN}#${REMARK}"

echo -e "\033[1;36m节点链接：\033[0m"
echo "$VLESS_URI"
qrencode -t ansiutf8 -m 1 "$VLESS_URI"
