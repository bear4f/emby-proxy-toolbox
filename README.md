
# Emby Proxy Toolbox（单站反代 + 通用反代网关，一体化脚本）

一个菜单式脚本，一键在 VPS 上部署 **Nginx 反向代理**，用于让 Emby / Jellyfin 等媒体流量**走你的 VPS 出口**。

支持两种模式：

- **单站反代管理器**：为某个域名（或域名+子路径）配置固定源站，支持新增/查看/修改/删除，支持额外高端口入口。
- **通用反代网关（Universal Gateway）**：只需部署一次网关，客户端按格式填写  
  `https://你的网关域名/源站域名:端口`  
  即可临时反代任意 Emby 源站，无需一个个写 Nginx 站点配置。

> ⚠️ **安全警告：通用网关本质上是“可变上游反代”，如果不加保护会变成开放代理（Open Proxy）。**  
> 强烈建议开启 BasicAuth 或 IP 白名单，至少二选一。

---

## 功能特性

- ✅ Debian 友好（默认使用系统 nginx，不强行覆盖 nginx.conf，避免 QUIC/http3 指令不兼容）
- ✅ 菜单交互（中文界面）
- ✅ 自动安装依赖（nginx/curl/rsync/certbot/apache2-utils 等）
- ✅ Nginx 配置校验 `nginx -t` + 自动回滚（配置错误自动恢复）
- ✅ 可选自动申请 Let’s Encrypt 证书（Certbot）
- ✅ 解决 Cloudflare/Host 依赖源站的 421 问题（`proxy_set_header Host $proxy_host` / 动态 Host）
- ✅ 支持 WebSocket、Range、长超时（适配 Emby 播放/刮削/转码）
- ✅ 通用网关支持：
  - `https://网关域名/源站host:port`（默认 HTTPS 回源）
  - `https://网关域名/http/源站host:port`（强制 HTTP 回源）
  - `https://网关域名/https/源站host:port`（显式 HTTPS 回源）

---

## 一键使用

### 方式 A：curl 直接运行（推荐）

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bear4f/emby-proxy-toolbox/main/emby-proxy-toolbox.sh)"
````

### 方式 B：下载后本地运行

```bash
curl -fsSL -o emby-proxy-toolbox.sh \
  https://raw.githubusercontent.com/bear4f/emby-proxy-toolbox/main/emby-proxy-toolbox.sh

chmod +x emby-proxy-toolbox.sh
sudo ./emby-proxy-toolbox.sh
```

---

## 使用说明

### 1）单站反代（固定源站）

适合：你有一个固定 Emby 源站，要长期使用。

脚本里选择 **单站反代管理器** → 添加/修改 → 填入：

* 入口域名（你指向 VPS 的域名）
* 源站域名/IP + 端口（例如 8096/8920/443 等）
* 是否启用 TLS（Let’s Encrypt）
* 可选：BasicAuth、子路径、额外高端口入口等

完成后，客户端填：

* `https://你的域名/`（如果开启 TLS）
* 或 `http://你的域名/`（未开启 TLS）

如启用“额外端口入口”，也可用：

* `http://你的域名:高端口/`
* `http://VPS_IP:高端口/`（注意是明文 HTTP）

> 注意：IP + HTTPS 会证书不匹配，属正常现象。推荐域名 + HTTPS。

---

### 2）通用反代网关（可变上游）

适合：你临时反代多个不同的 Emby 源站，不想每个都配置 Nginx。

部署一次网关后，在 Emby 客户端“服务器地址”里直接写：

默认（HTTPS 回源）：

* `https://你的网关域名/emby.example.com:443`

强制 HTTP 回源：

* `https://你的网关域名/http/203.0.113.10:8096`

显式 HTTPS 回源（部分客户端/转发器可能不支持该路径）：

* `https://你的网关域名/https/emby.example.com:443`

> ✅ 兼容建议
>
> * **Forward 不支持** `.../https/...` 的话，就用默认格式：`https://网关域名/源站:端口`（默认就是 HTTPS 回源）。
> * **SenPlayer 不支持 BasicAuth** 的话：建议关闭 BasicAuth，改用 **IP 白名单**（更安全）。

---

## BasicAuth 到底是什么？会不会影响 Emby 登录？

* **BasicAuth** 是 **Nginx 在最外层加的一道“网关密码”**。
  你访问网关/反代地址时，必须先通过这道用户名密码，才能继续访问源站。
* **Emby 自己的账号密码** 是第二层（源站应用层登录），两者不冲突。
* 如果你的播放器/转发器不支持 BasicAuth（例如某些客户端不弹窗、不支持 URL 内嵌 `user:pass@`），那就不要开 BasicAuth，改用 **IP 白名单**。

---

## Cloudflare 小黄云能不能反代？

看你走哪条路径：

* **主域名 443/80**：Cloudflare 小黄云一般没问题（标准 Web 代理端口）。
* **高端口**：Cloudflare 只代理少数端口（例如 443/8443/2053/2083/2087/2096/8080/8880 等，具体以 Cloudflare 官方为准）。
  如果你用不在列表内的高端口，并且 DNS 记录开了橙云，很可能无法访问。
* 解决思路：

  * 高端口访问（IP:port）建议直接走 **灰云（DNS only）**；
  * 或把端口改到 Cloudflare 支持的端口；
  * 或只用域名 443 入口（推荐）。

---

## 如何确认“播放走 VPS 流量”？

最简单的方法：

1. 在 VPS 上抓连接：

   ```bash
   ss -ntp | grep nginx | head
   ```

   播放时你会看到：

   * 客户端 → VPS 的连接
   * VPS → 源站的连接

2. 看 VPS 的网卡流量（播放时明显上涨）：

   ```bash
   apt-get update && apt-get install -y vnstat
   vnstat -l
   ```

   或用 `iftop` / `nload`。

---

## 卸载/回滚

脚本菜单内提供卸载选项（删除站点配置 / 删除网关配置）。
证书不会强制删除（避免误删），如需删除可手动执行：

```bash
sudo certbot delete --cert-name <你的域名>
```

---

## 免责声明

本项目仅用于合法用途与网络加速/自用反代场景。
请勿用于任何违法用途或提供公共开放代理服务，否则可能导致封禁或法律风险。


