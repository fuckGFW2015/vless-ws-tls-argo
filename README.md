### 一键安装/卸载命令

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fuckGFW2015/vless-ws-tls-argo/refs/heads/main/vless-ws-tls.sh)"
```

或使用 wget（兼容无 curl 的系统）：
```
bash -c "$(wget -qO- https://raw.githubusercontent.com/fuckGFW2015/vless-ws-tls-argo/refs/heads/main/vless-ws-tls.sh)"

```
✅ 在 Cloudflare Zero Trust 面板操作：

    进入 Access > Tunnels
    找到你的隧道 → Configure
    添加 Public Hostname：
        Hostname: huihechow89.dpdns.org
        URL: https://localhost:2096
        ✅ Enable "Disable TLS verification"（关键！否则自签证书失败）

    💡 这样既避免了本地配置冲突，又利用了 CF 的 NoTLSVerify 开关。
