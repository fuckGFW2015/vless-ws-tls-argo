#!/usr/bin/env bash
set -eu

# 颜色定义
info() { echo -e "\033[0;32m→ $*\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $*\033[0m"; }
die() { echo -e "\033[0;31m✖ $*\033[0m" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] && die "请使用 root 运行"

readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CERT_DIR="/etc/xray"
readonly CF_SERVICE="/etc/systemd/system/cloudflared.service"

# 检测是否已安装
is_installed() {
    [ -f "$CONFIG_DIR/config.json" ] || [ -f "$CF_SERVICE" ]
}

# ======================
# 卸载函数
# ======================
uninstall() {
    info "开始卸载 Vargo Argo 服务..."

    # 停止并禁用服务
    systemctl stop xray cloudflared 2>/dev/null || true
    systemctl disable xray cloudflared 2>/dev/null || true

    # 删除服务文件
    rm -f "$CF_SERVICE"
    systemctl daemon-reload

    # 删除二进制和配置
    rm -f /usr/local/bin/cloudflared
    rm -rf "$CONFIG_DIR" "$CERT_DIR"

    # 清理日志
    journalctl --vacuum-time=1s --quiet || true

    warn "已卸载 Vargo Argo 服务及相关配置。"
    warn "如需完全移除 Xray，请手动执行:"
    echo "  bash -c '\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)' @ remove"
    exit 0
}

# ======================
# 安装函数
# ======================
install() {
    if is_installed; then
        warn "检测到已安装，将覆盖现有配置。"
        read -rp "继续？(y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
    fi

    # 1. 安装依赖
    info "正在安装核心依赖..."
    apt update -y && apt install -y curl wget jq openssl qrencode haveged
    systemctl enable --now haveged >/dev/null 2>&1

    # 2. 用户输入
    read -rp "请输入域名 (如 vargo.example.com): " DOMAIN
    read -rsp "请输入 Cloudflare Tunnel Token: " CF_TOKEN
    echo

    # 3. 安装 Cloudflared
    info "安装 Cloudflared..."
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    if ! command -v cloudflared >/dev/null; then
        wget -q -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" \
            || die "下载 cloudflared 失败"
        chmod +x /usr/local/bin/cloudflared
    fi

    # 4. 安装 Xray
    info "配置 Xray (端口: 2096)..."
    if ! command -v xray >/dev/null; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    # 5. 生成自签名证书
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_DIR/priv.key" -out "$CERT_DIR/cert.pem" \
        -subj "/CN=$DOMAIN" -batch >/dev/null 2>&1
    chown -R nobody:nogroup "$CERT_DIR"
    chmod -R 755 "$CERT_DIR"

    # 6. 生成 Xray 配置
    UUID=$(cat /proc/sys/kernel/random/uuid)
    WS_PATH="/vargo$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.json" <<EOF
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

    # 7. 启动 Xray
    systemctl restart xray

    # 8. 配置 Cloudflared 服务（关键：Token 加双引号！）
    cat > "$CF_SERVICE" <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/cloudflared tunnel run --protocol grpc --token "$CF_TOKEN"
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now cloudflared

    # 9. 健康检查（增强版：用 pgrep 确认进程真实运行）
    info "🔎 执行健康检查 (最多等待 15 秒)..."
    sleep 3  # 给服务启动时间

    XRAY_OK=false
    CF_OK=false

    # 检查 Xray
    if systemctl is-active --quiet xray && ss -tulpn 2>/dev/null | grep -q ":2096 "; then
        XRAY_OK=true
    fi

    # 检查 Cloudflared（关键：不仅看状态，还要看进程）
    for i in {1..12}; do
        if systemctl is-active --quiet cloudflared && pgrep -x cloudflared >/dev/null; then
            CF_OK=true
            break
        fi
        sleep 1
    done

    echo "----------------------------------------"
    $XRAY_OK && echo -e "✅ Xray 进程: 在线" || warn "❌ Xray 进程: 离线"
    $XRAY_OK && echo -e "✅ 2096 监听: 成功" || warn "❌ 2096 监听: 失败"
    $CF_OK && echo -e "✅ Argo 隧道: 在线" || warn "❌ Argo 隧道: 离线"
    echo "----------------------------------------"

    if ! $CF_OK; then
        warn "Cloudflared 启动失败！查看日志："
        echo "  sudo journalctl -u cloudflared -n 20 --no-pager"
        exit 1
    fi

    # 10. 输出节点信息
    ENCODED_PATH=$(printf '%s' "$WS_PATH" | jq -sRr @uri)
    VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${ENCODED_PATH}&sni=${DOMAIN}#Argo_2096"
    info "🎉 部署完成！"
    echo -e "\n\033[1;36m$VLESS_URI\033[0m\n"
    if command -v qrencode >/dev/null; then
        qrencode -t ansiutf8 -m 1 "$VLESS_URI"
    else
        warn "qrencode 未安装，跳过二维码生成"
    fi
}

# ======================
# 主菜单
# ======================
show_menu() {
    clear
    echo "========================================"
    echo "   Vargo Argo 部署工具 (Xray + CF Tunnel)"
    echo "========================================"
    echo "1) 安装服务"
    echo "2) 卸载服务"
    echo "3) 退出"
    echo "----------------------------------------"
    read -rp "请选择操作 [1-3]: " choice

    case $choice in
        1) install ;;
        2) uninstall ;;
        3) exit 0 ;;
        *) die "无效选项，请输入 1、2 或 3" ;;
    esac
}

# ======================
# 入口
# ======================
if is_installed; then
    warn "检测到已安装 Vargo Argo 服务。"
fi

show_menu
