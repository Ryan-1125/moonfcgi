# 流式请求与响应

接口版本：0.2.0。安装入口见 [README](../README.md)。

StreamSession 独立于 socket，在 PARAMS 结束时产生 RequestHead。服务端将 STDIN/DATA 送入有界 BodyStream，StreamHandler 逐块消费，ResponseWriter 增量输出 STDOUT/STDERR，保留零字节及非 UTF-8 数据。

## 角色与处理流程

| 角色 | 契约 |
|---|---|
| Responder | 消费 STDIN，生成 CGI 响应 |
| Authorizer | PARAMS 结束即处理，通过状态与 Variable-* 头表达授权 |
| Filter | 独立 STDIN/DATA；先完成 STDIN，再处理 DATA；STDIN 结束后开始输出 |

默认允许 Responder，其他角色显式配置白名单。Nginx 示例使用 Responder，角色行为由外部驱动与 libfcgi 对照验证。

PARAMS 结束后启动 handler，输入输出可并行；响应结束发送 END_REQUEST。提前返回后排空剩余输入，再按 KEEP_CONN 复用或关闭连接。每连接一个活动请求，跨连接并发。

## 背压与生命周期

每流队列默认 4 条 record，可配置为 1..1024，满时暂停生产者。socket 写出产生真实背压。总输入、DATA、参数及输出另受 Limits 约束，应用保留的数据由应用管理。

ABORT、断开、期限和停机取消通过任务生命周期传播。背压期间后续控制消息读取由期限约束。完成操作绑定会话代次，避免旧任务污染下一请求。CGI 头提交后状态固定；提交前普通 handler 异常可返回 500。

运行示例见 [cmd/stream](../cmd/stream) 与 [Nginx 配置](../examples/nginx-stream.conf)。部署入口见 [部署](DEPLOYMENT.md)，停机与诊断见 [生命周期](LIFECYCLE.md)，真实测试结果见 [验证](VALIDATION.md)。
