#!/bin/bash

# 1. 交互式输入 (仅在第一次部署时询问)
echo "========== LuneHosts 全自动部署 =========="
read -p "请输入 Cloudflare Tunnel Token: " CF_TOKEN
read -p "请输入你的域名: " MY_DOMAIN
read -p "请输入 UUID (回车随机): " INPUT_UUID
MY_UUID=${INPUT_UUID:-$(cat /proc/sys/kernel/random/uuid)}
read -p "请输入路径 (回车默认 /lune): " INPUT_PATH
MY_PATH=${INPUT_PATH:-/lune}

# 2. 下载必要组件
echo "正在下载 Xray 和 Cloudflared..."
curl -L -s -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -qo xray.zip
chmod +x xray
curl -L -s -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared

# 3. 生成 Xray 配置文件 (config.json)
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

# 4. 【核心】自动生成 start.sh 守护脚本
echo "正在生成守护脚本 start.sh..."
cat <<EOF > start.sh
#!/bin/bash
cd /home/container
chmod +x xray cloudflared
# 启动隧道
nohup ./cloudflared tunnel --no-autoupdate run --token $CF_TOKEN > argo.log 2>&1 &
sleep 2
# 启动 Xray (前台运行保持容器不灭)
./xray -c config.json
EOF

chmod +x start.sh

# 5. 输出节点信息
VMESS_LINK="vless://$MY_UUID@$MY_DOMAIN:443?encryption=none&security=tls&type=ws&host=$MY_DOMAIN&path=$(echo $MY_PATH | sed 's/\//%2F/g')#Lune_Argo"

clear
echo "=========================================="
echo -e "\033[32m🎉 部署成功！\033[0m"
echo -e "你的节点链接：\033[33m$VMESS_LINK\033[0m"
echo "=========================================="
echo "⚠️  重要步骤："
echo "1. 请前往面板的 [Startup] 设置。"
echo "2. 将 [Startup Command] 修改为: bash start.sh"
echo "3. 修改完成后，点击面板的 [RESTART] 重启服务器。"
echo "=========================================="

# 6. 第一次运行直接启动
echo "正在尝试首次启动..."
bash start.sh
