# 持续运行与资源回收

真实 TCP 驱动复用生命周期测试服务，不使用 mock。覆盖持久连接顺序请求、反复 ABORT、上传中断、下载中断、恢复请求以及显式停机。每轮停机断言进程成功退出，active_connections 和 active_requests 均为零。

```powershell
. ./tools/Use-LocalToolchain.ps1
moon build --target native
$env:MOONFCGI_SOAK_SECONDS='3600'
node tools/lifecycle-integration.mjs
```

Linux：`MOONFCGI_SOAK_SECONDS=3600 node tools/lifecycle-integration.mjs`。时长允许 10..86400 秒；单进程轮次最长五分钟，随后停机并启动下一实例。CI 运行 60 秒回归，小时级运行由上述参数启用。

输出 soak-result.json 保存实际时长、成功请求数、每轮操作量和资源计数。Linux 读取真实进程 /proc 的 RSS 与描述符数量；Windows 的这些指标记为 null，不以 Node 驱动自身内存代替服务端指标。资源采样用于观察，不把短时数据或进程退出后的归零解释为无内存泄漏证明。

本地首次 60 秒验证使用每十秒重启一次的配置，后续默认轮次调整为五分钟以覆盖更长的单进程持续负载。准确运行结果以脚本输出和 CI 日志为准。既有生命周期回归继续覆盖停机排空、慢读期限和观察者异常隔离。
