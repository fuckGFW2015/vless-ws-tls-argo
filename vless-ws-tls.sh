#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[0;32m→ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }
die() { echo -e "\033[0;31m✖ $*\033[0m" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] && die "请使用 root 运行"

# ======================
# 卸载函数
# ======================
uninstall() {
    info "开始卸载..."
    
    # 停止并禁用服务
    systemctl stop cloudflared xray 2>/dev/null || true
    systemctl disable cloudflared xray 2>/dev/null || true
    
    # 删除服务文件
    rm -f /etc/systemd/system/cloudflared.service
    systemctl daemon-reload
    
    # 删除二进制和配置
    rm -f /usr/local/bin/cloudflared
    rm -rf /etc/xray /usr/local/etc/xray
    
    # 可选：卸载 Xray（谨慎！）
    if command -v xray >/dev/null; then
        read -rp "是否彻底卸载 Xray？(y/N): " UNINSTALL_XRAY
        if [[ "${UNINSTALL_XRAY,,}" == "y" ]]; then
            if [ -f /usr/local/bin/xray ]; then
                /usr/local/bin/xray uninstall 2>/dev/null || true
            fi
        fi
    fi
    
    # 清理依赖（可选）
    read -rp "是否移除安装的依赖包？(curl/wget/jq/openssl/qrencode/haveged) (y/N): " REMOVE_DEPS
    if [[ "${REMOVE_DEPS,,}" == "y" ]]; then
        apt remove -y curl wget jq openssl qrencode haveged 2>/dev/null || true
    fi
    
    info "✅ 卸载完成！所有相关文件和服务已清理。"
    exit 0
}

# ======================
# 安装函数（你的核心逻辑）
# ======================
install() {
    info "正在安装核心依赖..."
    apt update -y >/dev/null 2>&1
    apt install -y curl wget jq openssl qrencode haveged >/dev/null 2>&1
    systemctl enable --now haveged >/dev/null 2>&1

    read -rp "请输入域名 (如 vargo.xxx.xxx): " DOMAIN
    read -rp "请输入 CF Token: " CF_TOKEN

    info "安装 Cloudflared..."
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    wget -q -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
    chmod +x /usr/local/bin/cloudflared

    info "配置 Xray (端口: 2096)..."
    if ! command -v xray >/dev/null; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    CERT_DIR="/etc/xray"
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$CERT_DIR/priv.key" -out "$CERT_DIR/cert.pem" \
      -subj "/CN=$DOMAIN" -batch >/dev/null 2>&1

    if id "xray" &>/dev/null; then
        chown -R xray:xray "$CERT_DIR"
    elif id "nobody" &>/dev/null && getent group nogroup >/dev/null; then
        chown -R nobody:nogroup "$CERT_DIR"
    else
        die "无法确定 Xray 运行用户"
    fi
    chmod 600 "$CERT_DIR/priv.key"
    chmod 644 "$CERT_DIR/cert.pem"

    UUID=$(cat /proc/sys/kernel/random/uuid)
    WS_PATH="/vargo$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
    mkdir -p /usr/local/etc/xray
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

    info "启动服务中..."
    systemctl restart xray

    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel run --token $CF_TOKEN
Restart=on-failure
User=root
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now cloudflared >/dev/null 2>&1

    # 健康检查
    info "🔎 执行健康检查 (最多等待 10 秒)..."
    CHECK_PORT=""
    for i in {1..10}; do
        if ss -tulpn 2>/dev/null | grep -q ":2096 "; then
            CHECK_PORT="OK"
            break
        fi
        sleep 1
    done

    XRAY_S=$(systemctl is-active xray 2>/dev/null || echo "inactive")
    CF_S=$(systemctl is-active cloudflared 2>/dev/null || echo "inactive")

    echo "----------------------------------------"
    [ "$XRAY_S" == "active" ] && echo -e "✅ Xray 进程: 在线" || warn "❌ Xray 进程: 离线"
    [ "${CHECK_PORT:-}" == "OK" ] && echo -e "✅ 2096 监听: 成功" || warn "❌ 2096 监听: 失败"
    [ "$CF_S" == "active" ] && echo -e "✅ Argo 隧道: 在线" || warn "❌ Argo 隧道: 离线"
    echo "----------------------------------------"

    VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=$(printf '%s' "$WS_PATH" | jq -sRr @uri)&sni=${DOMAIN}#Argo_2096"
    info "🎉 部署完成！"
    echo -e "\033[1;36m$VLESS_URI\033[0m"
    command -v qrencode >/dev/null && qrencode -t ansiutf8 -m 1 "$VLESS_URI"
}

# ======================
# 主菜单
# ======================
echo "========================================"
echo " VLESS + Cloudflare Argo 部署工具 (2096)"
echo "========================================"
echo "1) 安装 / 修复"
echo "2) 卸载"
echo "========================================"
read -rp "请选择 (1/2): " ACTION

case "$ACTION" in
    1|install|"") install ;;
    2|uninstall) uninstall ;;
    *) die "无效选项，请输入 1 或 2" ;;
esac
