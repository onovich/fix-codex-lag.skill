# Scheduled diagnosis runbook

Use this reference only after the core diagnosis and safety contract in `SKILL.md` are loaded.

## Purpose

Use scheduling to catch an intermittent recurrence, not to perform unattended cleanup. The monitor must never kill a process, restart Codex, edit a repository, or direct another task.

## Detect an existing monitor

Use the current Codex automation tool and its documented metadata lookup. Match the exact name `FixCodexLag Monitor`.

- Treat an enabled matching automation as installed.
- Treat a disabled matching automation as present but disabled; offer to enable/update it instead of creating another.
- If more than one match exists, do not guess. Report duplicates and ask which one to retain.
- Read local automation metadata only to find an automation ID when the tool requires it. Never edit the metadata file directly.

## Create or update safely

Prefer a recurring heartbeat attached to the current FixCodexLag task. It reuses the diagnostic context instead of creating a fresh standalone task for each run.

Use these semantic settings through the automation tool's current schema:

| Setting | Value |
|---|---|
| name | `FixCodexLag Monitor` |
| status | enabled |
| kind | thread-attached recurring heartbeat when supported |
| cadence | every 60 minutes by default; never less than 30 minutes |
| destination | current local FixCodexLag task |
| action | bounded diagnosis and notification only |

Do not display or hand-write a raw recurrence rule. Translate the cadence through the automation tool.

Use this prompt content:

```text
Use $fix-codex-lag in scheduled diagnosis mode. Run one bounded, low-overhead diagnosis and lead with exactly one clear verdict: problem found, no targeted problem detected, or inconclusive. Never stop a process, restart Codex, edit a project, or message another task automatically. If a targeted cleanup-churn or verified-stale-runtime signature is confirmed, list each problem with sanitized evidence and ask whether to start a manual one-time repair. If no target is present and the evidence is sufficient, state clearly that no targeted problem was detected and end. If evidence is inconclusive, report the FixCodexLag health score or range, confidence, missing evidence, and whether a safe optimization exists; never optimize automatically. Do not offer or create another monitor from this scheduled run.
```

After the tool call, view the automation and verify its name, enabled state, target task, cadence, and prompt safety language.

## Avoid self-amplification

Creating a fresh standalone Codex job on every interval may add task/session and MCP lifecycle pressure, which is one of the problem families this skill mitigates. Therefore:

1. Prefer a thread-attached heartbeat.
2. If only standalone cron is supported, disclose the fresh-job/runtime risk.
3. Require separate explicit confirmation before creating that standalone cron.
4. Never create both a heartbeat and a cron fallback.
5. Never create a Windows Task Scheduler auto-cleanup fallback.

If no safe supported automation is available, explain that scheduled monitoring is unavailable in this environment and retain the one-time workflow.

## Scheduled-run cost controls

- Take one 10–12 second process sample.
- Do not include raw command lines.
- Do not run WPR/ETW unless the user separately authorizes an interactive investigation.
- Do not repeatedly query CIM/WMI after a timeout.
- Do not scan whole repositories or all Codex logs on a healthy window.
- Keep at most the current sanitized summary unless the user asks to retain evidence.

## Disable or replace

Use the automation tool to disable or delete the exact matching monitor. Verify the final state. Do not delete unrelated automations with similar words.
