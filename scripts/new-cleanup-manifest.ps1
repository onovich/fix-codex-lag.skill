#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotPath,

    [Parameter(Mandatory = $true)]
    [ValidateCount(1, 5)]
    [int[]]$RootProcessId,

    [int[]]$ProtectedProcessId = @(),

    [Parameter(Mandatory = $true)]
    [ValidateCount(2, 10)]
    [string[]]$Evidence,

    [string]$OutputPath = (Join-Path (Get-Location) ("cleanup-manifest-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss")))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-ImageName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    return ([IO.Path]::GetFileNameWithoutExtension($Name)).ToLowerInvariant()
}

$snapshotFullPath = [IO.Path]::GetFullPath($SnapshotPath)
if (-not (Test-Path -LiteralPath $snapshotFullPath -PathType Leaf)) {
    throw "Snapshot not found: $snapshotFullPath"
}

$snapshot = Get-Content -Raw -LiteralPath $snapshotFullPath | ConvertFrom-Json
if ([int]$snapshot.SchemaVersion -ne 1) {
    throw "Unsupported snapshot schema version: $($snapshot.SchemaVersion)"
}
if (-not [bool]$snapshot.CimAvailable) {
    throw "The snapshot has no bounded CIM metadata. It cannot be used for cleanup."
}

$cleanEvidence = @($Evidence | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
if ($cleanEvidence.Count -lt 2) {
    throw "Provide at least two distinct evidence statements."
}

$runningByPid = @{}
foreach ($process in @($snapshot.Processes | Where-Object { [bool]$_.IsRunningAtEnd })) {
    $pidKey = [string][int]$process.ProcessId
    if ($runningByPid.ContainsKey($pidKey)) {
        throw "Snapshot contains duplicate running PID identity: $pidKey"
    }
    $runningByPid[$pidKey] = $process
}

$rootIds = @($RootProcessId | Sort-Object -Unique)
$protectedIds = @($ProtectedProcessId | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
$forbiddenRootNames = @(
    "codex", "chatgpt", "openai.codex", "wmiprvse", "msmpeng", "dwm",
    "system", "idle", "explorer", "svchost", "services", "lsass",
    "wininit", "winlogon", "csrss", "smss", "taskmgr"
)

$memberIds = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($rootId in $rootIds) {
    $rootKey = [string]$rootId
    if (-not $runningByPid.ContainsKey($rootKey)) {
        throw "Root PID $rootId was not running at the end of the snapshot. Collect a fresh snapshot."
    }

    $root = $runningByPid[$rootKey]
    if ($forbiddenRootNames -contains (Normalize-ImageName -Name ([string]$root.ImageName))) {
        throw "Root PID $rootId is a protected core/system image: $($root.ImageName)"
    }

    $queue = New-Object 'System.Collections.Generic.Queue[int]'
    $queue.Enqueue($rootId)
    while ($queue.Count -gt 0) {
        $currentId = $queue.Dequeue()
        if (-not $memberIds.Add($currentId)) {
            continue
        }
        foreach ($child in @($runningByPid.Values | Where-Object { $null -ne $_.ParentProcessId -and [int]$_.ParentProcessId -eq $currentId })) {
            $queue.Enqueue([int]$child.ProcessId)
        }
    }
}

foreach ($protectedId in $protectedIds) {
    if ($memberIds.Contains($protectedId)) {
        throw "Protected PID $protectedId is inside the proposed stale tree. Reclassify the group as ACTIVE or UNKNOWN."
    }
}

$members = foreach ($memberId in @($memberIds | Sort-Object)) {
    $process = $runningByPid[[string]$memberId]
    if ([string]::IsNullOrWhiteSpace([string]$process.StartTimeUtc)) {
        throw "PID $memberId has no start-time identity."
    }
    if ([string]::IsNullOrWhiteSpace([string]$process.CommandLineSha256)) {
        throw "PID $memberId has no command-line hash. Collect a fresh snapshot after CIM recovers."
    }

    [pscustomobject][ordered]@{
        ProcessId         = [int]$process.ProcessId
        ParentProcessId   = if ($null -ne $process.ParentProcessId) { [int]$process.ParentProcessId } else { $null }
        ImageName         = [string]$process.ImageName
        StartTimeUtc      = [string]$process.StartTimeUtc
        CommandLineSha256 = [string]$process.CommandLineSha256
        RoleHint          = [string]$process.RoleHint
    }
}

$manifest = [pscustomobject][ordered]@{
    SchemaVersion       = 1
    Classification      = "STALE"
    CreatedAtUtc        = [DateTime]::UtcNow.ToString("o")
    SnapshotCollectedAt = [string]$snapshot.CollectedAtUtc
    Scope               = "Only these exact members; abort on identity or tree drift"
    RootProcessIds      = $rootIds
    ProtectedProcessIds = $protectedIds
    Evidence            = $cleanEvidence
    Members             = @($members)
}

$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
if ([string]::Equals($fullOutputPath, $snapshotFullPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must not overwrite the snapshot."
}

$parentDirectory = Split-Path -Parent $fullOutputPath
if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
}

$json = $manifest | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($fullOutputPath, $json, [Text.UTF8Encoding]::new($false))

[pscustomobject][ordered]@{
    OutputPath           = $fullOutputPath
    Classification       = $manifest.Classification
    RootProcessIds       = ($rootIds -join ",")
    MemberCount          = $manifest.Members.Count
    ProtectedProcessIds  = ($protectedIds -join ",")
    EvidenceCount        = $cleanEvidence.Count
}
