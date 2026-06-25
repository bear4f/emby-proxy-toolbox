# Emby 反代 - Emby Proxy Toolbox

一个用于 VPS 的菜单式 **Nginx 反向代理工具箱**，面向 Emby / Jellyfin 等媒体服务场景。

脚本提供两种模式：

- **单站反代管理器**：为一个入口域名配置一个固定源站，适合长期稳定使用。
- **通用反代网关（Universal Gateway）**：部署一个网关入口后，可通过 URL 中的目标地址临时反代多个不同源站。

> ⚠️ **安全警告：通用反代网关属于“可变上游反代”。如果不加保护，可能变成 Open Proxy。**  
> 推荐优先启用 **URL 密钥前缀**，IP 固定时再叠加 **IP 白名单**。BasicAuth 可选，但部分客户端不支持。

---

## 功能特性

- ✅ Debian / Ubuntu 友好，默认使用系统 Nginx
- ✅ 中文菜单交互
- ✅ 自动安装依赖：`nginx`、`curl`、`rsync`、`certbot`、`apache2-utils`、`openssl` 等
- ✅ 自动写入 Nginx 站点配置
- ✅ `nginx -t` 校验失败自动回滚
- ✅ 可选自动申请 Let’s Encrypt 证书
- ✅ 支持 WebSocket、Range、长连接、长超时，适配 Emby 播放、刮削、转码等场景
- ✅ 支持源站 HTTP / HTTPS 回源
- ✅ 支持源站 HTTPS 自签证书跳过验证
- ✅ 支持额外高端口 HTTP 入口
- ✅ 通用网关支持 URL 密钥前缀，兼容不支持 BasicAuth 的客户端
- ✅ 通用网关支持 BasicAuth
- ✅ 通用网关支持 IP 白名单
- ✅ 通用网关支持 `proxy_redirect` 自动改写，避免跳转后绕过网关
- ✅ 启用 URL 密钥后，错误路径 / 无密钥访问自动 `444` 静默断开

---

## 一键使用

### 方式 A：curl 直接运行

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bear4f/emby-proxy-toolbox/main/emby-proxy-toolbox.sh)"
```

### 方式 B：下载后运行

```bash
curl -fsSL -o emby-proxy-toolbox.sh \
  https://raw.githubusercontent.com/bear4f/emby-proxy-toolbox/main/emby-proxy-toolbox.sh

chmod +x emby-proxy-toolbox.sh
sudo ./emby-proxy-toolbox.sh
```

如果系统没有 `sudo`，直接用 root 执行：

```bash
bash emby-proxy-toolbox.sh
```

---

## 主菜单说明

启动后会看到：

```text
1) 单站反代管理器（逐个域名配置）
2) 通用反代网关（一个入口反代多个上游）
0) 退出
```

---

# 1. 单站反代管理器

适合场景：你有一个固定的 Emby / Jellyfin 源站，希望长期通过一个入口域名访问。

示例：

```text
客户端 -> https://emby-gw.example.com/ -> 源站 http://1.2.3.4:8096
```

## 单站模式支持

- 固定源站域名 / IP
- 固定源站端口
- HTTP 或 HTTPS 回源
- 源站 HTTPS 自签证书跳过验证
- Let’s Encrypt 自动证书
- BasicAuth 可选
- 子路径反代可选，例如 `/emby`
- 额外高端口 HTTP 入口可选
- UFW 放行端口可选

## 单站模式使用流程

菜单选择：

```text
1) 单站反代管理器
1) 添加/覆盖单站反代（可选额外端口）
```

按提示填写：

```text
访问域名：emby.example.com
源站域名或IP：1.2.3.4
源站端口：8096
源站协议：http
是否申请 Let's Encrypt：y
是否启用 BasicAuth：按需
是否使用子路径：按需
额外端口入口：可空
```

完成后，客户端填写：

```text
https://emby.example.com/
```

如果使用子路径，例如 `/emby`，客户端填写：

```text
https://emby.example.com/emby
```

> 注意：如果启用子路径，建议在 Emby 后台把 Base URL 设置为对应子路径，并重启 Emby。

---

# 2. 通用反代网关（Universal Gateway）

适合场景：你有多个不同源站，不想为每个源站单独写 Nginx 配置。

通用网关只需要部署一次。客户端访问时，把源站地址写进 URL 路径里。

---

## 推荐安全模式

### 最推荐：URL 密钥前缀 + IP 白名单

```text
URL 密钥前缀：开启
BasicAuth：关闭
IP 白名单：开启
```

适合 IP 相对固定的自用场景，扫描面最小。

### 兼容性最好：URL 密钥前缀

```text
URL 密钥前缀：开启
BasicAuth：关闭
IP 白名单：关闭
```

适合 SenPlayer / Forward / 某些 Emby 客户端不支持 BasicAuth 的情况。

### 不推荐：完全不加保护

```text
URL 密钥前缀：关闭
BasicAuth：关闭
IP 白名单：关闭
```

这会让网关接近 Open Proxy。脚本会提示高风险，不建议这样部署。

---

## URL 密钥前缀是什么？

开启后，网关访问地址必须带一个随机密钥作为路径第一段。

原始无密钥格式：

```text
https://gw.example.com/源站:端口
https://gw.example.com/http/源站:端口
```

启用 URL 密钥后变成：

```text
https://gw.example.com/你的密钥/源站:端口
https://gw.example.com/你的密钥/http/源站:端口
```

例如：

```text
https://gw.example.com/a3f1c8d92b4e7061f5a2c9d8/emby.example.net:443
https://gw.example.com/a3f1c8d92b4e7061f5a2c9d8/http/203.0.113.10:8096
```

没有正确密钥的请求会被 Nginx 直接 `444` 断开。

> 密钥默认由脚本自动生成，格式类似 24 位 hex 字符串。当前密钥会保存到：
>
> ```text
> /etc/nginx/.emby-gw-key
> ```

---

## 通用网关部署流程

菜单选择：

```text
2) 通用反代网关
1) 安装/更新 通用反代网关
```

推荐选择：

```text
启用 URL 密钥前缀：y
启用 BasicAuth：n
启用 IP 白名单：按需
```

如果你之前遇到某些客户端报 `401`、`cooldown`、无法加载服务器，建议：

```text
URL 密钥前缀：y
BasicAuth：n
IP 白名单：按需
```

然后在客户端删除旧服务器，重新添加带密钥的新地址。

---

## 通用网关客户端填写格式

以下示例假设：

```text
网关域名：gw.example.com
URL 密钥：a3f1c8d92b4e7061f5a2c9d8
```

### 1）默认 HTTPS 回源

适合源站端口实际是 HTTPS 的情况，例如 443、8920 或其他 HTTPS 端口。

```text
https://gw.example.com/a3f1c8d92b4e7061f5a2c9d8/emby.example.net:443
https://gw.example.com/a3f1c8d92b4e7061f5a2c9d8/emby.example.net:8920
```

### 2）强制 HTTP 回源

适合源站端口实际是 HTTP 的情况，例如 8096、部分 18099 / 8097 / 自定义端口。

```text
https://gw.example.com/a3f1c8d92b4e7061f5a2c9d8/http/203.0.113.10:8096
https://gw.example.com/a3f1c8d92b4e7061f5a2c9d8/http/emby.example.net:18099
```

### 3）显式 HTTPS 回源

通常不必使用，因为默认就是 HTTPS 回源。

```text
https://gw.example.com/a3f1c8d92b4e7061f5a2c9d8/https/emby.example.net:443
```

> 兼容建议：部分客户端或转发器可能不喜欢 `/https/` 这种路径。遇到兼容问题时，HTTPS 回源直接用默认格式即可。

---

## 如何判断该用默认格式还是 `/http/`？

在 VPS 上测试源站端口。

### 测 HTTPS

```bash
curl -vk https://目标地址:端口/
```

如果看到类似：

```text
wrong version number
SSL routines
TLS handshake failed
```

通常说明这个端口不是 HTTPS，应使用 `/http/`。

### 测 HTTP

```bash
curl -v http://目标地址:端口/
```

如果能返回 `200`、`302`、`401`、`403` 等 HTTP 响应，说明该端口可以按 HTTP 回源，应使用：

```text
https://网关域名/密钥/http/目标地址:端口
```

---

# BasicAuth 说明

BasicAuth 是 Nginx 网关层的用户名密码，不是 Emby 自身账号密码。

访问流程大致是：

```text
客户端 -> Nginx BasicAuth -> Emby 登录
```

两层认证互不冲突。

但部分客户端、播放器、转发器不支持 BasicAuth，可能表现为：

```text
401
无法连接服务器
cooldown
一直加载失败
```

这种情况建议关闭 BasicAuth，改用：

```text
URL 密钥前缀 + IP 白名单
```

或至少：

```text
URL 密钥前缀
```

---

# IP 白名单说明

通用网关支持 IP 白名单。启用后，只有白名单内的 IP / CIDR 可以访问网关。

示例：

```text
1.2.3.4/32,5.6.7.8/32
```

如果你家宽、公网出口、固定代理出口比较稳定，建议开启。

如果你的客户端经常换 IP，例如移动网络、不同 Wi-Fi、漫游网络，IP 白名单可能导致访问失败。

---

# URL 密钥安全提醒

URL 密钥前缀属于“共享密钥”模式，优点是客户端兼容性好。

需要注意：

- 密钥会出现在客户端服务器地址中
- 密钥可能出现在 Nginx access log 中
- 密钥泄露后，应重新安装/更新网关并换新密钥
- URL 密钥不等于真正的用户体系，只适合作为网关入口门禁

如果非常在意日志中出现密钥，可以自行关闭该站点的 access log，或对日志做脱敏处理。

---

# Cloudflare 小黄云说明

入口是 80 / 443 时，一般适合通过 Cloudflare 代理。

如果使用额外高端口入口，需要注意：Cloudflare 只代理其支持的 HTTP / HTTPS 端口，不在支持列表内的高端口即使开橙云也可能失败。

建议：

- 最稳：使用域名 443 入口
- 高端口直连：DNS 记录用灰云（DNS only）
- 高端口走 Cloudflare：只使用 Cloudflare 支持的端口

端口列表以 Cloudflare 官方文档为准。

---

# 如何确认播放流量走 VPS？

## 方法 1：看 Nginx 连接

播放时执行：

```bash
ss -ntp | grep nginx | head
```

如果看到 VPS 同时连接客户端和源站，说明反代正在工作。

## 方法 2：看实时网卡流量

```bash
apt-get update && apt-get install -y iftop
iftop
```

播放时 VPS 流量应明显上涨。

## 方法 3：看统计流量

```bash
apt-get update && apt-get install -y vnstat
vnstat -l
```

---

# 常见问题

## 1. 客户端 401 / cooldown / 无法加载

优先检查是否开启了 BasicAuth。

某些客户端不支持 BasicAuth。建议重新安装/更新网关时选择：

```text
URL 密钥前缀：y
BasicAuth：n
IP 白名单：按需
```

然后删除客户端里的旧服务器，重新添加带密钥的新地址。

---

## 2. 播放一跳转就失败

通常是跳转地址没有被正确改写回网关。

本脚本的通用网关已经对 `proxy_redirect` 做了处理，启用 URL 密钥时，跳转后的地址也会自动带上密钥前缀。

---

## 3. HTTPS 回源报 `wrong version number`

说明你把 HTTP 端口当成 HTTPS 访问了。

例如源站实际是：

```text
http://1.2.3.4:8096
```

客户端应填写：

```text
https://网关域名/密钥/http/1.2.3.4:8096
```

而不是：

```text
https://网关域名/密钥/1.2.3.4:8096
```

---

## 4. IP + HTTPS 证书不匹配

这是正常现象。证书一般签发给域名，不签给裸 IP。

推荐使用：

```text
https://你的域名/
```

不要用：

```text
https://VPS_IP/
```

---

## 5. Nginx 配置失败怎么办？

脚本会在写配置前备份 `/etc/nginx/`，并在 `nginx -t` 失败时自动回滚。

备份目录通常类似：

```text
/root/nginx-backup-YYYYMMDD_HHMMSS
```

---

# 主要配置文件路径

```text
/etc/nginx/sites-available/
/etc/nginx/sites-enabled/
/etc/nginx/conf.d/emby-gw-map.conf
/etc/nginx/snippets/emby-gw-locations.conf
/etc/nginx/.htpasswd-emby
/etc/nginx/.htpasswd-emby-gw
/etc/nginx/.emby-gw-key
```

---

# 卸载

脚本菜单中提供卸载选项。

通用网关卸载会删除：

```text
网关站点配置
/etc/nginx/conf.d/emby-gw-map.conf
/etc/nginx/snippets/emby-gw-locations.conf
/etc/nginx/.htpasswd-emby-gw
/etc/nginx/.emby-gw-key
```

证书不会强制删除，避免误删。

如需手动删除证书：

```bash
certbot delete --cert-name 你的域名
```

---

# 更新脚本

重新执行一键命令即可进入菜单。

如果是通用网关，选择：

```text
2) 通用反代网关
1) 安装/更新 通用反代网关
```

注意：重新安装/更新时，如果重新生成 URL 密钥，旧客户端地址会失效，需要在客户端重新填写新地址。

---

# 免责声明

本项目仅用于合法、自用的反向代理场景。

请勿用于公共开放代理、非法访问、绕过授权、侵犯版权或其他违法用途。使用者应自行承担部署、网络流量、账号安全、源站授权和法律合规责任。
