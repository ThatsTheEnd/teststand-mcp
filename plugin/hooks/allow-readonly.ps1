# ============================================================================
#  allow-readonly.ps1 - PreToolUse hook: lets the read-only TestStand MCP tools run
#  without a permission prompt. Windows PowerShell 5.1 and PowerShell 7.
#
#  hooks.json starts this script only for the literal names of tool-classes.json's
#  "allow" list, so a prompting tool starts no process. The script checks the same
#  list again (defence in depth) and prints nothing, exit 0, for everything else:
#  an unlisted tool, a malformed input, a missing or unreadable tool-classes.json.
#  The short tool name is the text after the last "__"; it needs an "mcp__plugin_"
#  start, so no plugin name or server key is typed here.
# ============================================================================
Set-StrictMode -Version 2.0

try { . (Join-Path $PSScriptRoot 'hook-common.ps1') } catch { exit 0 }

$script:AllowReason = 'no TestStand file is modified'
$script:PluginToolPrefixStart = 'mcp__plugin_'
$script:ToolNameSeparator = '__'
$script:ToolClassesFileName = 'tool-classes.json'

# The tool name after the last "__" of a plugin tool name; $null for anything else.
function Get-ShortToolName {
    param($ToolName)
    if ($ToolName -isnot [string]) { return $null }
    if (-not $ToolName.StartsWith($script:PluginToolPrefixStart, [StringComparison]::Ordinal)) { return $null }
    $separatorIndex = $ToolName.LastIndexOf($script:ToolNameSeparator, [StringComparison]::Ordinal)
    if ($separatorIndex -lt $script:PluginToolPrefixStart.Length) { return $null }
    return $ToolName.Substring($separatorIndex + $script:ToolNameSeparator.Length)
}

# The tool_name of a hook input text; $null when the text is not a JSON object with a string tool_name.
function Get-RequestedToolName {
    param([string]$InputText)
    if ([string]::IsNullOrWhiteSpace($InputText)) { return $null }
    $request = $InputText | ConvertFrom-Json
    if ($null -eq $request) { return $null }
    $property = $request.PSObject.Properties['tool_name']
    if ($null -eq $property) { return $null }
    return $property.Value
}

# True when the (possibly malformed) tool name is a plugin tool whose short name is allow-listed.
function Test-ToolAllowed {
    param($ToolName, [string[]]$AllowList)
    $shortName = Get-ShortToolName $ToolName
    if ([string]::IsNullOrEmpty($shortName)) { return $false }
    return ($AllowList -ccontains $shortName)
}

function Read-AllowList {
    param([string]$Path)
    $json = [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
    return @($json.allow | Where-Object { $_ -is [string] })
}

function New-AllowDecision {
    return @{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'allow'
            permissionDecisionReason = $script:AllowReason
        }
    }
}

function Invoke-AllowHook {
    $toolName = Get-RequestedToolName (Read-HookStdin)
    $allowList = Read-AllowList (Join-Path $PSScriptRoot $script:ToolClassesFileName)
    if (Test-ToolAllowed $toolName $allowList) { Write-HookOutput (New-AllowDecision) }
}

# Dot-sourcing (the tests) loads the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-AllowHook } catch { }
    exit 0
}
