# MoonFCGI

纯 MoonBit FastCGI 1.0 协议核心、Responder 会话状态机及基于 `moonbitlang/async 0.20.0` 的原生 TCP 服务端库。模块暂定 `Ryan-1125/moonfcgi`，本地 v0.1.0；**尚未发布 Mooncakes**，发布前需要核实账户命名空间。

## 快速运行

当前代码使用 moon 0.1.20261016 / moonc v0.10.16+b1a0e846e（含 Int32 新语法），旧版 0.10.14 不能检查当前源码。已验证 Windows x64 native（Nginx 1.28.0）和 Ubuntu 24.04 native（Nginx 1.24.0），Go 参考版本固定 1.23.2。Linux 格式/check/build/test、真实 TCP/Go/Nginx 和独立消费者均已在 [GitHub CI](https://github.com/Ryan-1125/moonfcgi/actions/runs/39408894313) 通过。

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

具体配置语法以已编译的 `cmd/main/moon.pkg` 为准。完整公开签名见根目录及 `server/` 的 `pkg.generated.mbti`。离线打包和独立消费者验证使用 `node tools/consumer.mjs`；它消费 `moon package` 的解包内容，隔离于开发目录，再通过 `moon.work` 解析本地模块。发布后才可以使用 `moon add Ryan-1125/moonfcgi@0.1.0`，当前不能宣称注册表安装成功。

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

支持 Responder、GET_VALUES、UNKNOWN_TYPE 管理回复、ABORT_REQUEST、KEEP_CONN、顺序连接复用及已完成请求 ID 复用。`FCGI_MPXS_CONNS=0`；同连接第二个并发 BEGIN 收到 `FCGI_CANT_MPX_CONN`，不影响原请求。非 Responder 收到 `FCGI_UNKNOWN_ROLE`。管理请求 ID 必须为 0，应用请求 ID 为 1..65535；无活动匹配的记录忽略，活动请求内非法序列关闭连接。重复 BEGIN 同 ID 视为协议错误。未知管理类型返回 UNKNOWN_TYPE，活动请求中未知应用类型关闭连接。

`Limits.new` 默认：请求正文 8 MiB、PARAMS 256 KiB / 1024 对、响应正文与 stderr **各** 8 MiB、并发连接 64。响应头固定最多 128 项、UTF-8 序列化合计 32 KiB，单个名字最多 1024 字符、值最多 16384 字符。正文与响应全量缓冲，输出切 record 后写入；不提供全流式应用消费，也不承诺常数内存。handler 自己分配的内存不受库限制。

`Config.new` 默认 cycle 30000 ms（包含空闲、输入、handler、写出，总周期完成或中止后重置）、handler 10000 ms、整批写出 10000 ms。超时为总期限，持续滴字节不会重置。达到连接上限后暂停 accept，由系统 backlog 排队。取消是协作式，CPU 密集 handler 必须让出执行权；不可阻塞事件循环。调用方取消 serve 会关闭 listener 并取消子任务。

请求尺寸超限、非法参数/序列、record 截断、读写失败及周期超时关闭连接；不尝试在损坏的协议状态中生成 HTTP 错误页。handler 普通异常或处理超时返回 500；响应越限或非法响应头回退为空 500。ABORT 取消 handler 并输出一次 END_REQUEST；旧任务结果不可污染下一请求。输出采用互斥串行写，一旦已开始写完响应，之后到达的 ABORT 不会撤回已发送字节。每次正常响应生成 STDOUT/STDERR 的空终止记录和 END_REQUEST。

CGI 头不包含 HTTP 状态行；库禁止自定义 Status / Content-Length / Transfer-Encoding / Connection，防止 CR/LF 和控制字符注入。HEAD 无正文，204/304 无正文和 Content-Length。不实现 1xx、trailers、应用级流式输出、Unix socket、fd0、Authorizer/Filter、进程管理、multipart、TLS、自动重连或 Web 框架。TCP EOF 在请求完成之前视为断开，**不支持以 TCP 半关闭代替 STDIN 终止**。

## 验证与来源

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

见 [验证记录](docs/VALIDATION.md)、[来源与查重](docs/RESEARCH.md)、[第三方许可](THIRD_PARTY_NOTICES.md)。FastCGI 基于公开 1.0 规范独立实现；Go 源码用于行为参考和差分测试，不是通过 FFI 代理。项目 Apache-2.0，Go 标准库 BSD-3-Clause 来源许可证保留于 `licenses/Go-LICENSE`。
