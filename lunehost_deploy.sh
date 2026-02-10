#!/bin/bash

clear
echo "========== LuneHosts 终极守护版 (含自动重连) =========="

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

# 4. 生成金刚不坏守护脚本 start.sh
cat <<EOF > start.sh
#!/bin/bash
cd /home/container

# [洁癖保护] 使用 /proc 彻底清理旧进程，零依赖，无报错
for pid in /proc/[0-9]*; do
    pid=\${pid##*/}
    if grep -qE "xray|cloudflared" "/proc/\$pid/cmdline" 2>/dev/null; then
        if [ "\$pid" != "\$\$" ]; then
            kill -9 "\$pid" >/dev/null 2>&1
        fi
    fi
done

chmod +x xray cloudflared

# [隧道守护] 定义无限循环重连逻辑
run_tunnel() {
    while true; do
        echo "[Argo] 正在建立隧道连接..."
        ./cloudflared tunnel --no-autoupdate run --token $CF_TOKEN > argo.log 2>&1
        echo "[Argo] 隧道异常退出，5秒后尝试重启..."
        sleep 5
    done
}

# 后台启动隧道守护循环
run_tunnel &

# [主进程绑定] 等待隧道握手并启动 Xray
# 使用 exec 使 Xray 成为容器主进程，方便面板监控
sleep 5
echo "[Xray] 启动核心程序..."
exec ./xray -c config.json
EOF
chmod +x start.sh

# 5. 拼接 VLESS 链接
# 这里的变量需要在生成脚本时就解析好
SAFE_PATH=$(echo $MY_PATH | sed 's/\//%2F/g')
VLESS_LINK="vless://$MY_UUID@$MY_DOMAIN:443?encryption=none&security=tls&type=ws&host=$MY_DOMAIN&path=$SAFE_PATH#Lune_Argo"

# 6. 最终输出
clear
echo "=========================================="
echo -e "\033[32m✅ 终极部署完成！\033[0m"
echo ""
echo "📝 配置摘要："
echo "域名: $MY_DOMAIN"
echo "UUID: $MY_UUID"
echo "路径: $MY_PATH"
echo ""
echo "🔗 节点链接 (直接复制):"
echo -e "\033[33m$VLESS_LINK\033[0m"
echo "=========================================="
echo "⚠️  操作提示:"
echo "1. 请确认 Startup Command 已设为: bash start.sh"
echo "2. 建议先 STOP 再 START 服务器以应用纯净环境。"
echo "=========================================="

# 首次尝试启动
bash start.sh
