# 服务生命周期、诊断与资源配置

本节描述 0.2.0 源码中的新增接口，已发布 0.1.0 不包含这些接口。

## 优雅停机

```moonbit
let control = @server.Control::new()
let stats = @server.Stats::new()
let config = @server.Config::new(
  control~, stats~,
  shutdown_timeout_ms=10000,
  idle_timeout_ms=30000,
  input_timeout_ms=60000,
  handler_timeout_ms=60000,
  write_timeout_ms=10000,
  cycle_timeout_ms=120000,
  input_queue_records=4,
  on_event=event => {
    // Send to your logger or collector; callback must be synchronous and nonblocking.
    ignore(event)
  },
)
```

将 config 传给 serve、serve_stream、serve_unix 或 serve_inherited；应用的另一任务调用 `control.shutdown()`。该调用同步发出停止通知，不等待排空；阻塞的 serve 函数在监听器和子连接完成清理后返回。默认每个配置有独立的 Control/Stats，也可显式共享给多个监听器。

收到停止通知后：取消 accept 并关闭本实例的监听句柄；空闲连接关闭；已有 handler 可以继续写完响应；不再启动新请求；超过 shutdown_timeout_ms 的在途任务取消并清理连接。显式的同一 Control 重复 shutdown 是幂等的。停止后的 token 不可重置，重新启动请创建新 Control 或新 Config。

serve_inherited 只关闭本实例复制的 fd，原始监听描述符和 Unix 路径由调用方拥有，因此父进程仍可能接受连接；库保证自己不再 accept，不声称移除了父进程的监听端口。serve_unix 自建路径按原有 inode/device 规则清理。

外层任务取消和进程默认 SIGTERM 处理仍是立即取消；本功能没有替换进程全局信号处理器。应用如需收到特定信号后优雅排空，应由应用的生命周期入口先调用 Control.shutdown，再等待 serve 返回。取消是协作式，CPU 密集 handler 必须让出执行权；截止时间不能强制抢占不让出的代码，也不能执行 SIGKILL 后的清理。

## 期限与背压

| 配置 | 默认 | 语义 |
|---|---|---|
| idle_timeout_ms | 等于 cycle_timeout_ms | 连接空闲期限 |
| input_timeout_ms | 等于 cycle_timeout_ms | 空闲后开始收到输入时启动的总输入期限，持续发送字节不刷新 |
| handler_timeout_ms | 10000 ms | handler 调用的总期限，包括其等待输入和输出的时间 |
| write_timeout_ms | 10000 ms | 缓冲 API 为整批响应；流式 API 为每个 record 的 socket 写操作 |
| cycle_timeout_ms | 30000 ms | 原有总周期保护，完成/中止后刷新；提前响应尚未排空输入不刷新 |
| shutdown_timeout_ms | 10000 ms | 停止通知后允许在途响应完成的宽限期 |
| input_queue_records | 4 | 每个 STDIN/DATA 队列可等待的 record 数，允许 1..1024 |

所有期限必须为正数。流式 STDIN/DATA 队列满时阻塞生产者，而非丢弃正文；每个 record 最多 65535 字节。队列上限是每流的排队上限，不是进程总内存限额。PARAMS、总正文、DATA、输出和连接数仍受 Limits 约束。

Responder 在 STDIN 结束时关闭输入计时；Filter 在 DATA 结束时关闭；Authorizer 在 PARAMS 结束后不等待 STDIN。输入和 handler 可以并行，因此多个预算也可能同时计时，以先到者为准。输入队列背压会推迟读取后续 ABORT；输入、handler 及总周期期限仍可中止任务。应用保留的 Bytes 不受队列容量控制。

## 事件与错误

Config.on_event 提供 ConnectionOpened、RequestStarted、RequestFinished、ConnectionError、ConnectionClosed。RequestFinished 包含连接 ID、请求 ID、Outcome、耗时与输入/输出 record 内容字节数。没有默认输出请求正文、参数或凭据。

ServerError 分类为 Protocol、Transport、Handler、Deadline(Stage)。Stage 包括 Idle、Input、Handler、Write、Cycle、Shutdown。应用可以按类型匹配，不必解析错误字符串。普通 handler 错误及 handler 超时仍按既有规则在响应提交前回退 500；已提交后不能回滚 HTTP 状态。连接入口对外传播结构化 ServerError；此前按核心 ProtocolError 匹配连接异常的调用者应迁移到 ServerError::Protocol，纯协议核心仍使用 ProtocolError。

回调抛出的错误仅增加 observer_errors，不影响 handler、协议写出或清理；不会再发出“回调失败事件”引发递归。回调不应阻塞、执行长计算或直接修改服务器状态之外的未同步共享资源。错误详情可能来自应用自身的错误文本，日志脱敏由应用决定。

## 统计口径

`config.stats.snapshot()` 返回只读值快照。统计针对一个协作式 async 事件循环，不宣称跨操作系统线程安全。可追踪累计/活动连接、请求、Completed/Failed/Aborted/Cancelled、读写字节、各类错误、超时及观察者错误。

- 全局 bytes_read/bytes_written 为成功读写操作的 FastCGI wire 字节数，包含管理消息、header 与 padding；一次失败写操作可能已部分写入，此未知部分不计入。
- 请求报告的 input_content_bytes/output_content_bytes 为该请求处理期间已观察到的 record 内容字节，不包含 FastCGI header/padding；输出包括 CGI 响应头。不是应用正文长度或网络带宽测量。
- RequestFinished 在响应写完、ABORT 处理或失败/取消清理时至多发出一次。提前响应后排空的额外输入只计入全局 wire 读量，不回改已经交付的报告。
- handler 自行选择返回 500 并不自动成为 handler 异常；Outcome 反映处理生命周期而非 HTTP 业务成功率。

## 验证

```powershell
. ./tools/Use-LocalToolchain.ps1
moon info
moon fmt --check
moon check --target native --deny-warn
moon build --target native
moon test --target native
node tools/lifecycle-integration.mjs
node tools/integration.mjs
node tools/stream-integration.mjs
node tools/consumer.mjs
```

cmd/lifecycle 是带短期限、故障路由与停机路由的联调 fixture，不是生产应用模板。独立 Node 驱动通过真实 FastCGI 管理回复确认请求已经开始，避免用 stdout 缓冲状态或固定延迟冒充同步。

当前 Windows 本地：28 项单元测试、10 组生命周期、13 组原有 TCP/Go/Nginx、11 组流式联调及独立消费者通过。

Linux 实测：[CI 39723922437](https://github.com/Ryan-1125/moonfcgi/actions/runs/39723922437)，提交 `67dbc3903c933e286da18a1cfa876a6a34aba29a`。Ubuntu 24.04、moon 0.1.20261020、moonc v0.10.16+b1a0e846e、Go 1.23.2、Nginx 1.24.0、libfcgi-dev 2.4.2-2.1ubuntu0.24.04.1。28 项单元测试、12 组生命周期、13 组原有联调、16 组流式/角色/POSIX/libfcgi 联调、1 项独立归档消费者全部通过。POSIX 额外验证自建 Unix 路径在排空后清理，以及继承 TCP/Unix listener 的优雅停机和调用方路径所有权。

首次 Linux CI 39723657162 在生命周期第二个实例遇到固定端口的 TIME_WAIT；没有跳过断言或降低期限，驱动改为每实例申请独立空闲端口后全量复验通过。Windows 慢读测试还曾发现将取消误包装为 Transport 的分类错误，已通过保留取消类型修正，现报告 Deadline(Write)。失败记录保留。
