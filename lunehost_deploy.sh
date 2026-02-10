#!/bin/bash

clear
echo "========== LuneHosts 交互式部署 (含链接生成) =========="

# 1. 交互输入提醒
echo "👉 步骤 1: 请输入 Cloudflare Token"
read CF_TOKEN

echo "👉 步骤 2: 请输入你的域名 (如 node.abc.com)"
read MY_DOMAIN

echo "👉 步骤 3: 请输入 UUID (直接回车随机生成)"
read INPUT_UUID
MY_UUID=${INPUT_UUID:-$(cat /proc/sys/kernel/random/uuid)}

echo "👉 步骤 4: 请输入路径 (必须以/开头，直接回车默认 /lune)"
read INPUT_PATH
MY_PATH=${INPUT_PATH:-/lune}

echo "------------------------------------------"
echo "⏳ 正在拉取组件并生成配置..."

# 2. 下载程序
curl -L -s -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -qo xray.zip
chmod +x xray
curl -L -s -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared

# 3. 生成 Xray 配置
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

# 4. 生成永久守护脚本 start.sh
cat <<EOF > start.sh
#!/bin/bash
cd /home/container

# 检查并清理可能残留的旧进程，防止端口占用或 Token 冲突
pkill -9 xray
pkill -9 cloudflared

chmod +x xray cloudflared

# 启动隧道并记录日志
# 使用 run --token 是最稳定的方式
nohup ./cloudflared tunnel --no-autoupdate run --token $CF_TOKEN > argo.log 2>&1 &

# 等待隧道握手
sleep 5

# 使用 exec 接管进程，让面板直接监控 Xray，效率更高
exec ./xray -c config.json
EOF
chmod +x start.sh

# 5. 【核心】拼接 VLESS 链接
# 处理路径中的斜杠以便用于 URL
SAFE_PATH=$(echo $MY_PATH | sed 's/\//%2F/g')
VLESS_LINK="vless://$MY_UUID@$MY_DOMAIN:443?encryption=none&security=tls&type=ws&host=$MY_DOMAIN&path=$SAFE_PATH#Lune_Argo"

# 6. 最终输出
clear
echo "=========================================="
echo -e "\033[32m✅ 部署成功！\033[0m"
echo ""
echo "📝 你的节点配置信息："
echo "域名: $MY_DOMAIN"
echo "UUID: $MY_UUID"
echo "路径: $MY_PATH"
echo ""
echo "🔗 VLESS 链接 (直接复制到客户端):"
echo -e "\033[33m$VLESS_LINK\033[0m"
echo ""
echo "=========================================="
echo "⚠️  最后一步 (关掉网页不断线):"
echo "1. 停止(STOP)服务器。"
echo "2. 在 [Startup] 菜单的 Startup Command 填入: bash start.sh"
echo "3. 重新启动(START)服务器。"
echo "=========================================="

# 启动尝试
bash start.sh
