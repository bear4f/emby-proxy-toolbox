README.md（最终版，安全示例已替换）
# Emby Proxy Toolbox（单站反代 + 通用反代网关，一体化脚本）

一个菜单式脚本，用于在 VPS 上部署 **Nginx 反向代理**，让 Emby / Jellyfin 等媒体访问 **走你的 VPS 出口**。

支持两种模式：

- **单站反代管理器**：为某个入口域名（可选子路径）配置固定源站，支持新增/查看/修改/删除，支持额外高端口入口。
- **通用反代网关（Universal Gateway）**：只需部署一次网关，客户端按格式填写  
  `https://你的网关域名/源站域名:端口`  
  即可临时反代任意源站，无需为每个源站单独写 Nginx 站点配置。

> ⚠️ **安全警告：通用网关是“可变上游反代”，不加保护会变成开放代理（Open Proxy）。**  
> 强烈建议开启 **IP 白名单**；BasicAuth 作为可选（部分客户端不支持）。

---

## 功能特性

- ✅ Debian 友好（默认使用系统 nginx；不强行覆盖 nginx.conf，避免 QUIC/http3 指令不兼容）
- ✅ 菜单交互（中文界面）
- ✅ 自动安装依赖（nginx/curl/rsync/certbot/apache2-utils 等）
- ✅ Nginx 配置校验 `nginx -t` + 自动回滚（配置错误自动恢复）
- ✅ 可选自动申请 Let’s Encrypt 证书（Certbot）
- ✅ 解决 Cloudflare/Host 依赖源站的 421 问题（动态 Host 头处理）
- ✅ 支持 WebSocket、Range、长超时（适配 Emby 播放/刮削/转码）
- ✅ 通用网关支持：
  - `https://网关域名/源站host:port`（**默认 HTTPS 回源**）
  - `https://网关域名/http/源站host:port`（**强制 HTTP 回源**）
  - `https://网关域名/https/源站host:port`（显式 HTTPS 回源；部分客户端可能不支持该路径）

---

## 一键使用

### 方式 A：curl 直接运行（推荐）

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bear4f/emby-proxy-toolbox/main/emby-proxy-toolbox.sh)"


将 <YOUR_GH_USER>/<YOUR_REPO> 替换成你的仓库路径。

方式 B：下载后运行
curl -fsSL -o emby-proxy-toolbox.sh \
  https://raw.githubusercontent.com/bear4f/emby-proxy-toolbox/main/emby-proxy-toolbox.sh

chmod +x emby-proxy-toolbox.sh
sudo ./emby-proxy-toolbox.sh

使用说明
1）单站反代（固定源站）

适合：你有一个固定 Emby 源站，要长期使用。

脚本里选择 单站反代管理器 → 添加/修改 → 填入：

入口域名（指向 VPS 的域名）

源站域名/IP + 端口（例如 8096/8920/443 等）

是否启用 TLS（Let’s Encrypt）

可选：IP 白名单 / BasicAuth / 子路径 / 额外高端口入口等

完成后，客户端填写：

https://你的入口域名/（如果开启 TLS）

或 http://你的入口域名/（未开启 TLS）

如启用“额外端口入口”，也可用：

http://你的入口域名:高端口/

http://VPS_IP:高端口/（注意是明文 HTTP）

注意：IP + HTTPS 会证书不匹配（正常现象），推荐 域名 + HTTPS。

2）通用反代网关（可变上游）

适合：你临时反代多个不同源站，不想每个都配置 Nginx。

部署一次网关后，在 Emby 客户端“服务器地址”里直接写：

✅ 上游是 HTTPS（常见：443 / 8920 / 18099* 也可能是 HTTP）

默认（HTTPS 回源）：

https://gw.example.com/emby.example.net:443

https://gw.example.com/emby.example.net:8920

✅ 上游是 HTTP（常见：8096 / 18099*）

强制 HTTP 回源（推荐用于“端口实际是 HTTP”的情况）：

https://gw.example.com/http/203.0.113.10:8096

https://gw.example.com/http/emby.example.net:18099

（可选）显式 HTTPS 回源

https://gw.example.com/https/emby.example.net:443

⭐ 如何判断该用 /http/ 还是默认？
在 VPS 上测试：

curl -vk https://目标:端口/ 如果出现 wrong version number / TLS 握手失败 → 该端口不是 HTTPS，用 /http/。

curl -v http://目标:端口/ 能正常 200/302 → 也说明是 HTTP，用 /http/。

✅ 兼容建议

某些客户端/转发器不支持 .../https/... 路径：直接用默认 https://网关域名/源站:端口（默认就是 HTTPS 回源）。

某些客户端不支持 BasicAuth：建议关闭 BasicAuth，改用 IP 白名单（更稳、更安全）。

BasicAuth 是什么？会不会影响 Emby 登录？

BasicAuth 是 Nginx 在最外层加的一道“网关密码”。访问网关时会先要求输入用户名/密码。

Emby 自己的账号密码 是第二层（源站应用层登录），两者不冲突。

但：部分播放器/转发器 不支持 BasicAuth（不会弹窗、不支持 user:pass@ 形式），这时建议使用 IP 白名单 替代。

Cloudflare 小黄云能不能反代？

取决于你用的入口方式：

入口是 80/443：一般没问题（常规 Web 代理端口）。

入口是 高端口：Cloudflare 仅代理其“允许的端口列表”。不在列表内的端口即使开橙云也可能访问失败。

建议：

高端口入口想走 IP:port → DNS 记录用 灰云（DNS only）

或改用 Cloudflare 支持的端口

或只用 域名 443 入口（最稳）

端口列表以 Cloudflare 官方文档为准（可能随时间变化）。

如何确认“播放走 VPS 流量”？

最简单的三种方法：

播放时看连接（你会看到 VPS 同时连着客户端与源站）：

ss -ntp | grep nginx | head


看实时网卡流量（播放时明显上涨）：

apt-get update && apt-get install -y iftop
iftop


看统计流量：

apt-get update && apt-get install -y vnstat
vnstat -l

卸载/回滚

脚本菜单内提供卸载选项（删除站点配置 / 删除网关配置）。
证书不会强制删除（避免误删），如需删除可手动执行：

sudo certbot delete --cert-name <你的域名>

免责声明

本项目仅用于合法用途与自用反代场景。
请勿用于任何违法用途或提供公共开放代理服务，否则可能导致封禁或法律风险。
