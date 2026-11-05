# 多个独立站点部署

每台 Ubuntu 服务器运行一个独立 new-api 站点：宿主机 Nginx 提供 HTTPS，Docker Compose 运行 new-api、PostgreSQL、Redis。站点只共用代码与镜像，不共用用户、渠道、余额、数据库、Redis 或密钥。每站应用固定使用 `master`。

仓库地址为 `lionellc/liuc-new-api`，工作流生成的镜像为 `ghcr.io/lionellc/liuc-new-api`。生产配置只放服务器，不提交到仓库。以下域名、管理员 IP、邮箱和 SSH 地址均需替换。

## 1. 安装服务器软件

推荐 Ubuntu 24.04。按 [Docker 官方 Ubuntu 安装说明](https://docs.docker.com/engine/install/ubuntu/)安装 Docker Engine 和 Compose 插件，Compose 至少为 2.30.0。已有 Docker 的服务器先核对安装，不要直接卸载。

```bash
sudo apt-get update
sudo apt-get install -y nginx certbot openssl util-linux
sudo systemctl enable --now docker nginx
sudo docker compose version
```

创建部署用户和目录；已有用户时跳过 `adduser`：

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy
sudo install -d -o deploy -g deploy -m 0700 /home/deploy/.ssh
sudo install -d -o deploy -g deploy -m 0750 /opt/liuc-new-api
```

部署用户拥有 Docker 控制权限。重新建立 SSH 会话后检查 `docker compose version` 能否以 deploy 身份执行。安全组只开放 SSH、80、443；不要开放 3000、5432、6379。此处默认 Nginx 直接接收公网请求；若前面还有 CDN，需另行配置真实 IP 信任链。

## 2. 配置本站 SSH 密钥

本地为每站生成独立密钥：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/liuc-new-api-site-a -C github-actions-site-a -N ""
```

通过现有管理员账号，将 `.pub` 文件内容安装到本站 `/home/deploy/.ssh/authorized_keys`，设置 deploy 所有、权限 600。目录权限 700。然后从本地验证：

```bash
ssh -i ~/.ssh/liuc-new-api-site-a deploy@node-a.example.com 'docker compose version'
```

用 `ssh-keyscan -p 22 node-a.example.com` 收集公钥。通过服务器控制台执行 `sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 核对指纹，再用于 GitHub Secret。自定义 SSH 端口需在采集、验证、上传和站点清单中一致使用。

## 3. 上传部署文件，生成本站配置

在本地项目根目录执行：

```bash
scp -i ~/.ssh/liuc-new-api-site-a -r deploy/. deploy@node-a.example.com:/opt/liuc-new-api/
```

以 deploy 用户登录本站，在服务器执行：

```bash
cd /opt/liuc-new-api
bash init-site.sh site-a https://api-a.example.com
chmod 750 init-site.sh deploy.sh
```

初始化器自动生成四个独立随机值：数据库密码、Redis 密码、SESSION_SECRET、CRYPTO_SECRET，并设置配置文件权限 600。发现已有配置时会拒绝覆盖。服务器 B 使用 `site-b` 和自己的域名重复执行。

首次发布前检查：

```bash
ip route
docker network ls
```

确认 `node.env` 中的 `172.29.250.0/24` 不与已有网络冲突。若修改子网与网关，同步修改 `app.env` 的 `TRUSTED_PROXIES`。本机 Nginx 经 Docker 发布端口连接时通常表现为网关地址；上线后需验证审计记录中的客户端 IP，按实际来源配置。

保管 `node.env` 和 `app.env`，已有站点不要重新生成密码和密钥。`app.env` 的可信 Origin 必须与实际浏览器 HTTPS 入口一致。初始化不创建 `release.env`，首次部署自动创建。

该目录及 Compose project name 默认在每台服务器只使用一套。如需同机多站，必须分别调整项目名、应用端口、部署路径、网络及工作流。

## 4. 配置 Nginx 和 HTTPS

先把域名 A/AAAA 解析到本站服务器，确认 80、443 可达。以有 sudo 权限的管理员操作：

```bash
sudo mkdir -p /var/www/letsencrypt
sudo sed 's/api.example.com/api-a.example.com/g' \
  /opt/liuc-new-api/nginx/bootstrap.conf.example \
  | sudo tee /etc/nginx/conf.d/liuc-new-api.conf > /dev/null
sudo nginx -t
sudo systemctl reload nginx
sudo certbot certonly --webroot -w /var/www/letsencrypt \
  -d api-a.example.com --email YOUR_EMAIL@example.com \
  --agree-tos --non-interactive
```

替换下面的 `198.51.100.50` 为你的管理员公网 IP。模板在初始化期间只允许这个来源访问应用：

```bash
sudo sed \
  -e 's/api.example.com/api-a.example.com/g' \
  -e 's/198.51.100.50/你的管理员公网IP/g' \
  /opt/liuc-new-api/nginx/site.conf.example \
  | sudo tee /etc/nginx/conf.d/liuc-new-api.conf > /dev/null
sudo nginx -t
sudo systemctl reload nginx
```

若服务器已有此域名的 Nginx 配置，应合并配置，避免重复 server。模板的 `map` 在同一 Nginx 实例中只定义一次。

配置续期后的重载并验证续期：

```bash
sudo install -d /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx > /dev/null <<'SH'
#!/bin/sh
systemctl reload nginx
SH
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
sudo certbot renew --dry-run
systemctl list-timers --all | grep certbot
```

发布应用前出现 502 是正常的。模板已配置 SSE、WebSocket、长请求超时，并关闭 Nginx 上游重试。

## 5. 配置镜像拉取凭据

在 GitHub 创建有 `read:packages` 权限的 PAT classic，所属账号需要具备镜像包访问权限。以本站 deploy 用户执行：

```bash
docker login ghcr.io -u lionellc
```

按提示输入 Token，不要把 Token 写入命令行或提交到仓库。Actions 推送镜像使用自动提供的 GITHUB_TOKEN，不需要保存服务器读取 Token 到 GitHub Actions。

## 6. GitHub Actions 配置

在仓库 Settings → Secrets and variables → Actions 添加 Repository secrets：

| 名称 | 内容 |
| --- | --- |
| `SITE_A_SSH_KEY` | 本地 `~/.ssh/liuc-new-api-site-a` 私钥全文 |
| `SITE_B_SSH_KEY` | 站点 B 的部署私钥全文 |
| `DEPLOY_KNOWN_HOSTS` | 所有站点已核验的 SSH 主机公钥内容 |

添加 Repository variables：

| 名称 | 内容 |
| --- | --- |
| `DEPLOY_TARGETS` | 按 `targets.example.json` 填写实际站点 JSON 数组 |
| `DEPLOY_ENABLED` | 准备完服务器后设置为字符串 `true`；未设置时只检查并构建镜像 |

`host` 必须是 Runner 能 SSH 访问的地址。支持主机名和 IPv4；仅 IPv6 的主机使用域名。`name` 必须唯一，`all` 保留用于发布全部站点。每项显式填写端口，`ssh_key_secret` 对应本站私钥 Secret 名称。

当前 origin 为自己的仓库，upstream 保留 QuantumNous/new-api。禁用自己仓库里暂不用的上游 Docker Hub、Release、Electron、GitCode 发布工作流，保留 CI 和 Liuc Build and Deploy。首次不要推送上游全部标签。

## 7. 提交与首次发布

本地检查变更并提交：

```bash
git add deploy .github/workflows/ci.yml .github/workflows/liuc-deploy.yml .gitignore .dockerignore
git diff --cached
git commit -m "ci: add independent multi-site deployment"
git push origin main
```

未启用部署时，流程先检查代码、构建 AMD64/ARM64 镜像并推送 GHCR。镜像标签为提交 SHA，应用版本显示为 `liuc-<提交前12位>`，实际部署使用 digest。若所有服务器都是 AMD64，可移除 QEMU 步骤，将 platforms 改成 linux/amd64。

服务器准备好后设置 `DEPLOY_ENABLED=true`，进入 Actions → Liuc Build and Deploy → Run workflow，选择 main，target 填 `site-a` 先验证一个站点，再用 `all` 发布全部。之后推送 main 会自动发布全部已配置站点。

工作流对每站独立运行，失败不会取消其他站点。首次启动本站数据库、Redis，再启动应用；后续发布先备份数据库，然后只更新应用。应用更新期间存在短暂中断。健康检查失败会输出日志，保存 `release.env.failed`，不自动回滚数据库或容器。

## 8. 初始化与验收

以本站 deploy 用户检查：

```bash
cd /opt/liuc-new-api
docker compose --env-file node.env --env-file release.env -f compose.yaml ps
curl -fsS http://127.0.0.1:3000/api/status
docker compose --env-file node.env --env-file release.env -f compose.yaml logs --tail 100 new-api
```

若首次发布失败还没有 `release.env`，排查时可使用 `--env-file release.env.attempt`。失败时数据库可能已迁移，成功版本记录不等于容器实际状态，需同时检查 ps 和日志。

从管理员 IP 访问本站 HTTPS 域名，分别完成管理员初始化、设置 ServerAddress 为本站 HTTPS 地址、配置渠道和令牌。验证登录、普通调用、SSE 流式调用、需要的 WebSocket 功能和审计客户端 IP。确认外网不能访问 3000、5432、6379。

完成管理员初始化后，删除本站 Nginx 中的 `allow` 与 `deny all` 两行，然后 `sudo nginx -t && sudo systemctl reload nginx` 对外开放。

## 9. 后续维护

- 新站点：重复服务器准备和独立配置，增加私钥 Secret、known_hosts 和 DEPLOY_TARGETS 项，再手动选择该站点发布。
- 自动发布更新镜像；修改 compose.yaml、deploy.sh 或 Nginx 模板后，先将变更同步到对应服务器。不要用模板覆盖已有 node.env/app.env。
- PostgreSQL 和 Redis 镜像升级是独立维护操作，不跟随普通应用发布自动重建。
- `logs/` 是应用文件日志，另外配置轮转；容器日志已限制大小。为 `backups/` 设置保留期限，并定期复制到异机或对象存储。
- 每次发布前的数据库备份是在线一致性快照，但不会包含备份完成后的新写入，也不包含挂载目录和 Redis。`pg_restore --list` 只是格式检查，需要另做真实恢复演练。定期备份应用本地文件、密钥和业务所需 Redis 数据。
- 不执行 `docker compose down -v`，它会删除数据库与 Redis 数据卷。

查看版本：

```bash
cat release.env
cat release.env.previous
cat deployment-history.log
```

确认旧版本兼容当前数据库后，按上一版本完整摘要回滚本站：

```bash
bash deploy.sh ghcr.io/lionellc/liuc-new-api@sha256:上一版本完整摘要
```

不兼容数据库迁移需要维护窗口内恢复对应备份，不能只换旧镜像。站点之间独立回滚。升级上游时建议先在独立测试站验证，再合并 main 触发正式发布。
