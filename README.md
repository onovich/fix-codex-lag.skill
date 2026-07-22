# FixCodexLag

[English](README.md) | [简体中文](README.zh-CN.md)

A safety-first, Windows-focused temporary workaround for two Codex Desktop lifecycle problems:

- runaway `taskkill.exe` / `conhost.exe` / Git-helper churn that can amplify WMI, Defender, and desktop lag;
- Node/MCP/CLI/CMD process trees retained after their owning Codex task has ended.

FixCodexLag diagnoses first and asks before every repair. It is an independent community workaround, not an official OpenAI fix.

## Quick start

Clone the skill into your Codex skills directory:

```powershell
git clone https://github.com/onovich/fix-codex-lag.skill.git `
  "$env:USERPROFILE\.codex\skills\fix-codex-lag"
```

Restart Codex, then run:

```text
$fix-codex-lag Diagnose this PC. Ask before any repair.
```

## What it does

1. Takes one bounded diagnostic snapshot.
2. Separates active, protected, stale, and unknown process groups.
3. If a target problem is found, offers a one-time repair or no action.
4. If no problem is found, optionally offers a diagnosis-only monitor.

The monitor runs every 60 minutes by default and never repairs automatically.

## Safety

- Never kills by process name or wildcard.
- Preserves Codex itself, active tasks, unrelated projects, and anything with uncertain ownership.
- Requires strong stale-ownership evidence, previews the exact process tree, and revalidates its identity before termination.
- Requires separate approval before restarting Codex Desktop.
- Stores diagnostic artifacts in a temporary directory and redacts sensitive text by default.

## Time and version scope

**Last reviewed:** 2026-07-22

The local Windows reproduction used Codex Desktop `26.715.4045.0`, session CLI `0.144.5`, and Windows 11 25H2. Related public reports cover other builds. This is an observed range, not a compatibility guarantee.

Check the latest status before using the skill:

- cleanup storm: [openai/codex#34260](https://github.com/openai/codex/issues/34260);
- sustained WMI/Defender load: [openai/codex#34666](https://github.com/openai/codex/issues/34666);
- retained MCP/Node processes: [openai/codex#32797](https://github.com/openai/codex/issues/32797) and [#17832](https://github.com/openai/codex/issues/17832);
- community report: [X/Twitter thread](https://x.com/Umbra_Onovich/status/2079840843721294181).

On newer builds, diagnose before repairing. Stop using the workaround when the linked issues are fixed and the same symptoms no longer reproduce.

## Not covered

FixCodexLag is not a general Windows process cleaner. It does not remove legitimate development servers, active Codex runtimes, or processes whose owner cannot be proven.

It also does **not** address high-rate writes to `logs_2.sqlite` / WAL or SQLite lock contention. That broader logging problem is tracked in [openai/codex#17320](https://github.com/openai/codex/issues/17320), [#20213](https://github.com/openai/codex/issues/20213), and [#24275](https://github.com/openai/codex/issues/24275). This project currently favors an upstream fix over a workaround that could affect shared diagnostic data. A separate opt-in, reversible mitigation may be considered later if users need it.
