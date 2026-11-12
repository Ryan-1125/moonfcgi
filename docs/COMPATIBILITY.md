# 2026-11 工具链兼容维护

2026-11-12 官方 latest Windows SDK：moon 0.1.20261104 (940aa18)、moonc v0.10.20+65efd5b93、moonrun 0.1.20261104。SDK 独立安装于私有目录；依赖保持 async 0.20.0。

修正 Linux 部署安装路径：当前 native 产物在 Linux 也使用 .exe 后缀。注册表消费者采用实际文件存在性选择产物。同步更新格式化及生成接口中的 #derive 语法；公开函数与数据字段契约保持一致。

复验入口：moon version --all、moon info、moon fmt --check、moon check --target native --deny-warn、moon build --target native、moon test --target native，以及 tools 中 integration、stream-integration、lifecycle-integration、consumer、registry-consumer 脚本。

Windows 本轮已通过检查、构建、34 项单元、13 组 TCP/Go/Nginx、11 组流式与 10 组生命周期测试。实际归档独立消费者与 Mooncakes 0.2.0 注册表消费者均通过，包括核心 API、真实 TCP、二进制回显、201 状态、重复头和持久连接复用。Linux Ubuntu 24.04 使用相同 moon/moonc 版本完成全量验证：[CI 43189516998](https://github.com/Ryan-1125/moonfcgi/actions/runs/43189516998)，修复提交 542dec2。通过 34 项单元、13 组协议、12 组生命周期、16 组流式/POSIX/libfcgi、独立归档与注册表消费，以及 systemd/Nginx 配置校验。60.111 秒持续回归完成 11057 次成功请求，停机后活动连接与请求均归零；采样 RSS 8284 KiB、fd 10，为单次观测而非长期泄漏证明。
