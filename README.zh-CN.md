# FixCodexLag

[English](README.md) | [简体中文](README.zh-CN.md)

一个安全优先、面向 Windows 的 Codex Desktop 临时止损方案，针对两类进程生命周期问题：

- `taskkill.exe`、`conhost.exe` 或 Git 辅助进程失控增长，连带放大 WMI、Defender 与桌面卡顿；
- Codex 任务结束后，其 Node/MCP/CLI/CMD 进程树仍未退出。

FixCodexLag 会先诊断、再询问，未经确认不会修复。它是独立的社区方案，不是 OpenAI 官方修复。

## 快速开始

将技能克隆到 Codex 技能目录：

```powershell
git clone https://github.com/onovich/fix-codex-lag.skill.git `
  "$env:USERPROFILE\.codex\skills\fix-codex-lag"
```

重启 Codex，然后运行：

```text
$fix-codex-lag 诊断这台电脑。任何修复前都先询问我。
```

## 它会做什么

1. 执行一次有界诊断采样。
2. 区分活跃、受保护、已失效和无法确认归属的进程组。
3. 明确给出结论：确认有问题、未发现目标问题，或暂不能确定。
4. 暂不能确定时，提供透明的健康分、置信度，以及是否存在安全优化方案。
5. 然后才提供相应的修复、优化、监控或不处理选项。

定时监控默认每 60 分钟运行一次，绝不会自动修复。

## 安全边界

- 不按进程名或通配符批量终止进程。
- 保留 Codex 本身、活跃任务、其他项目，以及归属不明确的进程。
- 只有在失效归属证据充分时才生成精确预览，并在终止前再次核验进程身份。
- 诊断文件写入临时目录，并默认脱敏。

## 适用版本与时间

**最后核对：** 2026-07-22

本机 Windows 复现环境为 Codex Desktop `26.715.4045.0`、会话 CLI `0.144.5`、Windows 11 25H2；公开报告还涉及其他版本。这些只是已观察范围，不是兼容性保证。

使用前请检查最新状态：

- 清理进程风暴：[openai/codex#34260](https://github.com/openai/codex/issues/34260)；
- WMI/Defender 持续高负载：[openai/codex#34666](https://github.com/openai/codex/issues/34666)；
- MCP/Node 进程遗留：[openai/codex#32797](https://github.com/openai/codex/issues/32797)、[#17832](https://github.com/openai/codex/issues/17832)；
- 社区报告：[X/Twitter 讨论串](https://x.com/Umbra_Onovich/status/2079840843721294181)。

更高版本应先诊断再决定是否修复。如果关联 Issue 已修复，且相同症状不再复现，请停用本方案。

## 当前不覆盖

FixCodexLag 不是通用的 Windows 进程清理器，不会清除正常开发服务、活跃 Codex 运行时或无法证明归属的进程。

当前也**不处理 `logs_2.sqlite` / WAL 高频写入或 SQLite 锁竞争**。这个影响面更广的日志问题记录在 [openai/codex#17320](https://github.com/openai/codex/issues/17320)、[#20213](https://github.com/openai/codex/issues/20213) 和 [#24275](https://github.com/openai/codex/issues/24275)。目前优先等待官方根治，避免临时方案影响共享诊断数据；如果用户确有需求，后续可考虑加入需要主动选择且可逆的临时缓解方案。
