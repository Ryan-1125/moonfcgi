# MoonFCGI 项目申报书

**项目名称：**MoonFCGI：MoonBit 原生 FastCGI 协议与异步服务端库  
**参赛方向：**新生态项目建设，参与季度优秀社区项目评选  
**项目类别：**Web 与网络基础设施／可复用协议库  
**仓库：**https://github.com/Ryan-1125/moonfcgi  
**实现类型：**依据公开规范独立实现，参考成熟开源库的接口与协议行为

## 项目定位与价值

MoonFCGI 为 MoonBit 程序提供与既有 FastCGI 部署环境互操作的基础库。应用通过缓冲式或流式 handler 接入 Nginx 等前端服务器，复用 Unix socket、继承监听和持久上游等部署方式，无需自行处理二进制记录、参数流和请求生命周期。核心协议与 socket 解耦，可用于服务端、协议适配器和其他运行环境；HTTP 边缘服务与进程管理由部署环境负责。

## 三个完整使用场景

1. **Nginx 后的 JSON API：**HTTP 客户端请求查询接口，Nginx 转为 FastCGI；MoonBit handler 读取参数并返回 JSON、状态和响应头。真实 Nginx 测试核对正文与状态，并验证两个 HTTP 请求复用同一 FastCGI 上游连接。
2. **流式二进制上传与下载：**客户端分段上传含零字节及非 UTF-8 字节的数据；handler 在 PARAMS 结束后逐块处理 STDIN，ResponseWriter 同步输出，借助有界队列和 socket 背压控制缓冲。测试覆盖 9 MiB 上传、4 MiB 下载，以及客户端收到前半回显后才发送后半正文的 Nginx 双向传输。
3. **长驻 FastCGI 服务部署：**应用通过私有 Unix socket 或启动器传入的 TCP/Unix fd0 接收请求，启用 KEEP_CONN 顺序复用；运维入口调用 Control.shutdown() 排空在途响应，超时后取消。事件和统计输出连接、请求耗时、字节量及错误分类；真实 Linux 测试验证继承、权限、路径清理和停机后的资源归零。

## 核心功能与实现路径

采用“纯 MoonBit 协议核心 → 会话状态机 → 异步服务端”的分层结构：增量 record/PARAMS 编解码处理任意分片、padding、二进制值、显式流终止与 EOF 截断；状态机实现 Responder、Authorizer、Filter、管理查询、ABORT、KEEP_CONN 和请求代次隔离。Authorizer 处理授权状态及 Variable-*，Filter 独立处理 STDIN/DATA。

服务端基于 moonbitlang/async 0.20.0，提供 TCP、POSIX Unix socket 与继承监听，支持跨连接并发、输入队列和总字节上限、分阶段期限、优雅停机、结构化事件及统计。每连接一个活动请求，能力报告 FCGI_MPXS_CONNS=0 并按协议拒绝并发 BEGIN。CGI 响应支持非 200 状态、重复头、HEAD/204/304 语义与头注入校验。POSIX 原生代码仅桥接系统调用，协议处理保留在 MoonBit 中。

## 来源与许可证

协议依据 [FastCGI 1.0](https://fastcgi-archives.github.io/FastCGI_Specification.html)；行为与互操作参考 [Go go1.23.2 net/http/fcgi](https://github.com/golang/go/tree/go1.23.2/src/net/http/fcgi) 及 [libfcgi](https://github.com/FastCGI-Archives/fcgi2/tree/47f2c03b7771f0ef61d887734ef91e6fa747f837)。项目采用 Apache-2.0；async 为 Apache-2.0，Go 为 BSD-3-Clause，libfcgi 为 Open Market 许可。参考范围与许可文本保存在 THIRD_PARTY_NOTICES.md 和 licenses/。

## 交付与验收

仓库提供完整源代码、公开 API、安装部署文档、Nginx 示例、测试与 CI。0.2.0 仓库版本在 Windows 与 Ubuntu native 完成验证；[Linux CI](https://github.com/Ryan-1125/moonfcgi/actions/runs/39724214744) 通过 28 项单元测试、13 组协议联调、16 组流式／角色／POSIX 联调、12 组生命周期联调和独立归档消费者。Mooncakes 已发布 0.2.0，可通过 `moon add Ryan-1125/moonfcgi@0.2.0` 安装。

复现入口为 `moon check/build/test --target native`（分别执行），以及 tools 下的 integration、stream-integration、lifecycle-integration 和 consumer 脚本；环境、命令和结果见 docs/VALIDATION.md。
