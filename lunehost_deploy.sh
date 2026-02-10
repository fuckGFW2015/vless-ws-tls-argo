#!/bin/bash

# 1. 交互式輸入提醒
echo "========== LuneHosts 部署配置 =========="
read -p "請輸入 Cloudflare Tunnel Token: " CF_TOKEN
read -p "請輸入 UUID (按回車隨機生成): " MY_UUID
read -p "請輸入 WebSocket 路徑 (例如 /lune, 按回車隨機生成): " MY_PATH
read -p "請輸入節點域名 (例如 node.example.com): " MY_DOMAIN

# 2. 如果用戶沒輸入，則自動生成
if [ -z "$MY_UUID" ]; then
    MY_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "使用隨機 UUID: $MY_UUID"
fi

if [ -z "$MY_PATH" ]; then
    MY_PATH="/lune$(date +%s | tail -c 4)"
    echo "使用隨機路徑: $MY_PATH"
fi

if [ -z "$CF_TOKEN" ] || [ -z "$MY_DOMAIN" ]; then
    echo "錯誤：Token 和 域名 為必填項！"
    exit 1
fi

# 3. 下載二進制文件 (針對翼龍面板容器環境)
echo "正在下載組件..."
curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o xray.zip
chmod +x xray

curl -L -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared

# 4. 生成 config.json (本地運行模式)
cat <<EOF > config.json
{
    "inbounds": [{
        "port": 8080,
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": { "clients": [{"id": "$MY_UUID"}], "decryption": "none" },
        "streamSettings": { "network": "ws", "wsSettings": { "path": "$MY_PATH" } }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 5. 生成 VLESS 節點鏈接並顯示
VMESS_LINK="vless://$MY_UUID@$MY_DOMAIN:443?encryption=none&security=tls&type=ws&host=$MY_DOMAIN&path=$(echo $MY_PATH | sed 's/\//%2F/g')#Lune_Argo"

echo "=========================================="
echo -e "\033[32m部署完成！您的節點鏈接為：\033[0m"
echo -e "\033[33m$VMESS_LINK\033[0m"
echo "=========================================="

# 6. 啟動服務
# 先在後台運行隧道，最後一行不加 & 以保持容器運行
echo "正在啟動服務，請勿關閉窗口..."
./cloudflared tunnel --no-autoupdate run --token $CF_TOKEN > /dev/null 2>&1 &
./xray -c config.json
