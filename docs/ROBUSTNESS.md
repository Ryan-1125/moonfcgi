# 协议健壮性与确定性随机测试

测试入口为 [robustness_test.mbt](../robustness_test.mbt)，由现有 Linux CI 的 `moon test --target native` 自动运行。固定种子保证输入、分片和请求序列可复现；测试无需网络或额外依赖。

| 测试组 | 固定种子 / 数量 | 独立预期与断言 |
|---|---|---|
| record 随机分片 | 1、7、2026、65535；400 条 record | 手工构造 header、非零 padding 和 reserved 字节；按生成前的字段逐项比较，随机合并/拆分读取及空 feed |
| record 边界与截断 | 391；最大正文 65535、padding 255；小向量所有非空截断；255 种非法版本 | padding 不进入正文，完整记录只产生一次；截断/非法版本后 decoder 拒绝继续使用；单次 feed 超限受控失败 |
| PARAMS 分片 | 17、128、2026、65535；256 条参数流 | 独立长度前缀，覆盖 0/1/127/128/255/256 字节名、二进制值、重复键、空值；不使用库 encoder 生成预期 |
| 恶意 PARAMS 与限额 | 412；256 条超大长度声明；固定向量所有截断点 | 远端巨大长度仅用前缀触发 ProtocolError；精确字节/参数数量边界；失败或结束后的调用受控拒绝 |
| 缓冲请求生命周期 | 3、2026、65535；300 个请求周期 | 两个独立会话、随机正文与 ID，完成/ABORT 后旧请求不能再次完成，外来会话请求不能完成本地请求 |
| 流式状态机 | 29、128、2026；300 个场景 | Filter 的 DATA 早于 STDIN 结束被拒绝；Responder 中止后同 ID 重用，旧完成操作不影响新请求，输入逐字节保持一致 |

伪随机生成器使用有界 16 位 LCG，乘法处于 Int32 范围内。异常断言仅接受公开 ProtocolError 的 Invalid、Limit、Truncated；其他异常继续抛出，避免把测试错误或运行时错误当成正确拒绝。

## 复现

Windows 使用项目私有 SDK 时先运行 `. ./tools/Use-LocalToolchain.ps1`，随后执行：

```sh
moon fmt --check
moon check --target native --deny-warn
moon build --target native
moon test --target native
```

2026-10-27 Windows native 实测：34 项测试全部通过（原有 28 项，加本次 6 组）。公共接口与生产实现保持不变。本轮确定性语料没有触发实现缺陷；上述覆盖范围是实际测试边界，不代表任意输入的穷尽证明或长期压力测试。

遇到失败时保留测试名称、seed、循环序号及实际输入，先将最小失败输入补为固定向量，再修复实现并重跑整套测试。现有网络、Go、Nginx 和 libfcgi 联调仍由完整 CI 执行，入口见 [验证说明](VALIDATION.md)。
