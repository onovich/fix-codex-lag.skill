#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateRange(2, 120)]
    [int]$DurationSeconds = 12,

    [ValidateRange(100, 5000)]
    [int]$SampleMilliseconds = 250,

    [string]$OutputPath = (Join-Path ([IO.Path]::GetTempPath()) ("runtime-snapshot-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [switch]$IncludeCommandLine,
    [switch]$IncludeNetwork,
    [switch]$NoRedact,
    [switch]$SkipCim
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "protect-sensitive-text.ps1")

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

function Redact-Text {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text -or $NoRedact.IsPresent) {
        return $Text
    }

    return Protect-SensitiveText -Text $Text -CurrentDirectory (Get-Location).Path
}

function Get-SafeValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Property,
        $Default = $null
    )

    try {
        $value = $Object.$Property
        if ($null -eq $value) {
            return $Default
        }
        return $value
    }
    catch {
        return $Default
    }
}

function Read-ProcessSample {
    $map = @{}
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        $startUtc = $null
        try {
            $startUtc = $process.StartTime.ToUniversalTime()
        }
        catch {
            # Some protected system processes do not expose StartTime.
        }

        $cpuSeconds = [double](Get-SafeValue -Object $process -Property "CPU" -Default 0.0)
        $identitySuffix = if ($null -ne $startUtc) { $startUtc.Ticks } else { $process.ProcessName }
        $identity = "{0}|{1}" -f $process.Id, $identitySuffix

        $threadCount = 0
        try { $threadCount = $process.Threads.Count } catch { }

        $map[$identity] = [pscustomobject][ordered]@{
            Identity         = $identity
            ProcessId        = [int]$process.Id
            ImageName        = [string]$process.ProcessName
            StartTimeUtc     = $startUtc
            CpuSeconds       = $cpuSeconds
            WorkingSetBytes  = [int64](Get-SafeValue -Object $process -Property "WorkingSet64" -Default 0)
            PrivateBytes     = [int64](Get-SafeValue -Object $process -Property "PrivateMemorySize64" -Default 0)
            HandleCount      = [int](Get-SafeValue -Object $process -Property "HandleCount" -Default 0)
            ThreadCount      = [int]$threadCount
        }
    }
    return $map
}

function New-StatsRecord {
    param($Item, [datetime]$AtUtc)

    return [pscustomobject][ordered]@{
        Identity              = $Item.Identity
        ProcessId             = $Item.ProcessId
        ImageName             = $Item.ImageName
        StartTimeUtc          = $Item.StartTimeUtc
        FirstSeenUtc          = $AtUtc
        LastSeenUtc           = $AtUtc
        SeenSamples           = 1
        CpuSecondsObserved    = 0.0
        ActiveWallSeconds     = 0.0
        CpuPercentPeak        = 0.0
        CpuPercentLast        = 0.0
        WorkingSetBytes       = $Item.WorkingSetBytes
        PrivateBytes          = $Item.PrivateBytes
        HandleCount           = $Item.HandleCount
        ThreadCount           = $Item.ThreadCount
        ExitSeen              = $false
        RunningAtEnd          = $false
    }
}

function Add-Count {
    param([hashtable]$Table, [string]$Key)

    if ($Table.ContainsKey($Key)) {
        $Table[$Key] = [int]$Table[$Key] + 1
    }
    else {
        $Table[$Key] = 1
    }
}

function Get-RoleHint {
    param([string]$ImageName, [AllowNull()][string]$CommandLine)

    $name = $ImageName.ToLowerInvariant()
    $command = if ($null -eq $CommandLine) { "" } else { $CommandLine.ToLowerInvariant() }

    if ($name -match '^(codex|chatgpt|openai\.codex)$') { return "CodexCore" }
    if ($name -eq 'node_repl' -or $command -match '(?:^|[\\/\s])(mcp|server\.mjs|start-mcp\.mjs)(?:[\\/\s]|$)') { return "McpRuntime" }
    if ($name -eq 'node') { return "NodeRuntime" }
    if ($name -match '^(cmd|conhost|powershell|pwsh)$') { return "ShellHelper" }
    if ($name -match '^git(?:-.*)?$') { return "GitHelper" }
    if ($name -eq 'taskkill') { return "CleanupHelper" }
    if ($name -match '^(wmiprvse|msmpeng|dwm)$') { return "SystemPressure" }
    return "Other"
}

$logicalProcessors = [Math]::Max(1, [Environment]::ProcessorCount)
$startedAtUtc = [DateTime]::UtcNow
$previousAtUtc = $startedAtUtc
$previous = Read-ProcessSample
$allStats = @{}
$startsByName = @{}
$exitsByName = @{}
$totalStartsSeen = 0
$totalExitsSeen = 0

foreach ($item in $previous.Values) {
    $allStats[$item.Identity] = New-StatsRecord -Item $item -AtUtc $startedAtUtc
}

$iterations = [Math]::Max(1, [int][Math]::Ceiling(($DurationSeconds * 1000.0) / $SampleMilliseconds))

for ($index = 0; $index -lt $iterations; $index++) {
    Start-Sleep -Milliseconds $SampleMilliseconds
    $nowUtc = [DateTime]::UtcNow
    $elapsedSeconds = [Math]::Max(0.001, ($nowUtc - $previousAtUtc).TotalSeconds)
    $current = Read-ProcessSample

    foreach ($item in $current.Values) {
        if (-not $allStats.ContainsKey($item.Identity)) {
            $allStats[$item.Identity] = New-StatsRecord -Item $item -AtUtc $nowUtc
            $totalStartsSeen++
            Add-Count -Table $startsByName -Key $item.ImageName
        }

        $stats = $allStats[$item.Identity]
        $stats.SeenSamples++
        $stats.LastSeenUtc = $nowUtc
        $stats.WorkingSetBytes = $item.WorkingSetBytes
        $stats.PrivateBytes = $item.PrivateBytes
        $stats.HandleCount = $item.HandleCount
        $stats.ThreadCount = $item.ThreadCount

        if ($previous.ContainsKey($item.Identity)) {
            $deltaCpu = [Math]::Max(0.0, $item.CpuSeconds - $previous[$item.Identity].CpuSeconds)
            $cpuPercent = ($deltaCpu / $elapsedSeconds / $logicalProcessors) * 100.0
            $stats.CpuSecondsObserved += $deltaCpu
            $stats.ActiveWallSeconds += $elapsedSeconds
            $stats.CpuPercentLast = $cpuPercent
            if ($cpuPercent -gt $stats.CpuPercentPeak) {
                $stats.CpuPercentPeak = $cpuPercent
            }
        }
    }

    foreach ($item in $previous.Values) {
        if (-not $current.ContainsKey($item.Identity)) {
            $stats = $allStats[$item.Identity]
            if (-not $stats.ExitSeen) {
                $stats.ExitSeen = $true
                $totalExitsSeen++
                Add-Count -Table $exitsByName -Key $item.ImageName
            }
        }
    }

    $previous = $current
    $previousAtUtc = $nowUtc
}

$endedAtUtc = [DateTime]::UtcNow
foreach ($key in $previous.Keys) {
    if ($allStats.ContainsKey($key)) {
        $allStats[$key].RunningAtEnd = $true
    }
}

$cimAvailable = $false
$cimError = $null
$cimByPid = @{}
if (-not $SkipCim.IsPresent) {
    try {
        foreach ($row in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine, CreationDate -ErrorAction Stop)) {
            $cimByPid[[string][int]$row.ProcessId] = $row
        }
        $cimAvailable = $true
    }
    catch {
        $cimError = $_.Exception.Message
    }
}

$networkByPid = @{}
$networkAvailable = $false
$networkError = $null
if ($IncludeNetwork.IsPresent) {
    try {
        foreach ($connection in @(Get-NetTCPConnection -ErrorAction Stop)) {
            $pidKey = [string][int]$connection.OwningProcess
            if (-not $networkByPid.ContainsKey($pidKey)) {
                $networkByPid[$pidKey] = @{}
            }
            $state = [string]$connection.State
            if ($networkByPid[$pidKey].ContainsKey($state)) {
                $networkByPid[$pidKey][$state] = [int]$networkByPid[$pidKey][$state] + 1
            }
            else {
                $networkByPid[$pidKey][$state] = 1
            }
        }
        $networkAvailable = $true
    }
    catch {
        $networkError = $_.Exception.Message
    }
}

$processRows = foreach ($stats in $allStats.Values) {
    $cim = $null
    $pidKey = [string]$stats.ProcessId
    if ($stats.RunningAtEnd -and $cimByPid.ContainsKey($pidKey)) {
        $candidate = $cimByPid[$pidKey]
        $sameIdentity = $true
        if ($null -ne $stats.StartTimeUtc -and $null -ne $candidate.CreationDate) {
            $creationUtc = ([datetime]$candidate.CreationDate).ToUniversalTime()
            $sameIdentity = [Math]::Abs(($creationUtc - $stats.StartTimeUtc).TotalSeconds) -le 2.0
        }
        if ($sameIdentity) {
            $cim = $candidate
        }
    }

    $commandLine = if ($null -ne $cim) { [string]$cim.CommandLine } else { $null }
    $executablePath = if ($null -ne $cim) { [string]$cim.ExecutablePath } else { $null }
    $averageCpu = if ($stats.ActiveWallSeconds -gt 0) {
        ($stats.CpuSecondsObserved / $stats.ActiveWallSeconds / $logicalProcessors) * 100.0
    }
    else { 0.0 }

    $tcpStates = $null
    if ($networkByPid.ContainsKey($pidKey)) {
        $tcpStates = [pscustomobject]$networkByPid[$pidKey]
    }

    $row = [ordered]@{
        ProcessId            = $stats.ProcessId
        ParentProcessId      = if ($null -ne $cim) { [int]$cim.ParentProcessId } else { $null }
        ImageName            = $stats.ImageName
        RoleHint             = Get-RoleHint -ImageName $stats.ImageName -CommandLine $commandLine
        StartTimeUtc         = if ($null -ne $stats.StartTimeUtc) { $stats.StartTimeUtc.ToString("o") } else { $null }
        FirstSeenUtc         = $stats.FirstSeenUtc.ToString("o")
        LastSeenUtc          = $stats.LastSeenUtc.ToString("o")
        IsRunningAtEnd       = [bool]$stats.RunningAtEnd
        ExitSeen             = [bool]$stats.ExitSeen
        SeenSamples          = [int]$stats.SeenSamples
        CpuSecondsObserved   = [Math]::Round([double]$stats.CpuSecondsObserved, 6)
        CpuPercentAverage    = [Math]::Round([double]$averageCpu, 3)
        CpuPercentPeak       = [Math]::Round([double]$stats.CpuPercentPeak, 3)
        CpuPercentLast       = [Math]::Round([double]$stats.CpuPercentLast, 3)
        WorkingSetMB         = [Math]::Round($stats.WorkingSetBytes / 1MB, 2)
        PrivateMemoryMB      = [Math]::Round($stats.PrivateBytes / 1MB, 2)
        HandleCount          = [int]$stats.HandleCount
        ThreadCount          = [int]$stats.ThreadCount
        ExecutablePath       = Redact-Text -Text $executablePath
        CommandLineSha256    = Get-Sha256 -Text $commandLine
        TcpStateCounts       = $tcpStates
    }
    if ($IncludeCommandLine.IsPresent) {
        $row.CommandLine = Redact-Text -Text $commandLine
    }
    [pscustomobject]$row
}

$processRows = @($processRows | Sort-Object -Property @{ Expression = "CpuPercentAverage"; Descending = $true }, @{ Expression = "ProcessId"; Descending = $false })

$churnNames = @(@($startsByName.Keys) + @($exitsByName.Keys) | Sort-Object -Unique)
$churnRows = foreach ($name in $churnNames) {
    [pscustomobject][ordered]@{
        ImageName  = $name
        StartsSeen = if ($startsByName.ContainsKey($name)) { [int]$startsByName[$name] } else { 0 }
        ExitsSeen  = if ($exitsByName.ContainsKey($name)) { [int]$exitsByName[$name] } else { 0 }
    }
}
$churnRows = @($churnRows | Sort-Object -Property @{ Expression = { $_.StartsSeen + $_.ExitsSeen }; Descending = $true }, ImageName)

$runningRows = @($processRows | Where-Object { $_.IsRunningAtEnd })
$snapshot = [pscustomobject][ordered]@{
    SchemaVersion       = 1
    CollectedAtUtc      = $endedAtUtc.ToString("o")
    StartedAtUtc        = $startedAtUtc.ToString("o")
    DurationSeconds     = [Math]::Round(($endedAtUtc - $startedAtUtc).TotalSeconds, 3)
    SampleMilliseconds  = $SampleMilliseconds
    LogicalProcessors   = $logicalProcessors
    CollectorProcessId  = $PID
    CollectorCwd        = Redact-Text -Text (Get-Location).Path
    Redacted            = -not $NoRedact.IsPresent
    IncludesCommandLine = $IncludeCommandLine.IsPresent
    CimAvailable        = $cimAvailable
    CimError            = if ($NoRedact.IsPresent) { $cimError } else { Redact-Text -Text $cimError }
    NetworkAvailable    = $networkAvailable
    NetworkError        = if ($NoRedact.IsPresent) { $networkError } else { Redact-Text -Text $networkError }
    Summary             = [pscustomobject][ordered]@{
        ProcessCountAtEnd       = $runningRows.Count
        ProcessIdentitiesSeen   = $processRows.Count
        StartsSeen              = $totalStartsSeen
        ExitsSeen               = $totalExitsSeen
        CpuPercentLastSampleSum = [Math]::Round([double](($runningRows | Measure-Object -Property CpuPercentLast -Sum).Sum), 3)
        WorkingSetMBAtEnd       = [Math]::Round([double](($runningRows | Measure-Object -Property WorkingSetMB -Sum).Sum), 2)
        HandleCountAtEnd        = [int](($runningRows | Measure-Object -Property HandleCount -Sum).Sum)
    }
    ChurnByName         = $churnRows
    Processes           = $processRows
}

$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$parentDirectory = Split-Path -Parent $fullOutputPath
if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
}

$json = $snapshot | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($fullOutputPath, $json, [Text.UTF8Encoding]::new($false))

[pscustomobject][ordered]@{
    OutputPath            = $fullOutputPath
    DurationSeconds       = $snapshot.DurationSeconds
    ProcessCountAtEnd     = $snapshot.Summary.ProcessCountAtEnd
    StartsSeen            = $snapshot.Summary.StartsSeen
    ExitsSeen             = $snapshot.Summary.ExitsSeen
    CimAvailable          = $snapshot.CimAvailable
    IncludesCommandLine   = $snapshot.IncludesCommandLine
    Redacted              = $snapshot.Redacted
}
