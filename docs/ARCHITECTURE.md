# 架构与目录

MoonFCGI 按 MoonBit 的目录包模型组织。根目录是独立协议包，server 是 native 服务端包，cmd 是可运行程序；包路径对应公开导入路径。

```text
moonfcgi/
├── moon.mod                   模块元数据与依赖
├── moon.pkg                   纯协议包依赖
├── codec.mbt                  增量 record 编解码
├── params.mbt                 PARAMS 流编解码
├── app.mbt                    缓冲请求与 CGI 响应
├── session.mbt                缓冲式 Responder 会话
├── stream.mbt                 流式会话及角色模型
├── *_test.mbt                 核心固定向量与边界测试
├── pkg.generated.mbti         协议公开签名
├── server/
│   ├── server.mbt             缓冲式 TCP 与配置
│   ├── streaming.mbt          流式 I/O、背压和角色调度
│   ├── lifecycle.mbt          停机、事件、统计和期限
│   ├── posix.mbt              POSIX 传输接入
│   ├── posix.c                socket 与 fd 系统调用桥接
│   └── lifecycle_test.mbt     配置和控制契约测试
├── cmd/
│   ├── main/                  JSON 与缓冲响应示例
│   ├── stream/                流式与角色示例
│   └── lifecycle/             生命周期集成测试程序
├── examples/                  Nginx 部署配置
├── tools/                     协议驱动、参考服务和消费验证
├── docs/                      用户文档、验证依据与 shenbao.md 申报材料
├── licenses/                  第三方许可文本
├── .github/workflows/ci.yml   Linux 自动化验证
├── README.md                  使用入口
├── CHANGELOG.md               版本变更
└── THIRD_PARTY_NOTICES.md      来源与许可说明
```

## 请求路径

网络字节 → Decoder → Record → Session/StreamSession → 应用 handler → CGI 响应 → FastCGI STDOUT/STDERR → END_REQUEST。

PARAMS 解析独立于 socket read 边界。协议层校验请求 ID、角色和流序列；传输层负责连接、任务、期限、背压与清理；应用层负责业务逻辑。流式 handler 在 PARAMS 结束后开始工作，正文通过有界队列交付。

## 所有权

serve 系列负责自身监听器；serve_connection、serve_stream_connection 和 serve_raw_connection 接管已连接句柄。serve_stream_io 使用调用方拥有的 Reader/Writer，关闭由调用方处理。serve_inherited 复制监听 fd，自身关闭副本，原 fd 和对应路径仍由调用方管理。

## 验证分层

核心测试验证固定字节、分片和状态；外部驱动验证网络与并发；Nginx 验证 HTTP/FastCGI 接入；Go/libfcgi 验证共同支持语义；消费者验证实际归档的公共 API。每层的命令和结果见 [测试说明](VALIDATION.md)。
