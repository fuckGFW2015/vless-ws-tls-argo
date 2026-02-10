#!/bin/bash

# 优化 1：使用标准 echo 代替 read -p，提高面板兼容性
echo "------------------------------------------"
echo "👉 请在下方输入框输入 Cloudflare Token 并回车:"
read CF_TOKEN

echo "👉 请输入你的域名 (例如 node.abc.com):"
read MY_DOMAIN

echo "👉 请输入 UUID (直接回车则随机生成):"
read INPUT_UUID
MY_UUID=${INPUT_UUID:-$(cat /proc/sys/kernel/random/uuid)}

echo "👉 请输入 Path (直接回车则默认 /lune):"
read INPUT_PATH
MY_PATH=${INPUT_PATH:-/lune}

# 优化 2：检查必填项
if [ -z "$CF_TOKEN" ] || [ -z "$MY_DOMAIN" ]; then
    echo "❌ 错误：Token 和域名不能为空！请重新启动脚本。"
    exit 1
fi

# 优化 3：环境静默安装（不弹框）
echo "⏳ 正在环境准备..."
curl -L -s -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -qo xray.zip
chmod +x xray
curl -L -s -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared

# 生成配置 (略，同之前逻辑)...

# 优化 4：生成节点链接
echo "=========================================="
echo "✅ 配置成功！"
echo "UUID: $MY_UUID"
echo "PATH: $MY_PATH"
echo "节点链接:"
echo "vless://$MY_UUID@$MY_DOMAIN:443?encryption=none&security=tls&type=ws&host=$MY_DOMAIN&path=$(echo $MY_PATH | sed 's/\//%2F/g')#Lune_Argo"
echo "=========================================="

# 启动 (容器前台运行逻辑)
./cloudflared tunnel --no-autoupdate run --token $CF_TOKEN > /dev/null 2>&1 &
./xray -c config.json
