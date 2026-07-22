---
name: fix-codex-lag
description: Provide a temporary, Windows-first mitigation for Codex Desktop slowdowns caused by rapid taskkill/conhost/WMI/Defender process churn or retained Node/MCP/CLI/CMD runtime groups. Use when Codex must diagnose stutter, offer a user-confirmed one-time repair, optionally configure a diagnosis-only recurring monitor, correlate a cleanup storm with a task or operation, or remove runtimes provably no longer owned by any active Codex task while preserving Codex itself, active tasks, unrelated projects, and ambiguous processes.
---

# FixCodexLag

Use this skill as a temporary containment runbook until the product lifecycle bug is fixed. Diagnose first, then remove only exact stale runtime groups. Never present the mitigation as an official product fix.

Respond in the user's language. Keep `Observed`, `Correlated`, and `Inferred` findings separate.

Before offering repair or scheduling, compare the installed Codex version and current date with [README.md](README.md#time-and-version-scope). If the build is newer than the observed range or the status snapshot is old, treat historical issue status as stale: run local diagnosis first and, when internet access is available, verify official Codex issues/release notes. Do not enable a monitor merely because an older build was affected.

## Enforce the safety contract

- Treat the current task, every running/waiting/needs-attention Codex task, user-named protected tasks, and every process with uncertain ownership as protected.
- Use task/thread tools read-only to build the active-task ledger when available. Do not send instructions to other tasks, alter their plans, or ask them to clean themselves unless the user explicitly requests that coordination.
- Never kill by image name. Prohibit commands such as `taskkill /IM node.exe`, `taskkill /IM cmd.exe`, `Stop-Process -Name node`, and wildcard termination.
- Never terminate Codex/ChatGPT UI processes, the shared app-server, the current shell or its ancestors, WMI, Defender, DWM, Explorer, service hosts, or Windows security/session processes.
- Do not treat `0% CPU`, age, process count, or “more groups than active tasks” as proof that a process is stale.
- Preserve a generic MCP/Node group under a shared app-server when no task ID, unique workspace, lifecycle event, or other ownership evidence distinguishes it. Label it `UNKNOWN`.
- Avoid tight WMI/CIM polling when WMI is already hot. Use one bounded metadata snapshot; use ETW/WPR only when short-lived churn must be proven.
- Limit cleanup to five verified roots per batch. Preview, execute, then resample before another batch.
- Require explicit user authority before restarting Codex Desktop because a restart interrupts every active task.
- Resolve bundled scripts relative to this `SKILL.md`. Write snapshots, manifests, and traces to a unique temporary directory, never into a project repository or the installed/distributed skill folder.
- Never let a scheduled run terminate processes, restart Codex, edit projects, or message other tasks. Scheduling is diagnosis and notification only.

## Apply the interactive decision gate

Begin every manual invocation with one bounded diagnosis. A user request to clean processes authorizes reaching the repair choice; it does not authorize termination before the diagnosis is shown.

Define a **target hit** as either:

- a Codex-correlated cleanup-churn storm; or
- at least one process group classified `STALE` by the evidence rules below.

After diagnosis, follow exactly one branch:

### Manual run: target hit

Show the evidence and ask one two-option question:

1. Execute a one-time repair.
2. Leave it alone.

Do not repair until the user selects option 1. If the available UI supports a structured short-choice prompt, use it; otherwise ask in the final response and stop the turn.

### Manual run: no target hit

Say that neither targeted signature was observed in the current window. If `FixCodexLag Monitor` is not already enabled, ask:

1. Enable scheduled diagnosis.
2. Leave it alone.

If the monitor is already enabled, report that fact and do not create or offer a duplicate.

### After a one-time repair

Verify the result first. Then check whether `FixCodexLag Monitor` is enabled. If it is absent, ask:

1. Enable scheduled diagnosis.
2. Leave it alone.

Do not combine the repair choice and monitor choice into one question. The repair result must be known before offering the monitor.

### Scheduled run

Diagnose only. If the target is hit, show the evidence and ask:

1. Execute a one-time repair.
2. Leave it alone.

If no target is hit, emit a short healthy-window report and end. Do not offer another monitor from a monitor-triggered run.

## Manage the opt-in monitor

Read [references/automation.md](references/automation.md) before viewing, creating, updating, or disabling a monitor.

- Use the Codex automation tool when it is available. Never hand-edit automation state or expose raw recurrence rules to the user.
- Use the exact automation name `FixCodexLag Monitor` so duplicate detection is deterministic.
- Prefer a recurring heartbeat attached to the current FixCodexLag task. Default to a 60-minute cadence unless the user requests another interval; refuse intervals shorter than 30 minutes because the diagnosis itself has cost.
- Configure the automation prompt to invoke `$fix-codex-lag` in scheduled diagnosis mode and to prohibit automatic repair.
- Do not silently fall back to Windows Task Scheduler or a process-killing script. A standalone OS task cannot reliably map processes to active Codex tasks.
- If only standalone Codex cron jobs are available, explain that repeated fresh jobs may themselves add Codex tasks/runtimes. Create one only after separate explicit confirmation.
- Prefer updating an existing monitor over creating another. Verify its status after creation or update.

## Follow the workflow

### 1. Establish scope and active ownership

Start with a brief commentary update before using tools.

Determine whether this is a manual or scheduled run. Read-only inspection does not authorize process termination; only option 1 at the post-diagnosis decision gate does.

Build an active-task ledger with these fields:

| Field | Meaning |
|---|---|
| task token | Redacted task identifier such as `<TASK-A>` |
| state | running, waiting, needs attention, completed, archived, or unknown |
| workspace token | Redacted unique workspace when available |
| last live operation | Tool call, shell, generator, Git review, or unknown |
| process evidence | Exact task marker, unique workspace command, process root, or none |
| protection | `PROTECTED`, `INACTIVE`, or `UNKNOWN` |

Use Codex task tools such as `list_threads`, `read_thread`, or an immediate `wait_threads` snapshot when available. Consider a task inactive only when the product state or an explicit lifecycle event shows that no turn/tool call is running. Silence or old age alone is insufficient. If task tools are unavailable, do not infer task inactivity from the OS process list.

Add the current process and its ancestor chain to the protected set. Add any PID explicitly mapped to an active task.

### 2. Capture bounded process evidence

Resolve the loaded skill directory and create a private run directory:

```powershell
$SkillRoot = '<directory containing the loaded SKILL.md>'
$RunRoot = Join-Path ([IO.Path]::GetTempPath()) ("fix-codex-lag-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $RunRoot | Out-Null
$Snapshot = Join-Path $RunRoot 'runtime-snapshot.json'
$Collector = Join-Path $SkillRoot 'scripts\collect-runtime.ps1'
$ManifestBuilder = Join-Path $SkillRoot 'scripts\new-cleanup-manifest.ps1'
$Executor = Join-Path $SkillRoot 'scripts\stop-verified-runtime.ps1'

& powershell -NoProfile -ExecutionPolicy Bypass `
  -File $Collector `
  -DurationSeconds 12 -SampleMilliseconds 250 -OutputPath $Snapshot
```

The collector records CPU deltas, starts/exits seen during sampling, process identity, parent PID, memory, handles, role hints, and command-line hashes. It omits raw command lines and redacts paths by default.

If WMI/CIM is timing out, rerun once with `-SkipCim`; use the result only for pressure diagnosis, not destructive ownership decisions. If exact command lines are needed locally, use `-IncludeCommandLine -NoRedact`, keep the file private, and delete it after analysis.

Read [references/windows-runbook.md](references/windows-runbook.md) when interpreting the snapshot, correlating logs, using WPR, or distinguishing the two failure modes.

### 3. Classify each relevant process group

Use exactly four classes:

- `PROTECTED`: Codex core, current ancestors, system/security/UI infrastructure, user-protected tasks, and all processes owned by active tasks.
- `ACTIVE`: a non-core runtime with a direct ownership match to an active task or operation.
- `STALE`: a runtime group with at least two independent ownership/lifecycle proofs that it belongs only to an inactive task, with no contradictory active mapping.
- `UNKNOWN`: anything else. Preserve it.

Acceptable independent stale proofs include:

1. An exact task/thread marker maps to a completed or archived task.
2. A unique workspace/runtime marker maps only to inactive tasks and no active task shares it.
3. A task-close or tool-exit event predates the still-running group.
4. The original task supervisor is gone and the remaining group is idle with no live client/listener.
5. A private runtime registry or product log explicitly releases that group.

Idle samples, high age, generic `server.mjs` arguments, or excess group count are supporting symptoms only. Require at least one ownership proof among items 1, 2, 3, or 5.

### 4. Identify the triggering failure mode

#### Cleanup-churn storm

Look for a high creation rate of `taskkill`, `conhost`, Git helpers, or shells together with WMI Provider Host, Defender, or DWM CPU. Correlate timestamps with repeated Git review-summary cancellation, stale-snapshot messages, or file generation inside a worktree.

Do not blame long-lived `0% CPU` processes for current CPU usage without delta evidence. Short-lived process creation and security/WMI inspection can consume CPU while each individual helper disappears too quickly for Task Manager to display clearly.

Contain the storm in this order:

1. Stop or let finish only the triggering review/generation operation when it is within the current authorized task.
2. Do not modify another project's files or workflow. Report the exact active task and operation if it is outside the current task.
3. For an inactive task with a uniquely mapped runtime root, use the verified cleanup flow below.
4. If the storm is inside the shared app-server and no leaf root is uniquely attributable, preserve all PIDs and offer a full Codex restart after the user saves work and approves it.

Project-level mitigations such as ignoring generated directories, moving volatile environments outside a repository, or serializing generation and Git review require explicit authorization for that project.

#### Retained runtime buildup

Group Node/MCP/CLI/CMD processes by their actual parent tree and stable command signature. Count accumulation, memory, handles, listeners, and sampled activity.

Clean only a uniquely attributed stale root. Never subtract the number of active tasks from the number of runtime groups and kill the oldest remainder. A shared generic MCP group without a unique owner remains `UNKNOWN`; the safe reset is an approved full app restart, not selective guessing.

### 5. Build and execute an identity-locked cleanup manifest

Only after the user selects one-time repair, create a manifest for each verified stale root. Supply two or more concise, sanitized evidence statements and every known active/protected PID:

```powershell
$Manifest = Join-Path $RunRoot 'cleanup-manifest.json'

& powershell -NoProfile -ExecutionPolicy Bypass `
  -File $ManifestBuilder `
  -SnapshotPath $Snapshot `
  -RootProcessId 12345 `
  -ProtectedProcessId 111,222 `
  -Evidence 'Exact task marker maps to an inactive task','No active task shares this runtime root' `
  -OutputPath $Manifest
```

Preview first:

```powershell
& powershell -NoProfile -ExecutionPolicy Bypass `
  -File $Executor `
  -ManifestPath $Manifest
```

Only after the preview matches the stale group, execute:

```powershell
& powershell -NoProfile -ExecutionPolicy Bypass `
  -File $Executor `
  -ManifestPath $Manifest -Execute
```

The executor revalidates PID, start time, image, command-line hash, protected identities, and process-tree shape. It aborts on PID reuse, tree drift, missing identity data, protected membership, or a forbidden core/system process. Do not bypass these refusals. Use `-Force` only when a verified stale member survives the normal termination attempt and the user explicitly asks to force it.

### 6. Verify and report

After each batch:

1. Capture a fresh 10–15 second snapshot.
2. Confirm all protected/active roots still exist.
3. Compare process churn, sampled CPU, WMI/Defender/DWM pressure, memory, handles, and perceived UI latency.
4. Wait for security/WMI pressure to settle before declaring failure; report the observation window.
5. Delete private raw-command snapshots unless the user asks to retain them.
6. On a manual repair run, check monitor status and apply the post-repair decision gate.

Report:

- what was observed before cleanup;
- the correlated triggering task/operation, or `not uniquely identified`;
- exact stale roots removed and the proofs used;
- active and unknown groups deliberately preserved;
- before/after measurements;
- residual risk and the safest next action.

For public evidence, replace usernames, paths, project names, task IDs, PIDs, ports, prompt text, and tokens with placeholders. Keep product/OS versions, aggregate counts, timing, role names, and non-reversible hashes only when useful.
