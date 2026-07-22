#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [switch]$Execute,
    [switch]$Force,

    [ValidateRange(1, 5)]
    [int]$MaxRoots = 5,

    [ValidateRange(1, 100)]
    [int]$MaxMembers = 50,

    [ValidateRange(0, 30)]
    [int]$GraceSeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-Sha256 {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $null
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Normalize-ImageName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    return ([IO.Path]::GetFileNameWithoutExtension($Name)).ToLowerInvariant()
}

function Get-ExpectedDepth {
    param(
        [int]$ProcessId,
        [hashtable]$ExpectedByPid
    )

    $depth = 0
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $cursor = $ProcessId
    while ($ExpectedByPid.ContainsKey([string]$cursor) -and $seen.Add($cursor)) {
        $parent = $ExpectedByPid[[string]$cursor].ParentProcessId
        if ($null -eq $parent -or -not $ExpectedByPid.ContainsKey([string][int]$parent)) {
            break
        }
        $depth++
        $cursor = [int]$parent
    }
    return $depth
}

$manifestFullPath = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) {
    throw "Manifest not found: $manifestFullPath"
}

$manifest = Get-Content -Raw -LiteralPath $manifestFullPath | ConvertFrom-Json
if ([int]$manifest.SchemaVersion -ne 1) {
    throw "Unsupported manifest schema version: $($manifest.SchemaVersion)"
}
if ([string]$manifest.Classification -cne "STALE") {
    throw "Manifest classification must be exactly STALE."
}

$evidence = @($manifest.Evidence | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
if ($evidence.Count -lt 2) {
    throw "Manifest must contain at least two distinct stale-evidence codes."
}
$allowedEvidenceCodes = @(
    "inactive-task-marker",
    "inactive-workspace-only",
    "task-close-before-runtime",
    "orphaned-supervisor-no-client",
    "runtime-release-record"
)
$ownershipEvidenceCodes = @(
    "inactive-task-marker",
    "inactive-workspace-only",
    "task-close-before-runtime",
    "runtime-release-record"
)
if (@($evidence | Where-Object { $allowedEvidenceCodes -notcontains $_ }).Count -gt 0) {
    throw "Manifest contains an unsupported stale-evidence code."
}
if (@($evidence | Where-Object { $ownershipEvidenceCodes -contains $_ }).Count -lt 1) {
    throw "Manifest lacks an evidence code that establishes task or runtime ownership."
}

$rootIds = @($manifest.RootProcessIds | ForEach-Object { [int]$_ } | Sort-Object -Unique)
$members = @($manifest.Members)
if ($rootIds.Count -lt 1 -or $rootIds.Count -gt $MaxRoots) {
    throw "Manifest contains $($rootIds.Count) roots; allowed range is 1..$MaxRoots."
}
if ($members.Count -lt 1 -or $members.Count -gt $MaxMembers) {
    throw "Manifest contains $($members.Count) members; allowed range is 1..$MaxMembers."
}

$expectedByPid = @{}
foreach ($member in $members) {
    $pidKey = [string][int]$member.ProcessId
    if ($expectedByPid.ContainsKey($pidKey)) {
        throw "Manifest contains duplicate PID: $pidKey"
    }
    if ([string]::IsNullOrWhiteSpace([string]$member.StartTimeUtc) -or [string]::IsNullOrWhiteSpace([string]$member.CommandLineSha256)) {
        throw "Manifest member PID $pidKey lacks start time or command-line hash."
    }
    $expectedByPid[$pidKey] = $member
}
foreach ($rootId in $rootIds) {
    if (-not $expectedByPid.ContainsKey([string]$rootId)) {
        throw "Root PID $rootId is not present in Members."
    }
}

$expectedChildrenByParent = @{}
foreach ($member in $members) {
    if ($null -eq $member.ParentProcessId) { continue }
    $parentKey = [string][int]$member.ParentProcessId
    if (-not $expectedChildrenByParent.ContainsKey($parentKey)) {
        $expectedChildrenByParent[$parentKey] = New-Object 'System.Collections.Generic.List[int]'
    }
    $expectedChildrenByParent[$parentKey].Add([int]$member.ProcessId)
}

$liveRows = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate -ErrorAction Stop)
$liveByPid = @{}
$childrenByParent = @{}
foreach ($row in $liveRows) {
    $pidKey = [string][int]$row.ProcessId
    $liveByPid[$pidKey] = $row
    $parentKey = [string][int]$row.ParentProcessId
    if (-not $childrenByParent.ContainsKey($parentKey)) {
        $childrenByParent[$parentKey] = New-Object 'System.Collections.Generic.List[int]'
    }
    $childrenByParent[$parentKey].Add([int]$row.ProcessId)
}

$protectedIds = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($protectedId in @($manifest.ProtectedProcessIds)) {
    if ([int]$protectedId -gt 0) {
        [void]$protectedIds.Add([int]$protectedId)
    }
}

# Protect this executor and all of its ancestors regardless of manifest contents.
$cursor = [int]$PID
while ($cursor -gt 0 -and $protectedIds.Add($cursor)) {
    $cursorKey = [string]$cursor
    if (-not $liveByPid.ContainsKey($cursorKey)) { break }
    $next = [int]$liveByPid[$cursorKey].ParentProcessId
    if ($next -eq $cursor) { break }
    $cursor = $next
}

$forbiddenNames = @(
    "codex", "chatgpt", "openai.codex", "wmiprvse", "msmpeng", "dwm",
    "system", "idle", "explorer", "svchost", "services", "lsass",
    "wininit", "winlogon", "csrss", "smss", "taskmgr"
)

$identityErrors = New-Object 'System.Collections.Generic.List[string]'
$presentTargetIds = New-Object 'System.Collections.Generic.HashSet[int]'
$missingTargetIds = New-Object 'System.Collections.Generic.List[int]'

foreach ($pidKey in $expectedByPid.Keys) {
    $expected = $expectedByPid[$pidKey]
    $processId = [int]$expected.ProcessId
    if (-not $liveByPid.ContainsKey($pidKey)) {
        $missingTargetIds.Add($processId)
        continue
    }

    [void]$presentTargetIds.Add($processId)
    $live = $liveByPid[$pidKey]
    $expectedName = Normalize-ImageName -Name ([string]$expected.ImageName)
    $liveName = Normalize-ImageName -Name ([string]$live.Name)

    if ($forbiddenNames -contains $liveName) {
        $identityErrors.Add("PID $processId is a forbidden core/system image: $($live.Name)")
    }
    if ($protectedIds.Contains($processId)) {
        $identityErrors.Add("PID $processId is protected by the active-task/current-process set")
    }
    if ($expectedName -ne $liveName) {
        $identityErrors.Add("PID $processId image changed from $expectedName to $liveName")
    }

    $expectedStart = ([datetime][string]$expected.StartTimeUtc).ToUniversalTime()
    $liveStart = ([datetime]$live.CreationDate).ToUniversalTime()
    if ([Math]::Abs(($liveStart - $expectedStart).TotalSeconds) -gt 2.0) {
        $identityErrors.Add("PID $processId start time changed (possible PID reuse)")
    }

    $liveHash = Get-Sha256 -Text ([string]$live.CommandLine)
    if (-not [string]::Equals($liveHash, [string]$expected.CommandLineSha256, [StringComparison]::OrdinalIgnoreCase)) {
        $identityErrors.Add("PID $processId command-line hash changed")
    }

    if ($null -ne $expected.ParentProcessId -and [int]$expected.ParentProcessId -ne [int]$live.ParentProcessId) {
        $identityErrors.Add("PID $processId parent changed from $($expected.ParentProcessId) to $($live.ParentProcessId)")
    }
}

# Reconstruct every live descendant. A new child means the tree changed after classification.
$treeDriftIds = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($rootId in $rootIds) {
    if (-not $liveByPid.ContainsKey([string]$rootId)) {
        $expectedTree = New-Object 'System.Collections.Generic.HashSet[int]'
        $expectedQueue = New-Object 'System.Collections.Generic.Queue[int]'
        $expectedQueue.Enqueue($rootId)
        while ($expectedQueue.Count -gt 0) {
            $expectedId = $expectedQueue.Dequeue()
            if (-not $expectedTree.Add($expectedId)) { continue }
            $expectedKey = [string]$expectedId
            if ($expectedChildrenByParent.ContainsKey($expectedKey)) {
                foreach ($expectedChildId in $expectedChildrenByParent[$expectedKey]) {
                    $expectedQueue.Enqueue([int]$expectedChildId)
                }
            }
        }
        $orphanedExpected = @($presentTargetIds | Where-Object { $expectedTree.Contains([int]$_) })
        if ($orphanedExpected.Count -gt 0) {
            $identityErrors.Add("Root PID $rootId exited while expected members remain; ownership is no longer stable")
        }
        continue
    }

    $queue = New-Object 'System.Collections.Generic.Queue[int]'
    $visited = New-Object 'System.Collections.Generic.HashSet[int]'
    $queue.Enqueue($rootId)
    while ($queue.Count -gt 0) {
        $currentId = $queue.Dequeue()
        if (-not $visited.Add($currentId)) { continue }
        if (-not $expectedByPid.ContainsKey([string]$currentId)) {
            [void]$treeDriftIds.Add($currentId)
        }
        $childKey = [string]$currentId
        if ($childrenByParent.ContainsKey($childKey)) {
            foreach ($childId in $childrenByParent[$childKey]) {
                $queue.Enqueue([int]$childId)
            }
        }
    }
}

if ($treeDriftIds.Count -gt 0) {
    $identityErrors.Add("Tree drift detected; unmanifested descendant PIDs: $(@($treeDriftIds | Sort-Object) -join ',')")
}
if ($identityErrors.Count -gt 0) {
    throw ("Cleanup refused:`n- " + ($identityErrors -join "`n- "))
}

$planRows = foreach ($processId in @($presentTargetIds)) {
    $expected = $expectedByPid[[string]$processId]
    [pscustomobject][ordered]@{
        ProcessId       = $processId
        ParentProcessId = $expected.ParentProcessId
        ImageName       = $expected.ImageName
        RoleHint        = $expected.RoleHint
        Depth           = Get-ExpectedDepth -ProcessId $processId -ExpectedByPid $expectedByPid
    }
}
$planRows = @($planRows | Sort-Object -Property @{ Expression = "Depth"; Descending = $true }, @{ Expression = "ProcessId"; Descending = $false })

[pscustomobject][ordered]@{
    RecordType       = "CleanupSummary"
    Mode             = if ($Execute.IsPresent) { "Execute" } else { "Preview" }
    ManifestPath     = $manifestFullPath
    RootCount        = $rootIds.Count
    PresentTargets   = $planRows.Count
    AlreadyExited    = $missingTargetIds.Count
    EvidenceCount    = $evidence.Count
    ForceRequested   = $Force.IsPresent
}
$planRows | ForEach-Object {
    [pscustomobject][ordered]@{
        RecordType       = "CleanupTarget"
        ProcessId       = $_.ProcessId
        ParentProcessId = $_.ParentProcessId
        ImageName       = $_.ImageName
        RoleHint        = $_.RoleHint
        Depth           = $_.Depth
    }
}

if (-not $Execute.IsPresent) {
    Write-Host "Preview only. No process was stopped. Re-run with -Execute only after checking every target."
    return
}

# Ask windowed processes to close first. Console runtimes normally have no main window.
$closeRequested = $false
foreach ($target in $planRows) {
    try {
        $process = Get-Process -Id $target.ProcessId -ErrorAction Stop
        if ($process.MainWindowHandle -ne 0 -and $process.CloseMainWindow()) {
            $closeRequested = $true
        }
    }
    catch {
        # The process may have exited between validation and this optional close request.
    }
}

if ($closeRequested -and $GraceSeconds -gt 0) {
    $deadline = [DateTime]::UtcNow.AddSeconds($GraceSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $stillOpen = @($planRows | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
        if ($stillOpen.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }
}

$results = New-Object 'System.Collections.Generic.List[object]'
foreach ($target in $planRows) {
    $expected = $expectedByPid[[string]$target.ProcessId]
    $process = Get-Process -Id $target.ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        $results.Add([pscustomobject][ordered]@{ ProcessId = $target.ProcessId; ImageName = $target.ImageName; Result = "AlreadyExited"; Error = $null })
        continue
    }

    try {
        $actualStartUtc = $process.StartTime.ToUniversalTime()
        $expectedStartUtc = ([datetime][string]$expected.StartTimeUtc).ToUniversalTime()
        if ([Math]::Abs(($actualStartUtc - $expectedStartUtc).TotalSeconds) -gt 2.0) {
            throw "Start time changed immediately before termination"
        }

        if ($Force.IsPresent) {
            Stop-Process -Id $target.ProcessId -Force -Confirm:$false -ErrorAction Stop
        }
        else {
            Stop-Process -Id $target.ProcessId -Confirm:$false -ErrorAction Stop
        }
        $results.Add([pscustomobject][ordered]@{ ProcessId = $target.ProcessId; ImageName = $target.ImageName; Result = "StopRequested"; Error = $null })
    }
    catch {
        $results.Add([pscustomobject][ordered]@{ ProcessId = $target.ProcessId; ImageName = $target.ImageName; Result = "Failed"; Error = $_.Exception.Message })
    }
}

Start-Sleep -Milliseconds 750
foreach ($result in $results) {
    if ($result.Result -eq "StopRequested") {
        if ($null -eq (Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue)) {
            $result.Result = "Stopped"
        }
        else {
            $result.Result = "StillRunning"
        }
    }
    [pscustomobject][ordered]@{
        RecordType = "CleanupResult"
        ProcessId  = $result.ProcessId
        ImageName  = $result.ImageName
        Result     = $result.Result
        Error      = $result.Error
    }
}

$failures = @($results | Where-Object { $_.Result -in @("Failed", "StillRunning") })
if ($failures.Count -gt 0) {
    throw "$($failures.Count) verified target(s) were not stopped. Do not broaden the target set; inspect the reported failures."
}
