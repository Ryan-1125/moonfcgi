# 规范、参考实现与依赖

## 固定来源

| 来源 | 参考范围 | 许可证 |
|---|---|---|
| [FastCGI 1.0，1996-04-29](https://fastcgi-archives.github.io/FastCGI_Specification.html) | record、参数、角色、管理消息、流终止与复用 | 规范引用 |
| [Go go1.23.2 net/http/fcgi](https://github.com/golang/go/tree/go1.23.2/src/net/http/fcgi) | child.go、fcgi.go、fcgi_test.go 的行为与测试思路；外部 Go 对照程序 | BSD-3-Clause |
| [libfcgi commit 47f2c03](https://github.com/FastCGI-Archives/fcgi2/tree/47f2c03b7771f0ef61d887734ef91e6fa747f837) | 流式、角色与继承监听行为；外部 C 对照程序 | Open Market |
| [moonbitlang/async 0.20.0](https://github.com/moonbitlang/async) | TCP、任务、取消、超时、同步与 RawFdStream | Apache-2.0 |

CGI 状态依据 [RFC 3875 §6.3.3](https://www.rfc-editor.org/rfc/rfc3875.html#section-6.3.3)。部署参考 [Nginx FastCGI 模块](https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html)。包管理遵循 [Moon 工具链文档](https://docs.moonbitlang.com/en/latest/toolchain/moon/package-manage-tour.html)。

协议、固定向量与 POSIX 桥接独立实现。Go/libfcgi 用于外部对照，不链接进入 MoonBit 库。许可文本及使用范围见 [来源说明](../THIRD_PARTY_NOTICES.md) 与 [licenses](../licenses)。

## 运行时设计依据

读取 async 0.20.0 源码与生成接口后，采用 TcpServer/Tcp、read_some/write、任务组、Task.cancel/wait、with_timeout、Timer、Mutex 和 Semaphore。任意读取分片、EOF、协议流结束分别处理。连接关闭保持单一所有者；任务取消保留类型向外传播。POSIX 使用公开 RawFdStream，监听 accept 以 5 ms 非阻塞轮询接入运行时，详见 [部署](DEPLOYMENT.md)。

## 生态调查记录

2026-10-20 的 Mooncakes registry 元数据检索覆盖 fastcgi、fcgi、fast-cgi、responder，当次范围内没有识别出完整同类实现。该记录仅反映当日索引，不代表所有源码审计或持续有效的生态空缺结论。

async 的 socket/任务是实际复用依赖；HTTP/1.1 库提供 HTTP 协议能力，与 FastCGI 分工不同；独立 socket 绑定属于传输基础。项目价值以可复用协议与真实部署互操作为依据，申报时结合当期 Mooncakes 检索核对同类项目。
