# MoonFCGI

[![CI](https://github.com/Ryan-1125/moonfcgi/actions/workflows/ci.yml/badge.svg)](https://github.com/Ryan-1125/moonfcgi/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

MoonFCGI 是 MoonBit 原生 FastCGI 1.0 协议库与异步服务端库，为 MoonBit 程序提供与现有 FastCGI 服务器及部署环境互操作的基础组件。

项目包含独立协议核心、缓冲式与流式应用接口、Responder/Authorizer/Filter 角色、TCP/POSIX 传输，以及服务生命周期与诊断能力。协议和会话使用 MoonBit 实现，POSIX 系统调用通过轻量原生适配接入官方异步 I/O。

## 核心能力

- **协议编解码**：增量 record 与 PARAMS 解析，支持任意分片、padding、二进制参数与正文、显式流结束及截断校验。
- **应用接口**：Request/Response/Handler 与 StreamRequest/BodyStream/ResponseWriter；流式 handler 在 PARAMS 结束后启动，按块读取和写出。
- **协议角色**：Responder、Authorizer 与 Filter；管理查询、能力报告、ABORT、KEEP_CONN、请求 ID 顺序复用及会话代次隔离。
- **部署接入**：TCP、POSIX 文件系统 Unix socket、继承 TCP/Unix 监听描述符；Nginx JSON API、二进制传输和持久上游示例。
- **生命周期**：显式优雅停机、在途响应排空、宽限期取消、连接与子任务清理。
- **资源与诊断**：可配置输入队列、连接/大小上限、分阶段期限、结构化事件、异常隔离回调和统计快照。

## 快速开始

当前仓库接口版本为 **0.2.0**，通过源码工作区使用完整接口：

```sh
git clone https://github.com/Ryan-1125/moonfcgi.git
cd moonfcgi
moon update
moon check --target native
moon build --target native
moon test --target native
moon run cmd/stream --target native -- 127.0.0.1:9000
```

工具链验证环境：moon 0.1.20261020、moonc v0.10.16+b1a0e846e；官方异步依赖为 `moonbitlang/async 0.20.0`。服务端使用 native 后端，Windows x64 与 Ubuntu 24.04 均有实际运行验证。

| 分发入口 | 版本 | 接口范围 |
|---|---|---|
| 本仓库 / 本地打包归档 | 0.2.0 | 缓冲与流式 API、三个角色、POSIX 部署、生命周期及诊断 |
| [Mooncakes](https://mooncakes.io/docs/Ryan-1125/moonfcgi@0.2.0) | 0.2.0 | 缓冲与流式 API、三个角色、POSIX 部署、生命周期及诊断 |

在独立工程执行 `moon add Ryan-1125/moonfcgi@0.2.0` 安装完整接口。0.2.0 的下游工作区接入与实际归档消费示例见 [安装与部署](docs/DEPLOYMENT.md) 和 [消费者验证脚本](tools/consumer.mjs)。

## 流式应用示例

根包别名为 `fcgi`，服务端包别名为 `server`；完整包配置见 [cmd/stream/moon.pkg](cmd/stream/moon.pkg)。

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

`BodyStream.read()` 以 FastCGI 终止记录表示 EOF；`ResponseWriter` 按 record 写出并等待 socket 背压，handler 返回后由库完成输出流和 END_REQUEST。缓冲式入口为 `serve`，适合在明确大小上限内处理完整正文。

## Nginx 接入

使用 [流式配置](examples/nginx-stream.conf)，在仓库根目录创建 `logs`、`temp` 后启动 Nginx：

```sh
nginx -p <仓库绝对路径>/ -c examples/nginx-stream.conf
curl --data-binary @payload.bin http://127.0.0.1:8080/echo -o echoed.bin
curl http://127.0.0.1:8080/download -o download.bin
```

流式配置关闭请求和响应缓冲。JSON API、重复响应头、错误状态及持久上游示例见 [缓冲式配置](examples/nginx.conf) 与 [cmd/main](cmd/main/demo.mbt)。Unix socket 权限、继承监听和进程生命周期接入见 [部署指南](docs/DEPLOYMENT.md)。

## 文档与代码导航

| 入口 | 内容 |
|---|---|
| [架构与目录](docs/ARCHITECTURE.md) | 模块职责、数据路径与源码位置 |
| [API 与协议契约](docs/API.md) | 公开接口、角色、字节语义与资源约束 |
| [流式处理](docs/STREAMING.md) | STDIN/DATA、输出背压与错误完成语义 |
| [服务生命周期](docs/LIFECYCLE.md) | Control、事件、统计、队列与期限配置 |
| [安装与部署](docs/DEPLOYMENT.md) | 源码工作区、Nginx、TCP/Unix/fd 接入 |
| [测试与兼容性](docs/VALIDATION.md) | 真实联调结果、版本和复现命令 |
| [参考来源](docs/RESEARCH.md) | 规范、成熟实现及参考范围 |
| [项目申报书](docs/shenbao.md) | 项目定位、场景与验收交付 |

完整公开签名见 [协议核心接口](pkg.generated.mbti) 和 [服务端接口](server/pkg.generated.mbti)。

## 验证

协议核心另含 6 组固定种子的[健壮性与随机测试](docs/ROBUSTNESS.md)，覆盖独立字节向量、随机分片、异常长度、截断及请求状态模型；当前本地单元测试合计 34 项。

[Linux CI](https://github.com/Ryan-1125/moonfcgi/actions/runs/39724214744) 覆盖格式、检查、构建、接口一致性、**28 项单元测试、13 组协议联调、16 组流式/角色/POSIX 联调、12 组生命周期联调，以及独立包消费者**。

互操作对象包括真实 Nginx、Go 1.23.2 `net/http/fcgi` 和系统 libfcgi。测试覆盖请求结束前的双向传输、9 MiB 二进制上传、上游连接复用、角色处理、超时、中止、Unix/fd 接入及优雅停机。

## 协议与运行契约

每个连接同时处理一个活动请求，不同连接并发；能力查询报告 `FCGI_MPXS_CONNS=0`，并发 BEGIN 以协议状态拒绝。角色通过允许列表配置，默认 Responder。Nginx 验证使用 Responder，Authorizer/Filter 使用独立协议驱动与 libfcgi 对照。

输入队列、总字节数和连接数有明确上限；停机及取消采用协作式任务清理。POSIX 部署接口适用于 POSIX 环境，HTTP 边缘服务、TLS 和进程管理由部署环境承担。详细期限、所有权及异常语义见 API 和生命周期文档。

## 开源许可

采用 [Apache-2.0](LICENSE)。FastCGI 规范、Go、libfcgi 与 async 的来源及许可见 [第三方说明](THIRD_PARTY_NOTICES.md)；对应许可证保存在 [licenses](licenses)。
