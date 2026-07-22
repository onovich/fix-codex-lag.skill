#requires -Version 5.1

Set-StrictMode -Version Latest

function Protect-SensitiveText {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$CurrentDirectory
    )

    if ($null -eq $Text) {
        return $null
    }

    $result = $Text
    $replacements = @(
        [pscustomobject]@{ Value = $env:LOCALAPPDATA; Token = "%LOCALAPPDATA%" }
        [pscustomobject]@{ Value = $env:APPDATA; Token = "%APPDATA%" }
        [pscustomobject]@{ Value = $env:TEMP; Token = "%TEMP%" }
        [pscustomobject]@{ Value = $env:USERPROFILE; Token = "%USERPROFILE%" }
        [pscustomobject]@{ Value = $CurrentDirectory; Token = "%CWD%" }
        [pscustomobject]@{ Value = $env:USERNAME; Token = "<USER>" }
        [pscustomobject]@{ Value = $env:COMPUTERNAME; Token = "<HOST>" }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Value) } | Sort-Object { $_.Value.Length } -Descending

    foreach ($replacement in $replacements) {
        $result = [regex]::Replace(
            $result,
            [regex]::Escape([string]$replacement.Value),
            [string]$replacement.Token,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    # Remove common credential forms before applying broader token rules.
    $result = [regex]::Replace(
        $result,
        '(?i)\b(authorization\s*[:=]\s*bearer\s+)\S+',
        '${1}<REDACTED>'
    )
    $result = [regex]::Replace(
        $result,
        '(?i)\b(api[_-]?key|token|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|secret)(?:\s*[:=]\s*|\s+)(?:"[^"]*"|''[^'']*''|\S+)',
        '${1}=<REDACTED>'
    )
    $result = [regex]::Replace($result, '(?i)\b(?:sk-[A-Za-z0-9_-]{12,}|gh[opusr]_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{12,}|xox[baprs]-[A-Za-z0-9-]{12,}|AKIA[0-9A-Z]{16})\b', '<REDACTED>')

    # Remove identifiers that commonly identify a person, task, or host.
    $result = [regex]::Replace($result, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '<EMAIL>')
    $result = [regex]::Replace($result, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<ID>')
    $result = [regex]::Replace($result, '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?(?![\d.])', '<ADDRESS>')
    $result = [regex]::Replace($result, '(?i)\b(?:localhost|[A-Z0-9.-]+\.local):\d{1,5}\b', '<ADDRESS>')

    # Remove quoted and unquoted Windows, UNC, file-URI, and common user-home paths.
    $result = [regex]::Replace($result, '(?i)"(?:file:///)?[a-z]:[\\/][^"]*"', '"<PATH>"')
    $result = [regex]::Replace($result, "(?i)'(?:file:///)?[a-z]:[\\/][^']*'", "'<PATH>'")
    $result = [regex]::Replace($result, '(?i)"(?:\\\\|//)[^"]*"', '"<PATH>"')
    $result = [regex]::Replace($result, "(?i)'(?:\\\\|//)[^']*'", "'<PATH>'")
    $result = [regex]::Replace($result, '(?i)(?<![%\w])(?:file:///)?[a-z]:[\\/][^\s"''<>|]*', '<PATH>')
    $result = [regex]::Replace($result, '(?i)(?<![:\\])\\\\[^\\\s]+\\[^\s"''<>|]+', '<PATH>')
    $result = [regex]::Replace($result, '(?i)(?<!:)//[^/\s]+/[^\s"''<>|]+', '<PATH>')
    $result = [regex]::Replace($result, '(?i)(?<![\w])/(?:Users|home)/[^\s"''<>|]+', '<PATH>')

    return $result
}
