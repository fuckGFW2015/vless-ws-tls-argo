#!/bin/bash

echo "========== LuneHosts 交互式部署 =========="

# 使用 echo 强制回显提示，再用 read 接收
echo "👉 步骤 1: 请输入 Cloudflare Token"
read CF_TOKEN

echo "👉 步骤 2: 请输入你的域名 (如 node.abc.com)"
read MY_DOMAIN

echo "👉 步骤 3: 请输入 UUID (直接回车随机生成)"
read INPUT_UUID
MY_UUID=${INPUT_UUID:-$(cat /proc/sys/kernel/random/uuid)}

echo "👉 步骤 4: 请输入路径 (直接回车默认 /lune)"
read INPUT_PATH
MY_PATH=${INPUT_PATH:-/lune}

echo "------------------------------------------"
echo "⏳ 正在拉取组件并生成配置..."

# 1. 下载程序
curl -L -s -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -qo xray.zip
chmod +x xray
curl -L -s -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared

# 2. 生成 Xray 配置
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

# 3. 生成永久守护脚本 start.sh (把变量写死进去)
cat <<EOF > start.sh
#!/bin/bash
cd /home/container
chmod +x xray cloudflared
nohup ./cloudflared tunnel --no-autoupdate run --token $CF_TOKEN > argo.log 2>&1 &
sleep 2
./xray -c config.json
EOF
chmod +x start.sh

# 4. 给出反馈
clear
echo "✅ 部署完成！"
echo "UUID: $MY_UUID"
echo "Path: $MY_PATH"
echo "------------------------------------------"
echo "⚠️  最后一步 (防断连):"
echo "1. 停止服务器。"
echo "2. 在 Startup Command 填入: bash start.sh"
echo "3. 重启服务器。"
echo "------------------------------------------"

# 启动尝试
bash start.sh
