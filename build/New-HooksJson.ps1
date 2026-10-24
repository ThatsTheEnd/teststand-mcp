# ============================================================================
#  New-HooksJson.ps1 - generates plugin/hooks/hooks.json (committed).
#  The PreToolUse matcher is the "|"-joined list of the full tool names of the
#  allow-list in plugin/hooks/tool-classes.json, each with the plugin tool prefix
#  from build/PluginIdentity.psm1 (a matcher of letters, digits, _ - and | is a list
#  of EXACT strings, never a regular expression), so a tool that prompts starts no
#  process. The classification is checked against the tools the server registers
#  first; an invalid one writes nothing and exits 1.
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\New-HooksJson.ps1
#  -OutputPath / -ClassesPath / -RegistryPath let the tests point it at fixtures.
#  The JSON is written by hand (LF, UTF-8 without BOM, final newline) so the bytes are the same
#  on Windows PowerShell 5.1 and PowerShell 7: ConvertTo-Json indents differently in the two.
#  Windows PowerShell 5.1 and PowerShell 7 compatible.
# ============================================================================
param(
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugin\hooks\hooks.json'),
    [string]$ClassesPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugin\hooks\tool-classes.json'),
    [string]$RegistryPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Tools\TestStandToolRegistry.cs')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1') -Force

$Description = 'TestStand MCP hooks: read-only TestStand tools run without a permission prompt, a startup check warns about a missing TestStand or doc-agent dependency, and a startup notice names a newer release. The hooks print nothing and never block when something fails.'
$HookShell = 'powershell'
$CommandFormat = 'powershell -NoProfile -ExecutionPolicy Bypass -File "${{CLAUDE_PLUGIN_ROOT}}/hooks/{0}"'
$PreToolUseScript = 'allow-readonly.ps1'
$SessionStartScripts = @('platform-guard.ps1', 'update-notify.ps1')
$SessionStartMatcher = 'startup'          # not resume, clear or compact
$SessionStartTimeoutSeconds = 5           # hook timeouts are in seconds (slice 0, fact 5)
$ToolNameSeparator = '|'
$IndentUnit = '  '

# A JSON string literal: backslash, quote and control characters escaped, everything else must be ASCII.
function ConvertTo-JsonStringLiteral {
    param([Parameter(Mandatory)][string]$Text)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($char in $Text.ToCharArray()) {
        switch ($char) {
            '"'  { [void]$builder.Append('\"') }
            '\'  { [void]$builder.Append('\\') }
            default {
                if ([int]$char -lt 32 -or [int]$char -gt 126) { [void]$builder.Append(('\u{0:x4}' -f [int]$char)) }
                else { [void]$builder.Append($char) }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Format-HookEntry {
    param([Parameter(Mandatory)][string]$ScriptName, [int]$TimeoutSeconds = 0, [Parameter(Mandatory)][string]$Indent)
    $command = $CommandFormat -f $ScriptName
    $fields = @(
        '"type": "command"',
        ('"shell": ' + (ConvertTo-JsonStringLiteral $HookShell)),
        ('"command": ' + (ConvertTo-JsonStringLiteral $command))
    )
    if ($TimeoutSeconds -gt 0) { $fields += ('"timeout": ' + $TimeoutSeconds) }
    $inner = $Indent + $IndentUnit
    $lines = @($Indent + '{')
    for ($index = 0; $index -lt $fields.Count; $index++) {
        $comma = if ($index -lt $fields.Count - 1) { ',' } else { '' }
        $lines += ($inner + $fields[$index] + $comma)
    }
    $lines += ($Indent + '}')
    return $lines
}

# A matcher group: { "matcher": ..., "hooks": [ entries... ] }, entries given as arrays of lines.
function Format-MatcherGroup {
    param([Parameter(Mandatory)][string]$Matcher, [Parameter(Mandatory)]$EntryLines, [Parameter(Mandatory)][string]$Indent)
    $inner = $Indent + $IndentUnit
    $lines = @(($Indent + '{'), ($inner + '"matcher": ' + (ConvertTo-JsonStringLiteral $Matcher) + ','), ($inner + '"hooks": ['))
    for ($index = 0; $index -lt $EntryLines.Count; $index++) {
        $entry = @($EntryLines[$index])
        if ($index -lt $EntryLines.Count - 1) { $entry[$entry.Count - 1] += ',' }
        $lines += $entry
    }
    $lines += ($inner + ']')
    $lines += ($Indent + '}')
    return $lines
}

function New-HooksJsonText {
    param([Parameter(Mandatory)][string[]]$ToolNames, [Parameter(Mandatory)][string]$ToolPrefix)
    $matcher = ($ToolNames | ForEach-Object { $ToolPrefix + $_ }) -join $ToolNameSeparator

    $preEntry = Format-HookEntry -ScriptName $PreToolUseScript -Indent ($IndentUnit * 5)
    $preGroup = Format-MatcherGroup -Matcher $matcher -EntryLines @(, $preEntry) -Indent ($IndentUnit * 3)

    $startEntries = @($SessionStartScripts | ForEach-Object {
        , (Format-HookEntry -ScriptName $_ -TimeoutSeconds $SessionStartTimeoutSeconds -Indent ($IndentUnit * 5))
    })
    $startGroup = Format-MatcherGroup -Matcher $SessionStartMatcher -EntryLines $startEntries -Indent ($IndentUnit * 3)

    $lines = @('{', ($IndentUnit + '"description": ' + (ConvertTo-JsonStringLiteral $Description) + ','), ($IndentUnit + '"hooks": {'))
    $lines += ($IndentUnit * 2) + '"PreToolUse": ['
    $lines += $preGroup
    $lines += ($IndentUnit * 2) + '],'
    $lines += ($IndentUnit * 2) + '"SessionStart": ['
    $lines += $startGroup
    $lines += ($IndentUnit * 2) + ']'
    $lines += ($IndentUnit + '}')
    $lines += '}'
    return (($lines -join "`n") + "`n")
}

try {
    Import-Module (Join-Path $PSScriptRoot 'PluginIdentity.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'ToolClassification.psm1') -Force

    $classes = Read-ToolClasses -Path $ClassesPath
    Assert-ToolClassification -Classes $classes -RegisteredTools (Get-RegisteredToolNames -RegistryPath $RegistryPath) -ClassesPath $ClassesPath

    $text = New-HooksJsonText -ToolNames @($classes.allow) -ToolPrefix (Get-PluginIdentity).pluginToolPrefix
    $target = Resolve-BuildPath $OutputPath
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
    [IO.File]::WriteAllText($target, $text, (Get-Utf8NoBomEncoding))
    Write-Host "Wrote $OutputPath ($(@($classes.allow).Count) allow-listed tools)"
    exit 0
} catch {
    Write-Host (Get-ScriptFailureText -ErrorRecord $_)
    exit 1
}
