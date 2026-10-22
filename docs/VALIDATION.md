# 验证与兼容性

[Linux CI 39724214744](https://github.com/Ryan-1125/moonfcgi/actions/runs/39724214744) 对提交 `1096d76` 全量检查通过。

| 平台 | 验证结果 |
|---|---|
| Ubuntu 24.04 native | 28 项单元、13 组协议、16 组流式/角色/POSIX、12 组生命周期联调及独立归档消费者 |
| Windows x64 native | 28 项单元、13 组协议、11 组流式、10 组生命周期联调及独立归档消费者 |

Linux 使用 moon 0.1.20261020、moonc v0.10.16+b1a0e846e、async 0.20.0、Go 1.23.2、Nginx 1.24.0、libfcgi-dev 2.4.2-2.1ubuntu0.24.04.1。Windows 使用 moon 0.1.20261016、相同 moonc/async 和 Nginx 1.28.0。Unix socket 与继承监听的验收平台为 Linux。

## 覆盖范围

- 固定人工字节向量、分片不变性、padding、跨 record PARAMS、二进制正文、EOF 截断与大小限制。
- 管理查询、角色白名单、中止、请求代次隔离、KEEP_CONN、顺序复用及 CANT_MPX_CONN。
- 真实 TCP 并发、长度声明提前校验、重复头、HEAD/204/304、handler 异常和慢读写超时。
- 固定 Go 1.23.2 对照 JSON、二进制、cookie、大响应与 404 的共同语义。
- 真实 Nginx GET/POST、错误状态、计数验证上游复用和关闭双向缓冲后的流式交换。
- 9 MiB 上传、4 MiB 下载、三角色、Unix 权限与清理、TCP/Unix fd0 和外部 libfcgi 对照。
- 在途响应排空、停机期限、观察者异常隔离、统计归零、队列背压与分阶段超时。
- 实际 moon package 归档在独立工作区编译并运行核心 API，编译服务端接口。

对照检查协议语义，Date 头与 record 分段不要求完全相同。固定向量独立于本库 encoder。

## 复现命令

Windows 使用仓库私有 SDK 时先执行 `. ./tools/Use-LocalToolchain.ps1`。

```sh
moon update
moon info
moon fmt --check
moon check --target native --deny-warn
moon build --target native
moon test --target native
```

Linux 安装 Node.js 22、Go 1.23.2、Nginx、C 编译器和 libfcgi-dev 后执行：

```sh
mkdir -p ../work
go build -o ../work/go-ref tools/reference/main.go
GO_REFERENCE_BIN="$PWD/../work/go-ref" NGINX_BIN="$(command -v nginx)" node tools/integration.mjs
node tools/consumer.mjs
node tools/lifecycle-integration.mjs
cc -Wall -Wextra -Werror tools/reference/libfcgi.c -lfcgi -o ../work/libfcgi-ref
NGINX_BIN="$(command -v nginx)" LIBFCGI_REFERENCE_BIN="$PWD/../work/libfcgi-ref" node tools/stream-integration.mjs
```

Windows 设置对应 .exe 的 GO_REFERENCE_BIN、NGINX_BIN 后运行 Node 入口。脚本使用真实进程与连接并清理本轮子进程。完整流程见 [CI](../.github/workflows/ci.yml)。独立消费对象为实际包归档；注册表分发版本见 [README](../README.md)。
