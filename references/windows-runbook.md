# Windows diagnosis and mitigation runbook

Use this reference for deeper triage after reading the safety contract in `SKILL.md`.

## Contents

1. Signal model
2. Active-task ownership
3. Snapshot interpretation
4. Cleanup-churn investigation
5. Retained-runtime investigation
6. Mitigation matrix
7. Verification and redaction

## 1. Signal model

Separate three kinds of evidence:

- **Observed:** measurements, process starts/exits, logs, task state, parent-child relationships.
- **Correlated:** events close enough in time and identity to plausibly share a cause.
- **Inferred:** the proposed mechanism. Label it and state what evidence would falsify it.

A Task Manager row showing `0% CPU` is a rounded instantaneous sample. It does not prove that a process has never used CPU, but a large set of idle processes is not automatically the cause of high CPU. Distinguish:

- **Steady load:** one or more long-lived processes accumulate CPU continuously.
- **Churn load:** many helpers start and exit rapidly; WMI and endpoint security inspect each lifecycle event.
- **Resource buildup:** retained processes add memory, handles, timers, pipes, sockets, and future inspection work even while momentarily idle.

The two bugs can amplify each other: retained runtimes enlarge the process surface, while repeated cancellation creates a high-rate lifecycle storm.

## 2. Active-task ownership

Prefer product/task state over OS heuristics.

Treat these task states as active or protected:

- the current task;
- a task with a running tool call or shell;
- waiting/needs-attention tasks whose turn has not completed;
- tasks explicitly protected by the user;
- tasks whose state cannot be read;
- tasks sharing a runtime that cannot be split by exact identity.

Treat a task as inactive only when completion/archive/close state is explicit and no tool call remains live. A task can be visually quiet while a background operation continues.

Ownership evidence, strongest first:

1. exact task/thread/host identifier in a runtime registry, log entry, command, or environment-derived diagnostic;
2. exact process root recorded by the task lifecycle;
3. unique workspace path that no active task shares;
4. start/stop timestamps plus a unique command signature;
5. parent-tree position and activity alone.

Items 4 and 5 do not establish ownership by themselves. Generic MCP commands under one shared app-server are ambiguous unless another source maps them.

Never direct another task to change its workflow as part of diagnosis. Report the task token and operation to the user instead.

## 3. Snapshot interpretation

`collect-runtime.ps1` samples cumulative process CPU and computes normalized CPU deltas:

```text
CPU percent = CPU-seconds delta / wall-seconds / logical-processor-count × 100
```

Important fields:

| Field | Interpretation |
|---|---|
| `CpuPercentAverage` | Average normalized CPU while the process was observed |
| `CpuPercentPeak` | Highest sampled interval, not an ETW-grade peak |
| `StartsSeen` / `ExitsSeen` | Helpers caught by polling; very short events may be missed |
| `ParentProcessId` | One bounded CIM snapshot; null when unavailable |
| `CommandLineSha256` | Exact local identity without publishing raw arguments |
| `RoleHint` | Name/argument heuristic, never ownership proof |
| `TcpStateCounts` | Optional connection-state counts without addresses |

If `CimAvailable` is false, the snapshot cannot safely drive cleanup because parent and command identity are incomplete. Use it only to diagnose pressure.

Sampling limitations:

- polling can miss helpers that live for less than the sample interval;
- kernel, interrupt, GPU, storage latency, and memory compression may not appear as user-process CPU;
- Defender or WMI may remain elevated briefly after the original caller stops;
- process IDs can be reused, which is why cleanup also checks start time and command hash.

## 4. Cleanup-churn investigation

### Fast pattern

Suspect a cleanup storm when several of these align:

- Task Manager shows WMI Provider Host, Defender, DWM, or the Codex UI consuming CPU;
- the snapshot catches repeated starts/exits of `taskkill`, `conhost`, Git, CMD, PowerShell, or Node helpers;
- product logs repeatedly mention an aborted review summary, stale snapshot, cancellation, or descendant cleanup;
- a task is generating or deleting many files while Git review/status logic runs;
- load falls sharply when the operation or Codex app exits.

### Correlate without exposing prompts

Resolve the Codex data root from `CODEX_HOME` when set; otherwise use the normal per-user Codex data directory. Search only likely log/session files and restrict matches:

```powershell
rg -n -i --glob '*.log' --glob '*.jsonl' `
  'review-summary.*abort|stale snapshot|taskkill|cleanup.*process|mcp.*exit' `
  <CODEX_DATA_ROOT>
```

Record timestamps, task tokens, operation type, and counts. Do not copy prompt bodies, environment values, authentication material, or full command lines into a public report.

Inspect a suspected worktree only when that project is within scope. Prefer one bounded check over a watcher loop. Large generated or untracked trees are a trigger clue, not proof of a Codex bug by themselves.

### Capture short-lived helpers with WPR

Use Windows Performance Recorder only when polling cannot prove churn and the user accepts a trace that may contain local paths. Administrator rights may be required.

```powershell
wpr.exe -start GeneralProfile -filemode
# Reproduce for 20–30 seconds.
wpr.exe -stop .\fix-codex-lag.etl
```

Do not run repeated WMI queries while capturing. Keep the ETL private unless it is reviewed and sanitized; binary ETL files are not safely redacted by search-and-replace.

### Immediate containment

- If the trigger is the current authorized operation, cancel or serialize that operation and let file changes settle before requesting one final Git/review pass.
- If another active task is the trigger, preserve it and report the task token and operation. Let the user decide whether to pause it.
- If an inactive task owns a unique runtime root, use the identity-locked manifest flow.
- If cancellation occurs inside the shared app-server and no leaf ownership exists, a full app restart is safer than PID guessing. Obtain user approval first.

## 5. Retained-runtime investigation

### Build groups

Construct parent trees from the snapshot. Useful runtime signatures include:

- task shell → CLI → Node child;
- Node launcher → MCP server;
- `node_repl` → Node runtime;
- CMD/PowerShell → package runner → Node;
- shared app-server → repeated similar MCP clusters.

Record for each group:

- root PID identity tuple;
- parent outside the group;
- normalized command signature/hash;
- start time range;
- CPU delta, memory, handles, and TCP states;
- exact task ownership evidence;
- active/inactive/unknown classification.

### Do not use count arithmetic as ownership

Examples of invalid cleanup logic:

- “There are 20 Node groups and 5 active tasks, so kill the oldest 15.”
- “This process is at 0% CPU, so it is unused.”
- “All copies of this MCP command are redundant.”
- “Its parent is Codex, so it belongs to the current task.”

Counts can establish accumulation and support a bug report. They cannot identify which group is safe to terminate.

### Verified stale group

A group is eligible only when:

1. its ownership is unique;
2. its owner is explicitly inactive;
3. no member is protected or shared;
4. at least two independent evidence statements are recorded;
5. the snapshot contains start time and command hash for every member;
6. the preview shows exactly the intended tree;
7. the live tree has not changed since the manifest was built.

If any condition fails, keep the group as `UNKNOWN`.

## 6. Mitigation matrix

| Situation | Temporary action | Forbidden shortcut |
|---|---|---|
| Unique stale leaf group | Preview and execute identity-locked manifest | Kill all Node/CMD by name |
| Generic clusters under shared app-server | Preserve; offer approved full app restart | Kill oldest/excess clusters |
| Active task causes Git/cancellation churn | Report exact operation; pause only with user authority | Instruct the other task to redesign its work |
| Inactive task causes unique churn | Stop verified stale tree, then resample | Kill WMI/Defender/DWM |
| Generated tree triggers repeated review | Propose ignore/move/serialize mitigation within project scope | Modify another project silently |
| CIM metadata unavailable | Diagnose only; retry after WMI settles | Execute from PID/name alone |
| CPU drops but stutter remains | Inspect churn, handles, storage/GPU latency, and UI thread pressure | Assume low average CPU means healthy |

## 7. Verification and redaction

Verify over two windows when practical:

1. 10–15 seconds immediately after cleanup;
2. another 10–15 seconds after WMI/Defender has had time to settle.

Compare:

- total starts/exits and top churn names;
- Node/MCP/CLI/CMD group count by classification;
- sampled CPU for Codex, WMI, Defender, DWM, Git, and helpers;
- working set and handle totals;
- active task availability;
- user-visible input, window, and terminal latency.

Use placeholders in shared reports:

```text
<USER>
<WORKSPACE-A>
<TASK-A>
<PID-A>
<PORT-A>
<PATH>
```

Remove raw command lines, prompts, file names, access tokens, environment values, private repository names, and absolute paths. Aggregate counts and durations. A SHA-256 command-line hash is useful for local identity but should still be omitted if it could act as a cross-report fingerprint without diagnostic value.
