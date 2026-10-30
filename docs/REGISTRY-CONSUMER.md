# 发布包消费回归

`node tools/registry-consumer.mjs` 在系统临时目录生成独立工程，固定依赖 Mooncakes `Ryan-1125/moonfcgi@0.2.0`，更新注册表后执行 native check（deny-warn）和 build。工程没有 moon.work，不使用开发目录或本地归档替代依赖。

测试启动该独立工程编译出的真实 TCP 服务：先执行固定字节协议 API 校验，再用外部 Node 字节驱动发送含零字节和非 UTF-8 内容的 10001 字节正文，检查 201 状态、两个 Set-Cookie、逐字节回显，以及同连接同请求 ID 的顺序复用。错误、截断、写出不符或超时均导致失败，最后关闭服务进程。

Windows 使用项目私有 SDK 时：

```powershell
. ./tools/Use-LocalToolchain.ps1
node tools/registry-consumer.mjs
```

Linux 使用匹配工具链直接运行相同 Node 入口。CI 同时保留实际归档消费测试：归档测试覆盖当前源码的打包质量，注册表测试覆盖已经发布的固定版本。新增源码功能并不自动成为旧发布包的验收能力。
