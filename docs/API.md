# API 与协议契约

适用接口版本：0.2.0。根包 `Ryan-1125/moonfcgi` 提供协议与状态机，`Ryan-1125/moonfcgi/server` 提供 native 服务端。完整签名由 moon info 生成于两个包的 pkg.generated.mbti。

## 协议核心

| API | 契约 |
|---|---|
| Decoder.feed / finish | 增量 record 解析，每次 feed 最大 65536 字节；固定约 66 KiB 暂存；finish 检查 EOF 截断；解析错误结束该实例 |
| encode_record / stream_records | 8 字节 header、65535 字节内容分片、padding 和显式空终止记录 |
| ParamsDecoder.feed / finish | 长度前缀、名字和值可跨任意分片或 record；总字节和数量受限；保留重复及二进制值 |
| Session.accept / complete | 缓冲式 Responder，完成结果绑定会话所有权和请求代次 |
| StreamSession.accept / complete | RequestHead、Start/Input/InputEnd 事件，逐块交付三个角色的输入 |
| Request / RequestHead.param | 返回最后一个同名参数的原始 bytes，完整有序参数列表保留 |
| text_param | 显式执行严格 UTF-8 解码 |
| Response.cgi_bytes / cgi_headers | CGI Status 与有序重复响应头；缓冲正文或已知/未知长度的流式头 |

字节数用于协议长度和容量计算，二进制零字节是正文的一部分。FastCGI 空记录是流结束；socket EOF、record 输入不足与请求完成分别处理。

## 角色与会话

- Responder：PARAMS 后处理 STDIN 并生成 CGI 响应；流式输出可与输入并行。
- Authorizer：PARAMS 结束即可作出决定；200 与 Variable-* 头传递授权结果，非 200 返回拒绝响应。
- Filter：先 STDIN、后独立 DATA；STDIN 结束后写出，DATA 可逐块处理。

角色通过允许列表配置，默认 Responder。GET_VALUES/UNKNOWN_TYPE 使用管理请求 ID 0；应用请求 ID 范围 1..65535。每连接一个活动请求，能力报告为 FCGI_MPXS_CONNS=0，第二个并发 BEGIN 返回 CANT_MPX_CONN；角色不在允许列表时返回 UNKNOWN_ROLE。

KEEP_CONN 支持顺序复用，完成或中止后的旧结果由会话所有权和代次检查隔离。非法序列、长度超限、截断及传输错误结束连接。正文 CONTENT_LENGTH 在 PARAMS 结束时检查语法、重复冲突和上限，并在后续输入中持续检查；Filter 另检查 FCGI_DATA_LENGTH。

## 服务端入口

| 入口 | 说明 |
|---|---|
| serve / Handler | 有界缓冲请求与响应 |
| serve_stream / StreamHandler | 逐块 STDIN/DATA、STDOUT/STDERR |
| serve_unix | POSIX 文件系统 Unix socket |
| serve_inherited | 复制并接入既有 TCP/Unix 监听 fd，默认 0 |
| serve_stream_io | 在已有 Reader/Writer 上运行协议 |
| Config / Control / Stats | 资源与期限配置、优雅停机、诊断与快照 |

## 默认资源

请求正文 8 MiB、PARAMS 256 KiB/1024 对、响应正文与 stderr 各 8 MiB、并发连接 64。响应头最多 128 项，UTF-8 序列化合计 32 KiB；单个名字上限 1024 字符、值上限 16384 字符。流式每流默认排队 4 个 record，input_queue_records 可配置 1..1024。

资源上限约束库管理的输入和输出；应用自行保留的数据由应用管理。队列满时阻塞生产者，后续控制消息的读取也随之受背压影响；输入、handler 和总周期期限提供取消界限。

## CGI 响应

状态范围为 200..599；重复响应头保持有序。库生成 CGI Status 头，而非 HTTP 状态行。Status/Content-Length/Transfer-Encoding/Connection 由序列化器管理；响应头校验控制字符与 CR/LF 注入。HEAD 抑制正文；204/304 抑制正文及 Content-Length。

缓冲 API 先验证完整响应；流式 API 的响应头提交后保持既有状态，后续应用异常以非零 appStatus 结束。正常完成生成 STDOUT/STDERR 空终止记录和一次 END_REQUEST。声明长度不符或写失败结束连接，已发送字节保持其网络语义。

## 运行约定

流结束由 FastCGI 终止记录表达；TCP 半关闭属于传输事件。HTTP 路由、multipart、TLS 终止和进程管理由应用或前端服务器负责。阶段期限、错误分类和停机入口见 [生命周期说明](LIFECYCLE.md)。
