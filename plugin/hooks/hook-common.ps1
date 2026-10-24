# ============================================================================
#  hook-common.ps1 - helpers the plugin hooks share (dot-sourced, never run alone).
#  Windows PowerShell 5.1 and PowerShell 7. Every hook is silent and non-blocking:
#  these helpers never print a diagnostic, the callers swallow every failure.
# ============================================================================

$script:MaxHookInputChars = 1048576   # hook stdin is untrusted: never buffer more than 1 MB

# The text on stdin as UTF-8, or $null when it is longer than the cap (treated as no input).
function Read-HookStdin {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    try {
        $buffer = New-Object char[] ($script:MaxHookInputChars + 1)
        $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($count -gt $script:MaxHookInputChars) { return $null }
        return (New-Object System.Text.StringBuilder).Append($buffer, 0, $count).ToString()
    } finally {
        $reader.Dispose()
    }
}

# Compact JSON in which every non-ASCII character is a \uXXXX escape, so the hook output is
# plain ASCII whatever the console code page is.
function ConvertTo-AsciiJson {
    param([Parameter(Mandatory)]$Object)
    $json = $Object | ConvertTo-Json -Compress -Depth 6
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($match) '\u{0:x4}' -f [int][char]$match.Value })
}

function Write-HookOutput {
    param([Parameter(Mandatory)]$Object)
    [Console]::Out.Write((ConvertTo-AsciiJson $Object) + "`n")
}

# ----------------------------------------------------------------------------
#  Environment, clock and state (the throttle / notify caches)
# ----------------------------------------------------------------------------
$script:StateDirOverrideVariable = 'TESTSTAND_MCP_STATE_DIR'      # tests and unusual stations
$script:PluginDataVariable = 'CLAUDE_PLUGIN_DATA'                 # survives plugin updates
$script:LocalAppDataStateFolder = 'teststand-mcp'                 # %LOCALAPPDATA%\teststand-mcp
$script:ClockOverrideVariable = 'TESTSTAND_MCP_NOW'               # an ISO 8601 instant, for the tests
$script:FlagOnValue = '1'

# The value of an environment variable, or $null when it is unset or blank.
function Get-HookEnvironmentText {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

# A switch variable: only the exact value 1 turns it on.
function Test-HookFlag {
    param([Parameter(Mandatory)][string]$Name)
    return ((Get-HookEnvironmentText $Name) -ceq $script:FlagOnValue)
}

# The current instant; TESTSTAND_MCP_NOW overrides it when it parses.
function Get-HookNow {
    $override = Get-HookEnvironmentText $script:ClockOverrideVariable
    $parsed = [DateTimeOffset]::MinValue
    if ($null -ne $override -and [DateTimeOffset]::TryParse($override, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed
    }
    return [DateTimeOffset]::UtcNow
}

# Where the caches live: TESTSTAND_MCP_STATE_DIR, else CLAUDE_PLUGIN_DATA, else
# %LOCALAPPDATA%\teststand-mcp; $null when none of them is set.
function Get-HookStateDir {
    $override = Get-HookEnvironmentText $script:StateDirOverrideVariable
    if ($null -ne $override) { return $override }
    $pluginData = Get-HookEnvironmentText $script:PluginDataVariable
    if ($null -ne $pluginData) { return $pluginData }
    $localAppData = Get-HookEnvironmentText 'LOCALAPPDATA'
    if ($null -ne $localAppData) { return (Join-Path $localAppData $script:LocalAppDataStateFolder) }
    return $null
}

# A property of a parsed JSON object, or $null (a missing property throws under strict mode).
function Get-HookProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# The state file as an object; $null when it is missing, unreadable or not JSON.
function Read-HookState {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $dir = Get-HookStateDir
        if ($null -eq $dir) { return $null }
        $path = Join-Path $dir $Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        return ([IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# Writes the state file atomically (temp file, then move or replace). True when it was written;
# a failure is swallowed, so a read-only profile can only cost a repeated message.
function Write-HookState {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$State)
    $temp = $null
    try {
        $dir = Get-HookStateDir
        if ($null -eq $dir) { return $false }
        [void][IO.Directory]::CreateDirectory($dir)
        $target = Join-Path $dir $Name
        $temp = Join-Path $dir ($Name + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        # A plain $null would reach .NET as an empty string, which Replace rejects as an illegal path.
        if (Test-Path -LiteralPath $target) { [IO.File]::Replace($temp, $target, [NullString]::Value) } else { [IO.File]::Move($temp, $target) }
        $temp = $null
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}
