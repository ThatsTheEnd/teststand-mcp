# ============================================================================
#  platform-guard.ps1 - SessionStart (startup) hook for Windows: ONE combined ASCII
#  warning when the station lacks TestStand or one of the doc-agent dependencies,
#  plus a one-line context that points the model at the teststand-rules skill.
#  Windows PowerShell 5.1 and PowerShell 7. Never blocks: it prints one JSON object
#  and exits 0, and every failure is silent.
#
#    - TestStand missing: warned EVERY time (the server cannot work without it).
#    - Python, python-docx, Pillow, Edge/Chrome missing: OPTIONAL (only the doc and
#      presentation agents need them), warned once per 24 hours per missing set;
#      TESTSTAND_MCP_NO_PLATFORM_WARNING=1 switches this part off.
#  The non-Windows message lives in platform-guard.sh.
# ============================================================================
Set-StrictMode -Version 2.0

try { . (Join-Path $PSScriptRoot 'hook-common.ps1') } catch { exit 0 }

$script:OptOutVariable = 'TESTSTAND_MCP_NO_PLATFORM_WARNING'
$script:GuardStateFile = 'platform-guard.json'
$script:OptionalThrottleSeconds = 24 * 60 * 60
$script:ProbeTimeoutMilliseconds = 1500   # per interpreter: two probes plus the shell start stay inside the 5 s hook timeout
$script:TestStandFolderFilter = 'TestStand*'
$script:TestStandVendorFolder = 'National Instruments'
$script:BrowserRelativePaths = @('Microsoft\Edge\Application\msedge.exe', 'Google\Chrome\Application\chrome.exe')
$script:BrowserCommandNames = @('msedge', 'chrome')
$script:ProgramFilesVariables = @('ProgramW6432', 'ProgramFiles', 'ProgramFiles(x86)')
# One probe answers both questions: "<docx present> <Pillow present>", each 1 or 0.
$script:PythonProbeCode = "import importlib.util as u; print(int(u.find_spec('docx') is not None), int(u.find_spec('PIL') is not None))"
$script:PythonProbePattern = '\A([01])\s+([01])\z'
$script:PythonCandidates = @(
    @{ Command = 'py';     Arguments = '-3 -c' }
    @{ Command = 'python'; Arguments = '-c' }
)
$script:RulesContext = 'TestStand MCP: before any TestStand work in this session, load the teststand-rules skill (the usage rules for the TestStand MCP tools).'
$script:TestStandFix = 'install NI TestStand 2019 or later, or start Claude Code where TestStand is installed'
$script:OptionalNote = 'The documentation and presentation agents are optional: they need Python, python-docx, Pillow and Edge or Chrome. The MCP tools work without them.'
$script:OptOutNote = "To hide these optional notes, set $($script:OptOutVariable)=1."

# ----------------------------------------------------------------------------
#  Probing the station
# ----------------------------------------------------------------------------
function Get-ProgramFilesRoots {
    $roots = @()
    foreach ($variable in $script:ProgramFilesVariables) {
        $path = Get-HookEnvironmentText $variable
        if ($null -ne $path -and (Test-Path -LiteralPath $path -PathType Container) -and ($roots -notcontains $path)) { $roots += $path }
    }
    return $roots
}

function Test-TestStandDetected {
    if ($null -ne (Get-HookEnvironmentText 'TestStand')) { return $true }
    foreach ($root in (Get-ProgramFilesRoots)) {
        $vendorDir = Join-Path $root $script:TestStandVendorFolder
        if (-not (Test-Path -LiteralPath $vendorDir -PathType Container)) { continue }
        $installs = @(Get-ChildItem -LiteralPath $vendorDir -Directory -Filter $script:TestStandFolderFilter -ErrorAction SilentlyContinue)
        if ($installs.Count -gt 0) { return $true }
    }
    return $false
}

function Test-BrowserInstalled {
    foreach ($root in (Get-ProgramFilesRoots)) {
        foreach ($relativePath in $script:BrowserRelativePaths) {
            if (Test-Path -LiteralPath (Join-Path $root $relativePath) -PathType Leaf) { return $true }
        }
    }
    foreach ($name in $script:BrowserCommandNames) {
        if ($null -ne (Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $true }
    }
    return $false
}

# Runs one program with a hard time limit; its stdout when it exits 0 in time, else $null.
function Invoke-Probe {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$Arguments, [int]$TimeoutMilliseconds)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            return $null
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { return $null }
        return $stdout.Result
    } finally {
        $process.Dispose()
    }
}

# The first interpreter that answers the probe: @{ Command; HasDocx; HasPillow }, or $null.
function Find-Python {
    foreach ($candidate in $script:PythonCandidates) {
        $application = Get-Command -Name $candidate.Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $application) { continue }
        try {
            $output = Invoke-Probe -FilePath $application.Source -Arguments ($candidate.Arguments + ' "' + $script:PythonProbeCode + '"') -TimeoutMilliseconds $script:ProbeTimeoutMilliseconds
        } catch {
            continue
        }
        if ($null -eq $output) { continue }
        $match = [regex]::Match($output.Trim(), $script:PythonProbePattern)
        if (-not $match.Success) { continue }
        return @{ Command = $candidate.Command; HasDocx = ($match.Groups[1].Value -eq '1'); HasPillow = ($match.Groups[2].Value -eq '1') }
    }
    return $null
}

# ----------------------------------------------------------------------------
#  Findings: pure decisions over the facts
# ----------------------------------------------------------------------------
function New-Finding {
    param([string]$Id, [bool]$IsOptional, [string]$Text)
    return [pscustomobject]@{ Id = $Id; IsOptional = $IsOptional; Text = $Text }
}

function Get-PipInstallCommand {
    param([string]$PythonCommand)
    return "$PythonCommand -m pip install python-docx pillow"
}

# $Facts: HasTestStand, and Optional = $null (not probed) or @{ Python = $null | @{ Command; HasDocx; HasPillow }; HasBrowser }.
function Get-Findings {
    param([Parameter(Mandatory)]$Facts)
    $findings = @()
    if (-not $Facts.HasTestStand) {
        $findings += New-Finding 'teststand' $false "NI TestStand was not detected. Fix: $($script:TestStandFix)."
    }
    if ($null -eq $Facts.Optional) { return $findings }
    $python = $Facts.Optional.Python
    if ($null -eq $python) {
        $findings += New-Finding 'python' $true 'Python was not found (neither "py -3" nor "python" answered). Fix: install Python 3 from python.org, then run: py -m pip install python-docx pillow'
    } else {
        $pip = Get-PipInstallCommand $python.Command
        if (-not $python.HasDocx)   { $findings += New-Finding 'docx' $true "python-docx is not installed. Fix: $pip" }
        if (-not $python.HasPillow) { $findings += New-Finding 'pillow' $true "Pillow is not installed. Fix: $pip" }
    }
    if (-not $Facts.Optional.HasBrowser) {
        $findings += New-Finding 'browser' $true 'Edge or Chrome was not found. Fix: install Microsoft Edge or Google Chrome.'
    }
    return $findings
}

# The identity of a missing set: the sorted ids, so a different set is a different key.
function Get-MissingSetKey {
    param($Findings)
    $ids = @($Findings | ForEach-Object { $_.Id })
    [Array]::Sort($ids, [StringComparer]::Ordinal)
    return ($ids -join ',')
}

# True when the same missing set was NOT warned about within the last 24 hours. A stored time in
# the future (the clock moved back) counts as expired rather than suppressing the warning.
function Test-OptionalWarningDue {
    param($State, [string]$Key, [long]$NowEpochSeconds)
    $storedKey = Get-HookProperty $State 'optionalMissing'
    if ($storedKey -cne $Key) { return $true }
    $warnedAt = 0L
    if (-not [long]::TryParse([string](Get-HookProperty $State 'warnedAtEpoch'), [ref]$warnedAt)) { return $true }
    $ageSeconds = $NowEpochSeconds - $warnedAt
    return ($ageSeconds -lt 0 -or $ageSeconds -ge $script:OptionalThrottleSeconds)
}

function Format-GuardMessage {
    param([Parameter(Mandatory)]$Findings)
    $lines = @('TestStand MCP: this station needs attention.')
    $lines += @($Findings | ForEach-Object { '- ' + $_.Text })
    $optional = @($Findings | Where-Object { $_.IsOptional })
    if ($optional.Count -gt 0) {
        $lines += $script:OptionalNote
        $lines += $script:OptOutNote
    }
    return ($lines -join "`n")
}

# ----------------------------------------------------------------------------
#  The hook
# ----------------------------------------------------------------------------
# The optional probes (Python, browser) are skipped when the optional warning is switched off.
function Get-StationFacts {
    param([bool]$IncludeOptional)
    $facts = @{ HasTestStand = (Test-TestStandDetected); Optional = $null }
    if ($IncludeOptional) { $facts.Optional = @{ Python = (Find-Python); HasBrowser = (Test-BrowserInstalled) } }
    return $facts
}

# The findings to show now: every required one, plus the optional ones when they are due.
# Records the optional warning as shown.
function Get-FindingsToShow {
    $isOptionalOn = -not (Test-HookFlag $script:OptOutVariable)
    $findings = @(Get-Findings (Get-StationFacts -IncludeOptional $isOptionalOn))
    $required = @($findings | Where-Object { -not $_.IsOptional })
    $optional = @($findings | Where-Object { $_.IsOptional })
    if ($optional.Count -eq 0) { return $required }
    $key = Get-MissingSetKey $optional
    $nowEpoch = (Get-HookNow).ToUnixTimeSeconds()
    if (-not (Test-OptionalWarningDue (Read-HookState $script:GuardStateFile) $key $nowEpoch)) { return $required }
    [void](Write-HookState $script:GuardStateFile @{ optionalMissing = $key; warnedAtEpoch = $nowEpoch })
    return ($required + $optional)
}

function Invoke-PlatformGuard {
    $findings = @(Get-FindingsToShow)
    $output = [ordered]@{}
    if ($findings.Count -gt 0) { $output['systemMessage'] = Format-GuardMessage $findings }
    $output['hookSpecificOutput'] = [ordered]@{ hookEventName = 'SessionStart'; additionalContext = $script:RulesContext }
    Write-HookOutput $output
}

# Dot-sourcing (the tests) loads the functions only. Off Windows the .sh twin speaks instead.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { Invoke-PlatformGuard }
    } catch { }
    exit 0
}
