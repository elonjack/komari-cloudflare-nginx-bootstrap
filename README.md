# Komari + Cloudflare + Nginx 安全反向代理脚本

适用于已用 Docker 运行 Komari 面板的 **Debian 13** 服务器。

脚本会把原先 Docker 的公网端口映射，收紧为仅本机可访问的 `127.0.0.1:25774:25774`；外部访问统一经由 Cloudflare 与 Nginx 的 HTTPS `443` 端口。

## 脚本会做什么

- 校验 Cloudflare 源证书与私钥是否匹配。
- 安装并启用 Nginx，配置 Komari 所需的 HTTPS 与 WebSocket 反向代理。
- 只为 Komari 配置 HTTPS `443`；不创建 Komari 的 HTTP `80` 入口。
- 保留原 Komari 数据目录，不拉取新镜像，也不删除数据。
- 停止并重命名旧 Komari 容器，保留为可回滚备份。
- 可选启用 Debian 无人值守**安全更新**，包含 Nginx 安全补丁。
- 在完成前校验 Nginx 配置，最多等待约 60 秒检查本机 Komari 是否完成初始化；若新容器未就绪，会自动恢复旧容器。

## 脚本不会做什么

- 不会显示、上传或提交任何证书私钥。
- 不会打开防火墙端口、关闭防火墙或修改 SSH 设置。
- 不会删除原 Komari 数据或直接删除旧容器。
- 不会自动在 Cloudflare 创建 DNS 记录或证书。

## 开始前准备

### 1. 配置 Cloudflare DNS

在 Cloudflare DNS 中创建 Komari 使用的子域名：

- 类型：`A`
- 内容：VPS 公网 IP
- 代理状态：**已代理**（橙色小黄云）

### 2. 创建 Cloudflare 源证书

进入 **SSL/TLS → 源服务器 → 创建证书**，选择“Cloudflare 生成私钥和 CSR”。

证书主机名填写你的 Komari 子域名；也可以使用匹配的单级通配符证书，例如 `*.example.com` 可以覆盖 `komari.example.com`。

创建后页面会显示两段内容：**源证书**和**私钥**。私钥只显示一次，务必立即保存；不要截图、发送给他人或提交到 Git 仓库。

### 3. 在 VPS 保存证书与私钥

在 SSH 终端以 root 执行：

```bash
install -d -m 0700 /root/komari-origin
nano /root/komari-origin/origin.pem
```

把 Cloudflare 的“源证书”完整粘贴进去，包含：

```text
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
```

保存与退出 Nano：按 `Ctrl+O`（字母 O）→ 按 `Enter` 确认文件名 → 按 `Ctrl+X` 退出。

接着保存私钥：

```bash
nano /root/komari-origin/origin.key
```

粘贴 Cloudflare 的“私钥”完整内容。它通常从 `-----BEGIN PRIVATE KEY-----` 开始，到 `-----END PRIVATE KEY-----` 结束。再次按 `Ctrl+O` → `Enter` → `Ctrl+X` 保存退出。

最后限制私钥权限并确认两个文件存在：

```bash
chmod 600 /root/komari-origin/origin.key
ls -l /root/komari-origin
```

正常会看到 `origin.pem` 和 `origin.key`；不要输出或分享文件内容。

### 4. 放行必要端口

在 VPS 服务商安全组与主机防火墙中，仅保留：

- 你当前使用的 SSH 端口。
- TCP `443`。

不要为 Komari 开放 TCP `80`、容器内部端口或旧公网端口。请先保留当前 SSH 会话，等 HTTPS 域名验证成功后，再从云安全组/防火墙中移除旧端口。

## 一键执行

### 短命令（推荐）

如果你已按本文前面的步骤，把源证书和私钥保存为 `/root/komari-origin/origin.pem`、`/root/komari-origin/origin.key`，可在 root SSH 终端原样复制这一整行：

```bash
mkdir -p /root/komari-bootstrap && curl --proto '=https' --tlsv1.2 -fLo /root/komari-bootstrap/komari-cloudflare-nginx.sh https://raw.githubusercontent.com/elonjack/komari-cloudflare-nginx-bootstrap/main/komari-cloudflare-nginx.sh && bash /root/komari-bootstrap/komari-cloudflare-nginx.sh
```

它会下载脚本到本机后再运行（不会直接把网络内容管道交给 `bash`），并交互询问域名和是否开启 Debian 安全更新。下载后的脚本保留在 `/root/komari-bootstrap/`，可先用 `less /root/komari-bootstrap/komari-cloudflare-nginx.sh` 查看内容。

### 完整、可审计写法

以下命令可以**原样复制**到 VPS 的 root SSH 终端：

```bash
mkdir -p /root/komari-bootstrap
cd /root/komari-bootstrap
curl --proto '=https' --tlsv1.2 -fLO https://raw.githubusercontent.com/elonjack/komari-cloudflare-nginx-bootstrap/main/komari-cloudflare-nginx.sh
chmod 700 komari-cloudflare-nginx.sh

./komari-cloudflare-nginx.sh \
  --cert-file /root/komari-origin/origin.pem \
  --key-file /root/komari-origin/origin.key \
  --enable-security-updates
```

脚本会问“请输入 Komari 对外域名”。这时才手动输入你在 Cloudflare 创建的子域名，然后回车。

接着会展示将要修改的内容，并询问是否继续。确认 Cloudflare 小黄云、证书文件和 TCP `443` 都已准备好后，输入 `y` 回车。

### 不想使用交互输入域名

将下面的 `komari.example.com` 替换为自己的域名后再执行；除此之外不要修改：

```bash
./komari-cloudflare-nginx.sh \
  --domain komari.example.com \
  --cert-file /root/komari-origin/origin.pem \
  --key-file /root/komari-origin/origin.key \
  --enable-security-updates
```

## 脚本完成后

在 Cloudflare 中按以下路径逐项确认：

1. **DNS → 记录**：Komari 子域名的云朵必须为橙色，即【已代理】。
2. **SSL/TLS → 概述**：加密模式必须为【完全（严格）/ Full (strict)】。
3. **SSL/TLS → 边缘证书**：向下找到【始终使用 HTTPS】卡片，打开右侧开关；开关显示绿色且带勾即为成功。

【始终使用 HTTPS】由 Cloudflare 在边缘将 `http://` 请求跳转到 `https://`。本脚本不会在 VPS 的 Nginx 中配置 HTTP→HTTPS 跳转，且不会让 Komari 监听 TCP `80`，因此两者不会造成重定向循环。开启此功能后，VPS 只需开放 TCP `443`。

注意：该开关对当前 Cloudflare 域名下的所有主机名生效；若其中还有仅支持 HTTP 的其他网站或服务，请先不要开启。

然后访问：

```text
https://你的 Komari 子域名
```

## 可选：Cloudflare AOP（进一步保护源站）

小黄云会隐藏常规 DNS 查询中的源站 IP，但本身不阻止知道源站 IP 的人直接请求 HTTPS。

Cloudflare **Authenticated Origin Pulls（AOP）** 会让 Nginx 只接受携带 Cloudflare 客户端证书的 HTTPS 请求，从而阻止绕过 Cloudflare 的直接访问。请先完成上面的基础部署，并确认 HTTPS 域名已经能正常打开后，再按以下步骤操作。

### 1. 下载 Cloudflare AOP 公共 CA 证书

在 VPS 的 root SSH 终端原样执行：

```bash
curl --proto '=https' --tlsv1.2 -fLo /root/komari-origin/cloudflare-aop-ca.pem \
  https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem

openssl x509 -in /root/komari-origin/cloudflare-aop-ca.pem -noout -subject -issuer
```

这是 Cloudflare 的**公共 CA 证书**，不是你的源证书，也不是私钥；可以保存到该路径。

### 2. 在 Cloudflare 开启全局 AOP

Cloudflare 域名后台 → **SSL/TLS → 源服务器** → 找到 **Authenticated Origin Pulls / 经过身份验证的源站拉取** 标签页 → 在 **Global / 全局** 区域打开开关。

先开启 Cloudflare 的开关是安全的：此时现有 Nginx 仍会正常响应。不要选择“上传自己的证书”或“按主机名”；小白使用 **Global / 全局** 即可。

### 3. 重新执行脚本，让 Nginx 强制验证 AOP

在 VPS 中执行以下**短命令**。它会重新下载最新脚本；运行时仍会询问你的域名，因此不要把域名写进命令：

```bash
curl --proto '=https' --tlsv1.2 -fLo /root/komari-bootstrap/komari-cloudflare-nginx.sh https://raw.githubusercontent.com/elonjack/komari-cloudflare-nginx-bootstrap/main/komari-cloudflare-nginx.sh && bash /root/komari-bootstrap/komari-cloudflare-nginx.sh --enable-aop
```

`--enable-aop` 等同于使用已下载的 `/root/komari-origin/cloudflare-aop-ca.pem`。它会继续使用默认源证书路径；自动安全更新则由脚本交互询问，不会擅自开启。

如你的证书不在默认路径，才使用下面的完整写法：

```bash
cd /root/komari-bootstrap
curl --proto '=https' --tlsv1.2 -fLO https://raw.githubusercontent.com/elonjack/komari-cloudflare-nginx-bootstrap/main/komari-cloudflare-nginx.sh
chmod 700 komari-cloudflare-nginx.sh

./komari-cloudflare-nginx.sh \
  --cert-file /root/komari-origin/origin.pem \
  --key-file /root/komari-origin/origin.key \
  --cloudflare-aop-ca-file /root/komari-origin/cloudflare-aop-ca.pem \
  --enable-security-updates
```

脚本询问域名时输入你的 Komari 子域名；在操作确认处输入 `y`。脚本会短暂重载 Nginx，并保留现有容器作为回滚备份。

### 4. 验证

先确认你的 HTTPS 域名仍能正常打开。随后在 VPS 上执行：

```bash
curl -kI --connect-timeout 5 https://你的VPS公网IP || true
```

预期是直接 IP 的 HTTPS 请求失败或被拒绝；而通过 Cloudflare 域名的 HTTPS 访问正常。若域名出现 `521` 或 `525`，先不要删除证书，执行 `nginx -t` 和 `systemctl status nginx --no-pager`，并保留当前 SSH 会话后再排查。

详细原理见 [Cloudflare Global AOP 官方教程](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/global/)。

## 安全清单

- Komari 管理员使用独立高强度密码，并开启 2FA。
- 每台 Komari Agent（探针）使用 `--disable-web-ssh`，关闭远程终端和远程命令执行。
- Cloudflare 保持小黄云，SSL 模式使用 **Full (strict)**，不要设置为 Flexible。
- HTTPS 验证成功后，从云安全组与防火墙删除旧 Komari 公网端口。
- 使用 `--enable-security-updates` 可自动安装 Debian 安全更新；它不会盲目升级所有软件包。

## 回滚

脚本会保留一个停止状态的旧容器，名称类似：

```text
komari-before-nginx-时间戳
```

将下面的 `旧容器名称` 替换为实际名称后执行：

```bash
docker stop komari
docker rm komari
docker rename 旧容器名称 komari
docker start komari
```

这会恢复原来的 Docker 端口映射，不会删除 Komari 数据目录。

## 验证命令

```bash
docker ps
ss -ltnp | grep -E ':(443|25774)\\b'
nginx -t
```

预期结果：Nginx 通过 `443` 提供服务，Docker 只监听 `127.0.0.1:25774`，没有 Docker 容器端口对公网发布。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
