# 初审反馈对应说明：0.2.0 扩展

## 反馈与修改

| 初审指出的范围 | 此次新增实现 | 当前证据 |
|---|---|---|
| 排除了流式请求与响应 | StreamSession、StreamHandler、BodyStream、ResponseWriter；PARAMS 结束即启动，逐块 STDIN/STDOUT/STDERR | 真实 TCP 在请求未结束前收到回显；9 MiB 上传；Nginx HTTP 客户端收到第一半回显后才发送第二半 |
| 排除了 Unix socket | POSIX 文件系统 Unix listener，默认 0600、已有路径保护、退出路径身份校验 | 代码及 Linux CI 用例已准备；本机无 Linux，运行结果待实际 CI |
| 排除了继承监听描述符 | serve_inherited，默认 fd0，校验并复制既有 TCP/Unix listener | Python fixture 真实创建 listener 并 exec；Linux CI 待运行 |
| 仅覆盖 Responder | Authorizer 状态/Variable-*；Filter 独立 STDIN 与 DATA；显式角色白名单 | 独立字节驱动的真实 TCP 允许/拒绝、二进制 DATA 通过；libfcgi 对照已纳入 Linux CI |

## 保留的工程边界

- 单连接一个活动请求，不做多路复用；不同连接并发。
- 输入和输出分块，不承诺应用自行保留数据的总内存；总字节上限、队列容量和超时仍生效。
- Nginx 测试是 Responder；不将其他角色的协议测试宣传为 Nginx 的所有角色部署能力。
- POSIX 原生桥接只处理系统调用；不通过 libfcgi 代理协议。官方 async 0.20.0 的公开接口限制使监听 accept 使用 5 ms 轮询，数据 I/O 仍为异步。
- 不新增进程管理、TLS、multipart、自动重连或 Web 框架。

## 复核入口

- 源码：stream.mbt、server/streaming.mbt、server/posix.mbt、server/posix.c。
- 接口：pkg.generated.mbti、server/pkg.generated.mbti。
- 示例：cmd/stream、examples/nginx-stream.conf。
- 固定向量与核心测试：stream_test.mbt 以及既有测试。
- 真实联调：tools/stream-integration.mjs；参考程序：tools/reference/libfcgi.c。
- 完整命令、版本边界和实测状态：docs/STREAMING.md。

已发布 0.1.0 与当前 0.2.0 源码范围分开说明。本文件是技术补充事实，不能代替赛事重新审核，也不能将尚未运行的 Linux CI 写成通过。

用户提供的本次驳回通知允许在 2026-10-31 前修改问卷后重新审核；以该通知及赛事最新要求为准，不沿用旧章程的 10-24 截止日期。
