#!/bin/bash

# 1. 输入 Token
read -p "请输入你的 Cloudflare Tunnel Token: " CF_TOKEN
read -p "请输入你在 CF 绑定的域名 (例如 node.example.com): " MY_DOMAIN

if [ -z "$CF_TOKEN" ] || [ -z "$MY_DOMAIN" ]; then
    echo "错误：Token 和 域名 均不能为空。"
    exit 1
fi

# 2. 安装/更新基础组件
apt update && apt install -y curl wget jq

# 3. 安装 Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 4. 自动生成随机配置
MY_UUID=$(cat /proc/sys/kernel/random/uuid)
MY_PATH="/lune$(date +%s | tail -c 4)"

cat <<EOF > /usr/local/etc/xray/config.json
{
    "inbounds": [{
        "port": 8080,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": { "clients": [{"id": "$MY_UUID"}], "decryption": "none" },
        "streamSettings": { "network": "ws", "wsSettings": { "path": "$MY_PATH" } }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 5. 安装并注册 Cloudflared 服务
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token $CF_TOKEN
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# 6. 重启服务
systemctl daemon-reload
systemctl restart xray
systemctl enable xray
systemctl enable cloudflared
systemctl restart cloudflared

# 7. 拼接 VLESS 链接
# 格式: vless://uuid@domain:443?encryption=none&security=tls&type=ws&host=domain&path=path#remark
VMESS_LINK="vless://$MY_UUID@$MY_DOMAIN:443?encryption=none&security=tls&type=ws&host=$MY_DOMAIN&path=$(echo $MY_PATH | sed 's/\//%2F/g')#LuneHosts_CF_Tunnel"

# 8. 输出结果
clear
echo "=========================================="
echo "🎉 部署完成！"
echo "=========================================="
echo -e "\033[33m您的专用 VLESS 链接如下：\033[0m"
echo -e "\033[32m$VMESS_LINK\033[0m"
echo "=========================================="
echo "注意事项："
echo "1. 请确保 CF 控制台已将 $MY_DOMAIN 指向 http://localhost:8080"
echo "2. 如果连接不上，请检查 LuneHosts 的系统防火墙是否放行了相关流量"
echo "3. 链接已包含 TLS 和 WS 设置，直接导入即可使用"
echo "=========================================="
