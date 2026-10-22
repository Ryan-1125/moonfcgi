# 项目能力与交付

MoonFCGI 是 MoonBit 原生 FastCGI 协议与异步服务端库，用于将可复用 handler 接入现有 FastCGI 部署环境。

- 纯 MoonBit 增量 record/PARAMS 编解码与独立状态机。
- 缓冲式/流式 API，Responder、Authorizer、Filter 角色。
- TCP、POSIX Unix socket、继承 TCP/Unix 监听。
- 有界队列、资源限制、期限、优雅停机、事件与统计。
- CGI 状态与重复头、管理消息、中止和连接顺序复用。

| 应用 | 入口 |
|---|---|
| Nginx JSON/二进制 API | cmd/main、examples/nginx.conf |
| 流式上传下载与双向处理 | cmd/stream、examples/nginx-stream.conf |
| 长驻 Unix/fd0 服务 | POSIX API、Control、Stats、ServerEvent |

[API](API.md)、[架构](ARCHITECTURE.md)、[部署](DEPLOYMENT.md)、[验证](VALIDATION.md) 构成完整交付说明。[申报书](shenbao.md) 提供项目材料入口。每连接一个活动请求；HTTP/TLS 与进程管理由部署环境负责。分发版本见 [README](../README.md)。
