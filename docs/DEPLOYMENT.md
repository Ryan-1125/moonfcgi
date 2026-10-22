# 安装与部署

## 版本入口

仓库与 Mooncakes 模块版本为 0.2.0，提供协议核心、缓冲式与流式接口、三种角色、部署和生命周期 API。

```sh
# 当前完整接口与示例
git clone https://github.com/Ryan-1125/moonfcgi.git
cd moonfcgi
moon update
moon build --target native
moon run cmd/stream --target native -- 127.0.0.1:9000
```

```sh
# 已发布的注册表接口，在独立下游工程中执行
moon add Ryan-1125/moonfcgi@0.2.0
```

源码工作区的下游工程可通过 moon.work 将本模块与消费者列为 members，并依赖 Ryan-1125/moonfcgi@0.2.0。实际生成、编译和运行流程见 tools/consumer.mjs；该脚本先打包，再消费解包后的模块，独立于开发目录。

工具链验证版本：moon 0.1.20261020、moonc v0.10.16+b1a0e846e，依赖 async 0.20.0。已有项目专用 SDK 的 Windows 终端可执行 `. ./tools/Use-LocalToolchain.ps1`。Go、Node.js、Nginx 和 libfcgi 用于互操作测试，应用运行按自身部署依赖配置。

## Nginx / TCP

启动 cmd/stream，创建 logs 和 temp 目录；Windows 使用 `New-Item -ItemType Directory -Force logs,temp`，POSIX 使用 `mkdir -p logs temp`。

```sh
nginx -p <仓库绝对路径>/ -c examples/nginx-stream.conf
curl --data-binary @payload.bin http://127.0.0.1:8080/echo -o echoed.bin
curl http://127.0.0.1:8080/download -o download.bin
```

流式配置同时设置 fastcgi_request_buffering off 与 fastcgi_buffering off。二进制内容按字节传输；/download 按块输出 4 MiB。缓冲 JSON API 使用 cmd/main 和 examples/nginx.conf，包含 /api/hello、/api/echo、重复 cookie 与状态响应。

持久上游同时配置 upstream keepalive 和 fastcgi_keep_conn on。停止 Nginx 时使用相同 prefix/config 参数并追加 `-s quit`。

## Unix socket

在私有父目录内创建 socket：

```sh
moon run cmd/stream --target native -- unix:/run/moonfcgi/app.sock
```

Nginx upstream 指向 `server unix:/run/moonfcgi/app.sock;`。serve_unix 默认 mode 为 0600，可按部署用户/组权限显式配置；已有路径保持原状，正常退出按 inode/device 确认归属后清理。

POSIX 适配只桥接 socket、fcntl、accept 等系统调用。async 0.20.0 公共接口下，监听 accept 使用 5 ms 可取消轮询，已连接数据读写由官方 RawFdStream 异步处理。

## 继承监听

进程启动器先建立 TCP 或 Unix stream listener，随后将监听 fd 交给应用。调用 `serve_inherited(handler, fd=0, config~)`；示例可执行程序使用 `fd:0` 参数。库检查描述符类型及监听状态，复制 fd 并设置 CLOEXEC/非阻塞；原 fd 的所有权保留给调用方，共享非阻塞标志的影响由调用方纳入部署约定。

可复现的真实 exec 入口见 tools/inherited-launch.py，Linux CI 覆盖 TCP 和 Unix 两种 fd0。继承 Unix 路径由调用方清理。

## 服务生命周期

应用传入 Control，在停止入口调用 control.shutdown()，等待 serve 返回以完成排空。信号策略由应用入口管理；外层取消执行立即清理。宽限期、事件和统计接入见 [生命周期说明](LIFECYCLE.md)。

Nginx 配置验证使用 Responder；Authorizer/Filter 的角色语义由独立驱动和 libfcgi 对照覆盖。部署时根据前端服务器的角色能力选择入口。
