# 流式与部署扩展

日期：2026-10-22；目标版本 0.2.0（源码，未发布）。0.1.0 已发布，原有缓冲式 API 保持兼容。

## 评审反馈与对应修改

此前文档明确排除了流式应用接口、Unix socket、继承 fd0 及 Authorizer/Filter。此次是实质功能扩展，不是把不支持列表删掉。

- `stream.mbt`：独立流式会话状态机，PARAMS 结束即交付 RequestHead，逐块 STDIN/DATA，支持请求中止、管理查询、角色白名单、输入长度校验和顺序复用。
- `server/streaming.mbt`：StreamHandler、BodyStream、ResponseWriter，真实双向 TCP，4-record 输入队列背压，逐 record 响应/stderr，超时、取消、提前返回后的输入排空与资源清理。
- `server/posix.{mbt,c}`：POSIX 文件系统 Unix socket 和继承 TCP/Unix listener。默认 0600，不覆盖已有路径，退出时仅删除仍属于本实例的 socket。继承接口复制描述符，调用方保留原 fd；共享非阻塞标志的副作用已明确。
- Authorizer：PARAMS 结束即运行，无 STDIN；通过状态和 Variable-* 头表达授权。
- Filter：先 STDIN 后 DATA，独立字节流，分别检查 CONTENT_LENGTH 与 FCGI_DATA_LENGTH；STDIN 未结束不能输出。

## 可复现命令

```powershell
# Windows, repository root
. ./tools/Use-LocalToolchain.ps1
moon info
moon fmt --check
moon check --target native --deny-warn
moon build --target native
moon test --target native
node tools/integration.mjs
node tools/stream-integration.mjs
node tools/consumer.mjs
```

```sh
# Linux, with compatible MoonBit, Node.js, Go 1.23.2, nginx, cc and libfcgi-dev
moon update
moon info
moon fmt --check
moon check --target native
moon build --target native
moon test --target native
mkdir -p ../work
go build -o ../work/go-ref tools/reference/main.go
GO_REFERENCE_BIN="$PWD/../work/go-ref" NGINX_BIN="$(command -v nginx)" node tools/integration.mjs
cc -Wall -Wextra -Werror tools/reference/libfcgi.c -lfcgi -o ../work/libfcgi-ref
dpkg-query -W libfcgi-dev
NGINX_BIN="$(command -v nginx)" LIBFCGI_REFERENCE_BIN="$PWD/../work/libfcgi-ref" node tools/stream-integration.mjs
node tools/consumer.mjs
```

## 当前验证证据

Windows native：26 项核心测试、13 组既有 TCP/Go/Nginx 联调、11 组新增真实流式/角色/Nginx 联调通过。0.2.0 实际打包归档的独立消费者测试通过，隔离目录为 C:\Users\Lenovo\AppData\Local\Temp\moonfcgi-consumer-Sf0yQ0；测试同时编译新增流式 API。

新增驱动证实：STDIN 未终止时已收到响应头及二进制回显；9 MiB 上传；ABORT 后同 ID 复用；提前响应后排空；Authorizer 允许/拒绝；Filter DATA；异常前后不同完成行为；非法长度和流序列拒绝；背压中的超时；4 MiB Nginx 下载。真实 Nginx 测试让客户端只发送一半 HTTP 正文，收到回显后才发送余下一半，排除仅在请求结束后一次性输出的假流式实现。

本机 WSL 未安装，Docker 不可用，因此新增 Unix/fd0 以及系统 libfcgi 的 Linux 运行结果尚无本机证据。CI 已增加真实 Unix、fd0 和 libfcgi 对照步骤；只有实际 CI 通过后才能将本节升级为已验证。旧版 Linux CI 通过不能证明新增代码通过。

## 设计边界

单连接一个活动请求，不做多路复用。每个输入流的队列容量为 4，阻塞时不会继续无限读取；后续控制消息的读取也可能被背压推迟，处理/周期期限负责最终取消。总正文、DATA 和响应字节仍受 Limits 限制，应用自行保留块不受库约束。

逐块写返回不代表 HTTP 客户端已经收到；Nginx、内核或网络可能缓冲。响应提交后不能回滚状态，应用异常以非零 appStatus 结束；传输写错误或不完整的声明响应关闭连接。Filter 前置 STDIN 未完成时提前返回会使连接失败，不伪造成功响应。正文未被应用消费而提前响应时，协议层继续校验并排空，之后才允许下一请求。

POSIX accept 因官方 async 0.20.0 公共 API 限制使用 5 ms 非阻塞轮询；连接数据 I/O 采用官方 raw_fd。未声称零拷贝、常数总内存、所有平台或生产安全审计完成。Unix socket 不实现 Linux abstract namespace。进程管理器、TLS、multipart 和 fd0 的 CGI 自动降级不在此扩展范围。

## 参考范围

FastCGI 1.0 文档（1996-04-29），重点为第 2、5、6 节。libfcgi 公共接口 FCGX_GetStr、FCGX_PutStr、FCGX_FFlush、FCGX_StartFilterData、FCGX_InitRequest 用于理解流和继承监听模式。

固定复查源码入口：FastCGI-Archives/fcgi2 commit `47f2c03b7771f0ef61d887734ef91e6fa747f837`。项目未移植或链接 libfcgi 到 MoonBit 库，独立 C 参考程序仅在联调时链接系统 libfcgi，系统包版本由 CI 实际记录。协议判断以规范为准，不把 libfcgi 某个历史行为视为规范全文。
