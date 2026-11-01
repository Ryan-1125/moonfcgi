# Linux 部署交付

本配方面向 Ubuntu 24.04 / Debian 的 systemd 和 Nginx（worker 组 www-data），使用专用 moonfcgi 用户与文件系统 Unix socket。示例是可替换 handler 的二进制回显服务，不包含测试故障路由。

## 构建与安装

在 Linux 安装匹配 MoonBit 工具链后，在仓库根目录执行：

```sh
moon update
moon build --target native
sudo apt-get install nginx
sudo useradd --system --no-create-home --shell /usr/sbin/nologin moonfcgi
sudo install -d -m 0755 /opt/moonfcgi
sudo install -m 0755 _build/native/debug/build/cmd/service/service /opt/moonfcgi/moonfcgi-service
sudo install -m 0644 deploy/linux/moonfcgi.service /etc/systemd/system/moonfcgi.service
sudo install -m 0644 deploy/linux/nginx.conf /etc/nginx/conf.d/moonfcgi.conf
sudo systemctl daemon-reload
sudo systemctl enable --now moonfcgi
sudo nginx -t
sudo systemctl reload nginx
```

已存在用户时跳过 useradd。Nginx 的运行组如果不同，应同时修改 unit 的 Group 和目录访问权限。运行目录由 systemd 创建，owner moonfcgi、group www-data、0750；应用创建 socket 0660。不要使用 chmod 777 或覆盖已有未知 socket 路径。

## 访问与运维

```sh
curl --fail http://127.0.0.1:8080/
printf '\000\377binary\n' > /tmp/moonfcgi-body
curl --fail --data-binary @/tmp/moonfcgi-body http://127.0.0.1:8080/echo -o /tmp/moonfcgi-output
cmp /tmp/moonfcgi-body /tmp/moonfcgi-output
sudo systemctl status moonfcgi --no-pager
sudo journalctl -u moonfcgi -n 100 --no-pager
stat /run/moonfcgi/app.sock
sudo systemctl restart moonfcgi
sudo systemctl stop moonfcgi
test ! -e /run/moonfcgi/app.sock
```

监听仅绑定本机 HTTP，TLS、外部域名与认证由前端部署配置。8 MiB 请求上限与默认协议限额对应。

此示例使用 SIGTERM 停止，意味着取消在途任务；systemd 清理 RuntimeDirectory。需要在途请求排空的应用应在自身生命周期入口调用 Control.shutdown 并等待 serve 返回，再接入进程停止通知；unit 的 TimeoutStopSec 本身不会将 SIGTERM 转成排空操作。继承 fd0 的部署方式见 [部署指南](DEPLOYMENT.md)。

Linux CI 校验 unit、Nginx 配置并构建此服务；真实 Unix socket、权限和清理行为由流式集成测试覆盖。完整 systemctl 安装命令应在目标主机按本配方执行；CI runner 的校验不等同于已在用户主机部署。
