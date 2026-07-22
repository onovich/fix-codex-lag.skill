# FixCodexLag

Temporary, safety-first mitigation for two Codex Desktop lifecycle problems on Windows:

1. rapid `taskkill.exe` / `conhost.exe` / Git cleanup churn that amplifies WMI, Defender, and desktop-compositor load;
2. retained Node/MCP/CLI/CMD runtime groups after their owning Codex task is no longer active.

This is an independent community workaround, not an OpenAI product fix. It diagnoses first, asks before every one-time repair, and preserves active or ambiguously owned processes.

## Time and version scope

**Last reviewed:** 2026-07-22

| Evidence | Version observed | Public status on 2026-07-22 |
|---|---|---|
| Original local incident reproduction | Codex Desktop `26.715.4045.0`, session CLI `0.144.5`, Windows 25H2 x64 build 26200 | Workaround evidence only |
| Current skill-script validation | Codex Desktop `26.715.4045.0`, configured CLI `0.145.0-alpha.18` | Collector/manifest/executor tests only |
| Cleanup/taskkill storm | Codex Desktop `26.715.4045.0` | [openai/codex#34260](https://github.com/openai/codex/issues/34260) open |
| Sustained WMI/Defender load | Codex Desktop `26.715.8383.0` | [openai/codex#34666](https://github.com/openai/codex/issues/34666) open |
| Repeated MCP/Node process pools | Codex Desktop `26.707.8479.0` | [openai/codex#32797](https://github.com/openai/codex/issues/32797) open |
| Earlier MCP child-process regression | Codex App `26.409.20454`, CLI `0.120.0` | [openai/codex#17832](https://github.com/openai/codex/issues/17832) open |

## Check whether this skill still applies

Before installing or running a repair on a newer build, check the current public evidence:

- primary cleanup-storm report: [openai/codex#34260](https://github.com/openai/codex/issues/34260);
- related WMI/Defender and retained-runtime reports: [#34666](https://github.com/openai/codex/issues/34666), [#32797](https://github.com/openai/codex/issues/32797), and [#17832](https://github.com/openai/codex/issues/17832);
- community incident summary and follow-up: [X/Twitter thread](https://x.com/Umbra_Onovich/status/2079840843721294181).

Read each issue's latest resolution and affected version rather than relying only on its open/closed label. Then run the skill's diagnosis: if the exact signatures no longer reproduce on the installed build, do not repair.

These versions are an **observed range, not a compatibility guarantee**. On builds newer than `26.715.8383.0`, use the skill only to reproduce and diagnose the exact signatures before considering cleanup.

Stop using the workaround and disable its monitor when OpenAI release notes or linked issues confirm both lifecycle families are fixed and the signatures no longer reproduce on the installed build. Re-check the official status before use on any build released after 2026-07-22 instead of assuming the workaround remains necessary.

## What it targets

- repeated short-lived cleanup helpers correlated with Codex cancellation or stale Git-review snapshots;
- WMI/Defender/DWM pressure caused or amplified by that process churn;
- a Node/MCP/CLI/CMD process tree with strong evidence that its exact owning Codex task is complete or archived;
- system stutter that persists even when average CPU appears modest, when process churn or retained handles are measurable.

It does **not** target general Windows process cleanup, legitimate Node development servers, active Codex tasks, processes with unknown ownership, WMI, Defender, DWM, Explorer, or the shared Codex app-server.

## Out of scope: diagnostic-log write storms

The current skill does **not** diagnose or mitigate sustained writes to `logs_2.sqlite` or its WAL, nor SQLite lock contention. Public reports span Codex Desktop, IDE/app-server, and multi-instance CLI paths, so this is broader than the Windows process-lifecycle failures handled here. It is already tracked in the official repository through [openai/codex#17320](https://github.com/openai/codex/issues/17320), [#20213](https://github.com/openai/codex/issues/20213), and [#24275](https://github.com/openai/codex/issues/24275); all three were still open when reviewed on 2026-07-22.

Because a temporary workaround could alter or suppress diagnostic logging and affect every active Codex task sharing that store, this project currently leaves that problem to an upstream fix. If users need temporary containment, a separate opt-in, reversible mitigation may be considered later after its safety boundaries are validated.

## Install

Clone directly into the Codex skill directory:

```powershell
git clone https://github.com/onovich/fix-codex-lag.skill.git `
  "$env:USERPROFILE\.codex\skills\fix-codex-lag"
```

Restart Codex so the skill picker refreshes, then invoke `$fix-codex-lag`.

## One-time instruction

Copy this into Codex:

```text
$fix-codex-lag Run one bounded diagnosis first. If the targeted problem is present, ask me to choose: 1. Execute a one-time repair; 2. Leave it alone. If it is not present, ask me to choose: 1. Enable scheduled diagnosis; 2. Leave it alone. Never repair before I choose.
```

Chinese version:

```text
$fix-codex-lag 先执行一次有界诊断。如果命中目标问题，只让我选择：1.执行一次性修复；2.不管。如果没有命中，只让我选择：1.开启定时诊断；2.不管。在我选择前不要执行修复。
```

## Interaction

- **Target hit:** choose one-time repair or leave it alone.
- **No target hit:** choose an opt-in scheduled diagnosis monitor or leave it alone.
- **After repair:** if no monitor exists, choose whether to enable it.
- **Scheduled run:** diagnose and notify only; never repair automatically.

The default monitor cadence is 60 minutes and never less than 30 minutes. A thread-attached Codex heartbeat is preferred. If the environment can only create standalone recurring jobs, FixCodexLag must disclose that fresh jobs may themselves add task/MCP lifecycle pressure and request separate confirmation.

No Windows Task Scheduler auto-cleanup fallback is installed: an OS-only background script cannot reliably know which Codex tasks are active.

To disable the monitor:

```text
$fix-codex-lag Disable only the automation named FixCodexLag Monitor and verify that it is disabled. Do not change other automations.
```

## Safety model

- No killing by process name or wildcard.
- `0% CPU`, process age, and excess counts are not stale-process proof.
- `PROTECTED`, `ACTIVE`, and `UNKNOWN` groups are preserved.
- A cleanup manifest requires PID, start time, command-line hash, stable tree shape, and at least two independent stale-ownership proofs.
- Cleanup is previewed before execution and limited to five verified roots per batch.
- Full Codex restart always requires separate approval.
- Other projects and Codex tasks are not modified or instructed to change their work.

## Privacy

Snapshots omit raw command lines and redact user/host values, common absolute paths, email addresses, UUIDs, network addresses, and common credential forms by default. Cleanup manifests accept controlled evidence codes instead of free-form evidence text.

Generated snapshots, manifests, and ETL traces are private diagnostic artifacts, not publication-ready reports. Never commit or upload them directly. Public reports should contain only aggregate counts, durations, product/OS versions, role names, and placeholders. Omit PIDs and command-line hashes unless essential; a stable hash can still fingerprint a repeated local command.

`-IncludeCommandLine` and `-NoRedact` are explicit local-debugging overrides. Files created with either option must stay private and be deleted after use.

## Repository layout

- `SKILL.md` — agent workflow and decision gates
- `agents/openai.yaml` — Codex UI metadata
- `scripts/collect-runtime.ps1` — bounded process sampler
- `scripts/protect-sensitive-text.ps1` — shared default-redaction helper
- `scripts/new-cleanup-manifest.ps1` — identity-locked cleanup manifest builder
- `scripts/stop-verified-runtime.ps1` — preview-first verified executor
- `references/windows-runbook.md` — diagnosis details
- `references/automation.md` — safe recurring-monitor behavior

## 中文说明

FixCodexLag 是官方修复前的临时止损技能，针对 Windows 版 Codex 的两类现象：

1. `taskkill` / `conhost` / Git 进程风暴带来的 WMI、Defender、DWM 高负载和整机卡顿；
2. 已结束 Codex 任务遗留的 Node/MCP/CLI/CMD 进程组。

本技能最后核对日期为 **2026-07-22**。原始本机问题证据来自 **Codex Desktop 26.715.4045.0 / 会话 CLI 0.144.5**；本轮脚本复验时配置的 CLI 为 **0.145.0-alpha.18**。官方公开报告覆盖到 **26.715.8383.0**，且上述 issue 在核对当日仍为 open。更高版本只能先按症状诊断，不能默认仍需要清理。官方确认修复且当前版本不再复现后，应停用定时诊断并卸载本技能。

使用前可查看 [主要官方 Issue #34260](https://github.com/openai/codex/issues/34260)、上方列出的关联 Issue，以及[公开的 X/Twitter 讨论串](https://x.com/Umbra_Onovich/status/2079840843721294181)，确认当前版本是否仍会复现目标症状。不要只看 Issue 是否关闭，还应核对修复版本并重新诊断。

当前版本**不处理 `logs_2.sqlite` / WAL 持续写入或 SQLite 锁竞争造成的卡顿**。相关公开报告已经进入官方 `openai/codex` 仓库（[#17320](https://github.com/openai/codex/issues/17320)、[#20213](https://github.com/openai/codex/issues/20213)、[#24275](https://github.com/openai/codex/issues/24275)），影响范围也横跨 Desktop、IDE/app-server 和 CLI 多实例，比本技能针对的 Windows 进程生命周期问题更广。因此目前优先等待官方根治，不引入可能影响共享日志库和活跃任务的临时数据库改动；如果用户确有需求，后续会考虑加入经过安全验证、可逆且明确选择后才启用的临时方案。

定时能力只做诊断和提醒，不会自动杀进程。任何一次性修复都必须先展示证据，再由用户明确选择。
