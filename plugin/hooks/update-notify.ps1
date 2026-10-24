# ============================================================================
#  update-notify.ps1 - SessionStart (startup) hook: tells the user, once a day, that a
#  newer plugin release exists. Windows PowerShell 5.1 and PowerShell 7. Never blocks:
#  it prints at most one systemMessage and exits 0; every failure is silent.
#
#  The latest version is the tag in the Location header of a no-redirect HEAD request
#  to <repo>/releases/latest (no API rate limit). The lookup, successful or failed, is
#  cached for 24 hours, and a version is announced at most once per 24 hours.
#  Silent when: the installed version is the 0.0.0 placeholder or unreadable, it is
#  equal or higher than the latest, TESTSTAND_MCP_NO_UPDATE_CHECK=1, or anything fails.
#
#  Injectable through environment variables, so the tests never touch the network or
#  the real profile: TESTSTAND_MCP_RELEASES_BASE_URL (the repository URL),
#  TESTSTAND_MCP_NOW (the clock), TESTSTAND_MCP_STATE_DIR (the cache directory) and
#  CLAUDE_PLUGIN_ROOT (the plugin root that holds .claude-plugin/plugin.json).
# ============================================================================
Set-StrictMode -Version 2.0

try { . (Join-Path $PSScriptRoot 'hook-common.ps1') } catch { exit 0 }

$script:OptOutVariable = 'TESTSTAND_MCP_NO_UPDATE_CHECK'
$script:BaseUrlVariable = 'TESTSTAND_MCP_RELEASES_BASE_URL'
$script:PluginRootVariable = 'CLAUDE_PLUGIN_ROOT'
$script:DefaultBaseUrl = 'https://github.com/Zuehlke/teststand-mcp'
$script:LatestReleasePath = '/releases/latest'
$script:HttpTimeoutMilliseconds = 3000   # the hook timeout is 5 s: shell start plus this stays inside it
$script:UserAgent = 'teststand-mcp-update-notify'
$script:RedirectStatusCodes = @(301, 302, 303, 307, 308)
$script:StateFile = 'update-notify.json'
$script:CacheSeconds = 24 * 60 * 60
$script:PlaceholderVersion = [version]'0.0.0'
$script:PluginJsonRelativePath = '.claude-plugin\plugin.json'
$script:TagPattern = '\A[vV]?(\d+\.\d+\.\d+)\z'
$script:TagInLocationPattern = '/tag/([^/?#]+)(?:[?#].*)?\z'
$script:MarketplaceName = 'zuehlke-teststand'
$script:PluginName = 'teststand-mcp'

# ----------------------------------------------------------------------------
#  Pure decisions
# ----------------------------------------------------------------------------
# "v1.10.0", "V1.8.6" or "1.2.3" as a [version]; $null for anything else (v1.x, 1.2, 1.2.3-rc1, overflow).
function Convert-TagToVersion {
    param([AllowNull()][string]$Tag)
    if ([string]::IsNullOrEmpty($Tag)) { return $null }
    $match = [regex]::Match($Tag, $script:TagPattern)
    if (-not $match.Success) { return $null }
    $parsed = $null
    if ([version]::TryParse($match.Groups[1].Value, [ref]$parsed)) { return $parsed }
    return $null
}

# The tag a Location header names (absolute or relative); $null when it names none.
function Get-TagFromLocation {
    param([AllowNull()][string]$Location)
    if ([string]::IsNullOrEmpty($Location)) { return $null }
    $match = [regex]::Match($Location, $script:TagInLocationPattern)
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

# True when the instant is less than 24 hours in the past. An instant in the future (the clock moved
# back) is not fresh, so a wrong clock can never silence the hook for longer than a day.
function Test-IsFresh {
    param([long]$Epoch, [long]$NowEpoch)
    $ageSeconds = $NowEpoch - $Epoch
    return ($ageSeconds -ge 0 -and $ageSeconds -lt $script:CacheSeconds)
}

# The message to show, or $null: only a latest version above the installed one that was not announced
# within the last 24 hours.
function Get-UpdateMessage {
    param([version]$Installed, [AllowNull()][version]$Latest, [string]$AnnouncedVersion, [long]$AnnouncedEpoch, [long]$NowEpoch)
    if ($null -eq $Latest -or $Latest -le $Installed) { return $null }
    $wasAnnouncedRecently = ($AnnouncedVersion -ceq [string]$Latest) -and (Test-IsFresh $AnnouncedEpoch $NowEpoch)
    if ($wasAnnouncedRecently) { return $null }
    $lines = @(
        "TestStand MCP update available: you have $Installed, the latest release is $Latest.",
        'To update, run these two commands in order:',
        "  1. claude plugin marketplace update $($script:MarketplaceName)",
        "  2. claude plugin update $($script:PluginName)",
        'Then restart Claude Code. You can ignore this message when marketplace auto-update is on: it updates the plugin by itself.',
        "To stop these checks, set $($script:OptOutVariable)=1."
    )
    return ($lines -join "`n")
}

# ----------------------------------------------------------------------------
#  I/O
# ----------------------------------------------------------------------------
function Set-HookTls12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Get-PluginRoot {
    $fromEnvironment = Get-HookEnvironmentText $script:PluginRootVariable
    if ($null -ne $fromEnvironment) { return $fromEnvironment }
    return (Split-Path -Parent $PSScriptRoot)
}

# The version in plugin.json; $null when it is missing, unreadable or not a version.
function Get-InstalledVersion {
    param([string]$PluginRoot)
    try {
        $path = Join-Path $PluginRoot $script:PluginJsonRelativePath
        $text = [IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))
        $versionText = [string](Get-HookProperty ($text | ConvertFrom-Json) 'version')
        $parsed = $null
        if ([version]::TryParse($versionText, [ref]$parsed)) { return $parsed }
    } catch { }
    return $null
}

# A HEAD request that does not follow redirects, cut off after the HTTP timeout (the whole call,
# connecting included). @{ StatusCode; Location }, or $null on any failure.
function Invoke-HeadRequest {
    param([Parameter(Mandatory)][string]$Url)
    $response = $null
    try {
        $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $false
        $request.Timeout = $script:HttpTimeoutMilliseconds
        $request.ReadWriteTimeout = $script:HttpTimeoutMilliseconds
        $request.UserAgent = $script:UserAgent
        $request.Proxy = [Net.WebRequest]::GetSystemWebProxy()
        $request.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials
        $pending = $request.GetResponseAsync()
        if (-not $pending.Wait($script:HttpTimeoutMilliseconds)) {
            $request.Abort()
            return $null
        }
        $response = $pending.Result
        return @{ StatusCode = [int]$response.StatusCode; Location = $response.Headers['Location'] }
    } catch {
        return $null
    } finally {
        if ($null -ne $response) { $response.Close() }
    }
}

# The latest released version, or $null when the lookup fails or the redirect is not a clean X.Y.Z tag.
function Get-LatestVersion {
    param([Parameter(Mandatory)][string]$BaseUrl)
    Set-HookTls12
    $answer = Invoke-HeadRequest ($BaseUrl.TrimEnd('/') + $script:LatestReleasePath)
    if ($null -eq $answer -or $script:RedirectStatusCodes -notcontains $answer.StatusCode) { return $null }
    return (Convert-TagToVersion (Get-TagFromLocation $answer.Location))
}

function ConvertTo-EpochOrZero {
    param($Value)
    $parsed = 0L
    if ([long]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return 0L
}

# The latest version from the cache when the last lookup is under 24 hours old (a failed lookup is
# cached as "no version"), else from the network. Returns @{ Latest; State } with the state to keep.
function Get-LatestVersionCached {
    param($State, [long]$NowEpoch)
    $kept = @{
        announcedVersion = [string](Get-HookProperty $State 'announcedVersion')
        announcedEpoch   = (ConvertTo-EpochOrZero (Get-HookProperty $State 'announcedEpoch'))
    }
    $lookupEpoch = ConvertTo-EpochOrZero (Get-HookProperty $State 'lookupEpoch')
    if (Test-IsFresh $lookupEpoch $NowEpoch) {
        $cached = $null
        if (Get-HookProperty $State 'lookupOk') { [void][version]::TryParse([string](Get-HookProperty $State 'latestVersion'), [ref]$cached) }
        return @{ Latest = $cached; State = $null }
    }
    $latest = Get-LatestVersion (Get-BaseUrl)
    $kept['lookupEpoch'] = $NowEpoch
    $kept['lookupOk'] = ($null -ne $latest)
    $kept['latestVersion'] = if ($null -ne $latest) { [string]$latest } else { '' }
    return @{ Latest = $latest; State = $kept }
}

function Get-BaseUrl {
    $fromEnvironment = Get-HookEnvironmentText $script:BaseUrlVariable
    if ($null -ne $fromEnvironment) { return $fromEnvironment }
    return $script:DefaultBaseUrl
}

# The state after an announcement: the lookup that produced the version, plus what was announced when.
function New-AnnouncedState {
    param($State, [version]$Latest, [long]$NowEpoch)
    return @{
        lookupEpoch      = (ConvertTo-EpochOrZero (Get-HookProperty $State 'lookupEpoch'))
        lookupOk         = $true
        latestVersion    = [string]$Latest
        announcedVersion = [string]$Latest
        announcedEpoch   = $NowEpoch
    }
}

function Invoke-UpdateNotify {
    if (Test-HookFlag $script:OptOutVariable) { return }
    $installed = Get-InstalledVersion (Get-PluginRoot)
    if ($null -eq $installed -or $installed -le $script:PlaceholderVersion) { return }

    $nowEpoch = (Get-HookNow).ToUnixTimeSeconds()
    $state = Read-HookState $script:StateFile
    $lookup = Get-LatestVersionCached $state $nowEpoch
    if ($null -ne $lookup.State) {
        [void](Write-HookState $script:StateFile $lookup.State)
        $state = [pscustomobject]$lookup.State
    }

    $message = Get-UpdateMessage -Installed $installed -Latest $lookup.Latest `
        -AnnouncedVersion ([string](Get-HookProperty $state 'announcedVersion')) `
        -AnnouncedEpoch (ConvertTo-EpochOrZero (Get-HookProperty $state 'announcedEpoch')) -NowEpoch $nowEpoch
    if ($null -eq $message) { return }

    [void](Write-HookState $script:StateFile (New-AnnouncedState $state $lookup.Latest $nowEpoch))
    Write-HookOutput @{ systemMessage = $message }
}

# Dot-sourcing (the tests) loads the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-UpdateNotify } catch { }
    exit 0
}
