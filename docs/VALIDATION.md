# 本地验收记录

最新维护验证：18 项核心测试、13 组真实网络联调、1 项独立消费者测试通过。此前各节的版本和数量保留为阶段记录；本轮细节见文末。

日期：2026-10-20。实际运行平台 Windows x64，MSVC native 后端；不是模拟运行。

## 版本

| 工具 | 实测版本 |
|---|---|
| moon / moonrun | 0.1.20260920 (914d7da) |
| moonc | v0.10.14+7d59c7ec9 |
| moonbitlang/async | 锁定并读取源码 0.20.0 |
| Git | 2.53.0.windows.3 |
| Node | v22.22.1 |
| Go | go1.23.2 windows/amd64 |
| Nginx | nginx/1.28.0，官方 Windows 版本 |

初始环境无可调用 Go/Nginx/Docker。Go、Nginx 下载到工作区 `../work`，未安装为系统服务或更改 PATH。Moon 在受限沙箱内遇到 current directory Access denied；通过已授权的工具执行权限运行后可正常编译。首次 native 构建还暴露了编译器对可抛错默认参数的 C 返回类型错误，已将默认构造移到函数体内，未修改生成 C 文件。

## 执行命令与结果

在 `moonfcgi` 目录中，按顺序执行；每项失败均应停止：

```powershell
moon info
moon fmt
moon fmt --check
moon check --target native
moon build --target native
moon test --target native
../work/go/bin/gofmt.exe -w tools/reference/main.go
../work/go/bin/go.exe build -o ../work/go-ref.exe tools/reference/main.go
node tools/integration.mjs
node tools/consumer.mjs
git diff --check
```

- 格式、check、build：成功，无 Moon 编译警告。
- 核心测试：`Total tests: 15, passed: 15, failed: 0.` 固定人工字节向量和所有切点/多种片宽测试，不只依赖自产 encoder/decoder 往返。
- 外部网络驱动：`TOTAL 12 integration groups passed`，覆盖下表。
- 独立消费者：实际 `moon package` ZIP 解到临时工作区；独立模块依赖该解包模块，check/build/test 成功，`Total tests: 1, passed: 1, failed: 0.` 根协议 API 运行且 `/server` 的 Handler/Config 接口被独立编译引用；没有直接读取开发目录作为依赖。
- `moon package` 成功；现已填写真实公开 repository；早期打包时因未建库而产生的警告属于此前记录。
- 手工示例配置也执行了真实 `nginx -p <项目路径>/ -c examples/nginx.conf -t`，创建 logs/temp 后语法和路径检查成功。
- 临时消费者目录保留供复查，最近一次：`%TEMP%/moonfcgi-consumer-pBacfQ`。消费者脚本每次生成新的独立目录。

## 真实网络验收

| 组 | 断言 |
|---|---|
| TCP 字节驱动 | PARAMS 每 3 字节一个 record（含 padding）；180001 字节 0..255 循环正文；同连接同 ID 顺序复用；KEEP_CONN=false 后关闭 |
| 管理协议 | GET_VALUES 能力、忽略未知查询键、UNKNOWN_TYPE 固定 8 字节回复、拒绝 Authorizer |
| 中止与多路拒绝 | 第二 ID 收到 CANT_MPX_CONN；活动请求 ABORT；旧任务取消；同 ID 复用后无旧正文污染 |
| 并发与应用错误 | 慢 handler 与另一连接互不阻塞；处理超时及普通异常返回 500 |
| 异常输入 | 非法版本、EOF 截断、超限正文、空闲超时关闭连接 |
| 真实写超时 | 客户端暂停读，8 MiB 响应产生 TCP 背压；500 ms 写期限后无 END_REQUEST，连接关闭，新连接仍可服务 |
| 连接上限 | 测试配置 8 个空闲连接占满；第 9 个请求先排队，前序空闲连接超时后可处理 |
| Go 差分 | 同一个独立协议驱动分别连接 Moon 与固定 Go 1.23.2 标准库服务，比较 JSON、二进制正文、cookie 场景正文、大响应、404 的共同语义 |
| Nginx GET/复用 | Nginx 1.28.0 代理 JSON GET；两次 HTTP 请求通过透明 TCP 转发计数只建立一次真实上游 FastCGI 连接 |
| Nginx POST/错误 | 二进制 POST 逐字节一致；Set-Cookie 两项；404、handler 500 状态 |

测试配置与生产默认配置分开：示例可执行文件第二参数为 `test` 时 body=1 MiB、connections=8、cycle=1500 ms、handler/write=500 ms。正常运行不加 test，使用 README 中的默认资源值。

联调脚本自动生成的 Nginx 配置在 `../work/nginx-test/nginx.conf`；真实访问日志末段如下：

```text
GET /api/hello?a=1  -> 200, 33 bytes
GET /api/hello?a=1  -> 200, 33 bytes
POST /api/echo      -> 200, 180001 bytes
GET /api/cookies   -> 200, 7 bytes
GET /missing       -> 404, 9 bytes
GET /api/error     -> 500, 21 bytes
```

Nginx 会将较大 POST 缓冲到临时文件，error.log 的这一 warning 是 Nginx 行为，不是协议失败。完整 access/error 日志保留工作区。测试脚本 finally 结束本轮进程；测试后检查没有残留 nginx/main/go-ref 进程。

## 未完成的外部步骤及适用限制

- `.github/workflows/ci.yml` 已配置 Linux 格式/check/build/test、真实 TCP/Go/Nginx、独立消费者，已推送到公开仓库，Linux CI 已真实通过：https://github.com/Ryan-1125/moonfcgi/actions/runs/39408894313 。
- 官方旧版 Linux 工具链 URL 现场返回 403，CI 因此采用官方 latest 安装器并记录版本；Go 固定 1.23.2，Nginx 使用 Ubuntu 仓库版本。CI 的 Moon/Nginx 版本与本地可能不同，兼容性必须以 CI 实际结果判断。
- 未发布 Mooncakes。安装包验证是本地 ZIP + 独立 workspace 消费，**不是**注册表下载验证。发布后仍需全新目录执行 `moon add Ryan-1125/moonfcgi@0.1.0`，移除本地 workspace 替代，再运行消费者。
- 现已验证 Ubuntu 24.04 native；未做性能基准、长期压力测试、其他平台验证或生产级安全审计。无性能数字或全平台支持声明。
- 公开仓库已按用户授权建立并推送：https://github.com/Ryan-1125/moonfcgi 。Mooncakes namespace 仍待核实，未发布或报名。

## 建库前新增回归（2026-10-20）

复现并修复了跨会话同 ID/序号误完成；CGI Status 增加固定安全 reason phrase。新增真实 TCP 的 STDOUT/STDERR 空终止、HEAD、超限响应后恢复及 Nginx 204/304/超限回退检查；本轮 15 项核心测试和 12 组联调通过。公开仓库保留连续真实开发历史，首次推送包含 10 个提交；以后正常维护可能超过 10 个。


## 真实 Linux CI 与当前 SDK

2026-10-20，GitHub Actions run 39408894313 全部步骤成功：Ubuntu 24.04、moon 0.1.20261016、moonc v0.10.16+b1a0e846e、Go 1.23.2、Nginx 1.24.0。包含格式检查、检查、构建、15 项核心测试、12 组真实协议/Go/Nginx 联调和独立包消费者。

此前两轮失败记录保留在 Actions：第一轮新版格式差异及 artifact 路径不合法；第二轮 fresh runner 缺少 registry index。已分别修复，没有删除失败记录或跳过失败测试。

Windows 上同版本 SDK 安装在工作区 ../work/moon-sdk，未替换用户系统 SDK；新版代码已使用 Int32，旧全局 0.10.14 不再适用。当前目录的外部 outputs/Open-MoonFCGI.ps1 会用匹配 SDK 启动独立 VS Code 窗口。其他机器请安装当前官方 SDK，先执行 moon update。上方旧 SDK 表格为首次验收的历史记录。

## 提前拒绝无效正文声明与编辑器启动改进（2026-10-20）

先新增回归测试，确认旧实现会把声明长度校验推迟到 STDIN 结束；3 个新增测试在修复前失败，修复后全部通过。现在 PARAMS 结束时校验长度语法、冲突重复值和上限；正文逐 record 检查长度，越界立即拒绝，缺少字节仍在流终止时拒绝。覆盖空/零长度、相同数值重复值、非 UTF-8 长度和 Int32 边界，公开 API 签名没有变化。

真实 TCP 新增一组：仅发送 BEGIN/PARAMS（或发送超出声明长度的 STDIN record），不发送 STDIN 结束记录，断言服务器在 700 ms 内关闭连接，早于测试配置的 1500 ms 周期超时；之后独立连接正常响应。原有 Go/Nginx、顺序复用、ABORT、并发和写超时场景继续通过。

在 `D:\GitHub\moonfcgi`，先 `. ./tools/Use-LocalToolchain.ps1`，再运行 `moon info`、`moon fmt`、`moon check --target native`、`moon build --target native`、`moon test --target native`、`node tools/integration.mjs`、`node tools/consumer.mjs`。结果为 18 / 13 / 1 全部通过。

`tools/Open-MoonFCGI.ps1` 已改为默认复用普通窗口，只有显式 `-Isolated` 才启用独立配置。PowerShell Parser 语法检查通过；本轮没有再次启动编辑器窗口，也未声称交互界面经过自动化测试。

