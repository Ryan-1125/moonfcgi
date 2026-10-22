# MoonFCGI

[![CI](https://github.com/Ryan-1125/moonfcgi/actions/workflows/ci.yml/badge.svg)](https://github.com/Ryan-1125/moonfcgi/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

MoonFCGI 是 MoonBit 原生 FastCGI 1.0 协议库和 Responder 服务端库，让 MoonBit 程序通过 TCP 接入 Nginx 等 FastCGI 前端。v0.1.0 已发布至 [Mooncakes](https://mooncakes.io/docs/Ryan-1125/moonfcgi@0.1.0)。

**版本说明：**Mooncakes 的 `0.1.0` 是原有缓冲式 Responder；本仓库 `0.2.0` 源码增加流式 API、Authorizer/Filter 与 POSIX 部署接口。以下新增 API 请从本仓库构建使用，不要将其与已发布的 `0.1.0` 混淆。

协议核心独立于 socket；服务端基于 `moonbitlang/async 0.20.0`，负责多连接并发、请求生命周期、超时和资源清理。应用通过 `Request`、`Response` 和异步 `Handler` 处理请求，Nginx 负责对外 HTTP 接入。

- **协议处理：**增量 record 与 PARAMS 解码，支持跨边界长度前缀、二进制内容及 padding。
- **连接管理：**Responder、管理查询、请求中止、KEEP_CONN 和顺序连接复用；每连接一个活动请求。
- **应用接口：**保留缓冲式接口；新增有界队列的请求流、按块写出的响应与 stderr，以及 Authorizer/Filter 角色。
- **部署方式：**TCP、POSIX 文件系统 Unix socket、继承 TCP/Unix 监听描述符（默认 fd0）；POSIX 运行验证状态单独记录。
- **真实互操作：**外部协议驱动、Go 标准库参考服务和 Nginx 集成测试，覆盖 GET、二进制 POST、错误状态及上游连接复用。

适用于将 MoonBit JSON API 部署在 Nginx 后方、处理二进制请求，或在自定义运行环境中复用 FastCGI 协议核心。它是协议与服务端基础库，应用自行选择路由和业务逻辑。

## 安装

安装已发布的缓冲式 `0.1.0`，在独立 MoonBit 项目中运行：

```sh
moon update
moon add Ryan-1125/moonfcgi@0.1.0
```

根包为 `Ryan-1125/moonfcgi`，TCP 服务端包为 `Ryan-1125/moonfcgi/server`。服务端使用 native 后端。安装命令用于下游项目，不要在 MoonFCGI 自身目录添加自身依赖。

## 运行仓库示例

```sh
git clone https://github.com/Ryan-1125/moonfcgi.git
cd moonfcgi
moon update
```

## 快速运行

使用兼容的 MoonBit SDK。Windows 本地已有项目专用 SDK 时，可先在 PowerShell 执行 `. ./tools/Use-LocalToolchain.ps1`；其他机器直接使用已安装的兼容 SDK。Nginx、Go 和 Node.js 仅用于示例或集成验证，不由本库管理。

当前代码使用 moon 0.1.20261016 / moonc v0.10.16+b1a0e846e（含 Int32 新语法），旧版 0.10.14 不能检查当前源码。本轮已验证 Windows x64 native（Nginx 1.28.0），Go 参考版本固定 1.23.2。0.2.0 也已在 Ubuntu 24.04（Nginx 1.24.0、libfcgi 2.4.2-2.1ubuntu0.24.04.1）的 [Linux CI](https://github.com/Ryan-1125/moonfcgi/actions/runs/39717428442) 通过，包含真实 Unix socket、继承 TCP/Unix fd0、路径清理及三个角色的 libfcgi 对照。

```sh
moon check --target native
moon build --target native
moon test --target native
moon run cmd/main --target native -- 127.0.0.1:9000
```

运行 Nginx：先在项目根目录创建 `logs` 和 `temp` 目录（PowerShell：`New-Item -ItemType Directory -Force logs,temp`；Linux：`mkdir -p logs temp`），再执行 `nginx -p <本项目绝对路径>/ -c examples/nginx.conf`；示例监听 `127.0.0.1:8080`。Nginx 自行安装，库不包含或管理 Nginx 进程。停止：用相同 `-p` / `-c` 参数追加 `-s quit`。

```sh
curl 'http://127.0.0.1:8080/api/hello?name=MoonBit'
# {"message":"hello","query":"name=MoonBit"}，字段顺序不作保证
curl --data-binary @payload.bin http://127.0.0.1:8080/api/echo -o echoed.bin
curl -i http://127.0.0.1:8080/missing
```

`payload.bin` 可以包含零字节和非 UTF-8 字节，返回正文逐字节一致。`/api/error` 返回 500；`/api/cookies` 保留两个 Set-Cookie；`/api/large` 返回 200000 字节。示例仅用于协议联调。

## 可复用 API

根包 `Ryan-1125/moonfcgi` 无 socket 依赖；`Ryan-1125/moonfcgi/server` 仅支持 native。

```moonbit
// moon.pkg: import { "Ryan-1125/moonfcgi" @fcgi }
fn decode_fragmented() -> Unit raise {
  let decoder = @fcgi.Decoder::new()
  ignore(decoder.feed(b"\x01\x05\x00"))
  let records = decoder.feed(b"\x01\x00\x00\x00\x00")
  assert_eq(records[0].content, b"")
  decoder.finish()
}
```

应用可将下列入口放入独立 native 可执行包，`moon.pkg` 需导入根包别名 `fcgi` 及 `/server` 别名 `server`，并声明 `pkgtype(kind: "executable")`：

```moonbit
async fn main {
  let handler : @server.Handler = request => {
    @fcgi.Response::new(request.body, headers=[("Content-Type", "application/octet-stream")])
  }
  @server.serve("127.0.0.1:9000", handler)
}
```

包配置参见 [示例 moon.pkg](cmd/main/moon.pkg)，完整应用参见 [cmd/main](cmd/main/demo.mbt)。公开签名见 [核心 API](pkg.generated.mbti) 和 [服务端 API](server/pkg.generated.mbti)。`node tools/consumer.mjs` 对实际打包内容进行隔离消费验证：解包后在独立 workspace 中编译并运行消费者，与开发目录分离。

| API | 契约 |
|---|---|
| `Decoder.feed/finish` | 增量 record 解码，每次 feed 最多 65536 字节；固定约 66 KiB 暂存；EOF 检查截断；错误后不可复用 |
| `encode_record / stream_records` | 8 字节 header、合法 padding、65535 字节分片、显式空记录结束流；输入是 bytes |
| `ParamsDecoder.feed/finish` | 真正逐字节解析，长度前缀/名字/值可跨任意边界；总大小和数量有界；保留重复及非 UTF-8 参数 |
| `Session.accept` | 接受完整 record，依次产生 Send / Ready / Aborted / Close；不操作 socket |
| `Session.complete` | 绑定所属会话及请求代次；跨会话和中止后的旧结果忽略；先验证全部输出再完成会话 |
| `Request.param/text_param` | 原始 bytes；显式严格 UTF-8 转换可抛错；重复键取最后一项，完整列表仍保留 |
| `Response.new/cgi_bytes` | 有界缓冲正文；状态 200..599；有序重复头；生成 CGI Status 头、长度及输出流结束标记 |
| `server.Handler/serve` | async 函数接口，多连接并发；每连接一个活动请求，拥有 listener 和所有已接收 socket |
| `server.serve_connection` | 接管 socket，所有退出路径负责关闭；不可再交给自动关闭 socket 的回调包装器 |

## 支持边界与资源

CONTENT_LENGTH 在 PARAMS 终止时校验：非法十进制、超过正文上限、相互冲突的重复值立即关闭连接，无需等到 STDIN 结束。正文逐 record 检查声明长度，少于声明值则在流终止时拒绝；相同数值的重复长度允许，空值按未提供长度处理。

原有 `Session` / `serve` 缓冲式接口支持 Responder、GET_VALUES、UNKNOWN_TYPE 管理回复、ABORT_REQUEST、KEEP_CONN、顺序连接复用及已完成请求 ID 复用。`FCGI_MPXS_CONNS=0`；同连接第二个并发 BEGIN 收到 `FCGI_CANT_MPX_CONN`，不影响原请求。非 Responder 收到 `FCGI_UNKNOWN_ROLE`。管理请求 ID 必须为 0，应用请求 ID 为 1..65535；无活动匹配的记录忽略，活动请求内非法序列关闭连接。重复 BEGIN 同 ID 视为协议错误。未知管理类型返回 UNKNOWN_TYPE，活动请求中未知应用类型关闭连接。

`Limits.new` 默认：请求正文 8 MiB、PARAMS 256 KiB / 1024 对、响应正文与 stderr **各** 8 MiB、并发连接 64。响应头固定最多 128 项、UTF-8 序列化合计 32 KiB，单个名字最多 1024 字符、值最多 16384 字符。缓冲式 API 的正文与响应全量缓冲，输出切 record 后写入。流式 API 按块消费和输出，仍执行总字节上限；应用保留的块及自行分配的内存不受库限制。

`Config.new` 默认 cycle 30000 ms（包含空闲、输入、handler、写出，总周期完成或中止后重置）、handler 10000 ms、整批写出 10000 ms。超时为总期限，持续滴字节不会重置。达到连接上限后暂停 accept，由系统 backlog 排队。取消是协作式，CPU 密集 handler 必须让出执行权；不可阻塞事件循环。调用方取消 serve 会关闭 listener 并取消子任务。

请求尺寸超限、非法参数/序列、record 截断、读写失败及周期超时关闭连接；不尝试在损坏的协议状态中生成 HTTP 错误页。handler 普通异常或处理超时返回 500；响应越限或非法响应头回退为空 500。ABORT 取消 handler 并输出一次 END_REQUEST；旧任务结果不可污染下一请求。输出采用互斥串行写，一旦已开始写完响应，之后到达的 ABORT 不会撤回已发送字节。每次正常响应生成 STDOUT/STDERR 的空终止记录和 END_REQUEST。

CGI 头不包含 HTTP 状态行；库禁止自定义 Status / Content-Length / Transfer-Encoding / Connection，防止 CR/LF 和控制字符注入。HEAD 无正文，204/304 无正文和 Content-Length。不实现 1xx、trailers、单连接多路复用、进程管理、multipart、TLS、自动重连或 Web 框架。流式、Unix socket、继承监听和其他角色使用下面的新增 API。TCP EOF 在请求完成之前视为断开，**不支持以 TCP 半关闭代替 STDIN 终止**。

## 流式 API 与部署扩展（0.2.0 源码）

`StreamSession` 是独立于 I/O 的状态机，在 PARAMS 终止时产生 `Start(RequestHead)`，随后逐块产生 STDIN/DATA 事件，不在协议层聚合完整正文。`serve_stream` 将它接到真实 TCP；原有 `serve` 和 `Handler` 保持兼容。

```moonbit
async fn main {
  let handler : @server.StreamHandler = (request, response) => {
    response.start(headers=[("Content-Type", "application/octet-stream")])
    while request.body.read() is Some(chunk) {
      response.write(chunk)
    }
  }
  @server.serve_stream("127.0.0.1:9000", handler)
}
```

包导入与 native 配置见 [流式可执行示例](cmd/stream/moon.pkg)。`BodyStream.read()` 在 FastCGI 空终止记录处返回 `None`；socket EOF、协议截断和取消属于错误，不冒充正常流结束。`response.start(content_length=...)` 可声明已知长度；省略时不生成 Content-Length。`write` 直接等待 socket 写出，`write_stderr` 使用独立 stderr 流。库在 handler 返回后发送两个流终止记录和一次 END_REQUEST。

输入采用每流最多 4 个 record 的阻塞队列（每个 record 最多 65535 字节），输出逐 record 写入，形成有界背压；这不是进程总内存承诺。输入队列阻塞期间后续 ABORT 也会等待读取进度，周期/handler 超时提供最终取消界限。响应头提交前的 handler 错误回退 500；提交后不能改写状态，已输出部分保留并以非零 appStatus 结束。写失败或声明长度不符会关闭连接。

| 入口 | 用途 |
|---|---|
| `serve_stream` / `serve_stream_connection` | TCP 流式服务 / 接管已连接 TCP socket |
| `serve_stream_io` | 在调用方拥有的 Reader/Writer 上运行协议，不替调用方关闭传输 |
| `serve_raw_connection` | 接管官方 `RawFdStream`，退出时关闭 |
| `serve_unix(path, handler)` | POSIX 文件系统 Unix socket；默认权限 0600，不删除已有路径 |
| `serve_inherited(handler, fd=0)` | 复制并使用已有 TCP/Unix 监听 socket；原 fd 由调用方保留 |

POSIX 适配使用小型 C 系统调用桥接，协议和会话仍为 MoonBit。async 0.20.0 没有公开监听 fd 的 readiness API，因此仅 accept 采用 5 ms 可取消轮询，已连接数据 I/O 使用官方异步 `RawFdStream`；不导入依赖的 internal 包。继承时验证流式监听 socket、设置 CLOEXEC 与非阻塞；非阻塞标志影响原 fd 共享的 open file description。Unix 路径正常退出时按 inode/device 校验清理；SIGKILL 无法执行清理。Windows 对这两个 POSIX 入口返回错误，不宣称支持 Windows Unix socket。

角色默认仅启用 Responder；通过 `roles=[@fcgi.Responder, @fcgi.Authorizer, @fcgi.Filter]` 显式开启其他角色：Authorizer 不等待 STDIN，以 200 + `Variable-*` 头允许或以非 200 拒绝；Filter 先读取 `request.body` 至 EOF，再读取独立 `request.data`，STDIN 结束前不能写响应。角色不在允许列表中返回 UNKNOWN_ROLE。Nginx 示例使用 Responder，其他角色由外部协议驱动及 libfcgi 对照测试，不能据此宣称 Nginx 原生支持所有角色。

```sh
# TCP streaming echo and delayed-chunk download
moon run cmd/stream --target native -- 127.0.0.1:9000
# POSIX Unix socket (create a private parent directory first)
moon run cmd/stream --target native -- unix:/run/moonfcgi/app.sock
# A process manager must already have supplied a listening socket at fd0
# Execute the built cmd/stream binary with argument fd:0 in that environment.
```

[流式 Nginx 配置](examples/nginx-stream.conf) 同时关闭请求和响应缓冲；`/echo` 支持边上传边回显，`/download` 分块输出 4 MiB。Unix socket 部署时让 Nginx worker 与应用拥有匹配的访问权限，按需显式配置 socket mode；库不接管进程管理器。

完整行为、平台验证和复查命令见 [扩展说明](docs/STREAMING.md)。
## 测试与互操作

2026-10-22 Windows 实测 **26 项核心测试、原有 13 组真实 TCP/Go/Nginx 联调、新增 11 组流式/角色/Nginx 联调及 1 项独立包消费者验证**。Linux CI 同轮通过 26 项核心、13 组原有联调、16 组流式/角色/POSIX/libfcgi 联调和独立消费者；详见 [0.2.0 CI](https://github.com/Ryan-1125/moonfcgi/actions/runs/39717428442)。Windows x64 和 Ubuntu 24.04 native 均有运行记录；完整环境、断言和命令见 [验证记录](docs/VALIDATION.md)。

| 验证对象 | 覆盖内容 |
|---|---|
| 协议核心 | 固定字节向量、分片、PARAMS 跨 record、截断、大小限制和会话状态 |
| TCP 服务 | 中止、多路复用拒绝、请求 ID 复用、跨连接隔离、处理与写出超时 |
| Go 参考实现 | 共同支持场景中的 JSON、二进制正文、重复头、大响应和错误状态 |
| Nginx | GET、二进制 POST、404/500、HEAD、204/304 和真实上游连接复用 |
| 独立消费者 | 实际发布归档的协议与服务端 API 编译、运行 |

[GitHub Actions](https://github.com/Ryan-1125/moonfcgi/actions/workflows/ci.yml) 执行格式、检查、构建、测试、接口检查、真实联调及独立消费者验证。

```sh
moon fmt --check
moon check --target native
moon build --target native
moon test --target native
go build -o ../work/go-ref tools/reference/main.go
MOONFCGI_BIN=<native可执行文件> GO_REFERENCE_BIN=<go-ref> NGINX_BIN=<nginx> node tools/integration.mjs
node tools/consumer.mjs
```

Windows 将 go-ref 输出命名为 `.exe`，环境变量用 PowerShell `$env:NAME='...'` 设置。集成脚本默认使用工作区 `../work` 中的本地工具；Linux CI 通过环境变量指定。端口固定为 19000/19001/19002/18080，运行前应空闲。失败即退出非零；SKIP_GO/SKIP_NGINX=1 只用于排障，完整验收不可跳过。集成日志写入 `../work/`。脚本在 finally 中停止本轮启动的进程。

## 许可证与参考来源

项目采用 [Apache-2.0](LICENSE)。参考范围见 [来源与查重](docs/RESEARCH.md) 和 [第三方许可](THIRD_PARTY_NOTICES.md)。FastCGI 基于公开 1.0 规范独立实现；Go 源码用于行为参考和差分测试，不是通过 FFI 代理。项目 Apache-2.0，Go 标准库 BSD-3-Clause 来源许可证保留于 `licenses/Go-LICENSE`。
