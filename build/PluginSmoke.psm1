# ============================================================================
#  PluginSmoke.psm1 - the smoke tests of the STAGED exe (spec AC-3, AC-6), run on a machine with no
#  TestStand: every check starts the exe from the staged tree and nothing else.
#    Assert-VersionOutput        --version names the version, the tag and the commit (stdout, exit 0)
#    Assert-ToolList             --list-tools --json equals the tools classified in tool-classes.json
#    Assert-InitializeRoundTrip  a stdio initialize returns serverInfo.version, and the startup log
#                                names the same version
#  Each process is started here with a timeout and stopped by its own process id.
#
#  initialize does NOT connect the TestStand engine (read in src/McpServer.cs): HandleInitialize
#  negotiates the protocol version, logs, and answers with VersionInfo.Current. The engine is
#  connected only by a tool call (ConnectAsync / EnsureConnected in TestStandService), and
#  ApplyStationDefaults only stores the configured values. So this check needs no TestStand.
#
#  The startup log cannot be read from a redirected stderr: with stdin redirected, Program.cs
#  allocates its own console window and writes the banner and the log there (so a human can watch
#  it), and nothing reaches the redirected stderr. Assert-StartupLogVersion therefore reads stderr
#  when something arrives, and otherwise checks in Program.cs that the startup log line prints
#  VersionInfo.Current.Version, the same value serverInfo reports.
#  Compatible with Windows PowerShell 5.1 and PowerShell 7.
# ============================================================================
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'ToolClassification.psm1')

$script:CommandTimeoutSeconds = 60       # a cold first start under Defender can be slow (the spike measured 0.4 s)
$script:InitializeTimeoutSeconds = 60
$script:ExitAfterEofSeconds = 15
$script:StderrDrainMilliseconds = 5000
$script:InitializeRequest = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"packaging-smoke","version":"0"}}}'
$script:StartupLogSourcePattern = 'starting[^\r\n]*VersionInfo\.Current\.Version'
$script:UntaggedMarker = '-dev'
$script:MetadataNoteLabel = 'note:'

function Format-OutputExcerpt {
    param([AllowEmptyString()][string]$Text)
    $lines = @(($Text -split '\r?\n') | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 8)
    if ($lines.Count -eq 0) { return '(no output)' }
    return ($lines -join "`n")
}

# Runs the exe with arguments; fails when it times out or exits non-zero (exit 0 is part of every smoke test).
function Invoke-SmokeCommand {
    param([string]$ExePath, [string[]]$Arguments)
    $shown = "$([IO.Path]::GetFileName($ExePath)) $($Arguments -join ' ')"
    $result = Invoke-ChildProcess -FilePath $ExePath -ArgumentList $Arguments -TimeoutSeconds $script:CommandTimeoutSeconds
    if ($result.TimedOut) {
        Write-BuildFailure -What "$shown did not finish within $script:CommandTimeoutSeconds s and was stopped." `
            -Why 'The staged exe must answer its informational flags at once, without an engine; a hang means it started something it should not.' `
            -Fix "Run it by hand from the staged tree: $shown"
    }
    if ($result.ExitCode -ne 0) {
        Write-BuildFailure -What "$shown exited with code $($result.ExitCode):`n$(Format-OutputExcerpt ($result.Stdout + "`n" + $result.Stderr))" `
            -Why 'The exe could not start or failed before answering; it would not start for a user either.' `
            -Fix "Run it by hand from the staged tree: $shown"
    }
    return $result
}

function Assert-VersionOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath, [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Commit
    )
    $result = Invoke-SmokeCommand $ExePath @('--version')
    $problems = @()
    # The first line is "<product> <version>"; the version must be its last word (the tag line also holds "1.9.0" inside "v1.9.0").
    $firstWord = @(($result.Stdout -split '\r?\n')[0].Trim() -split '\s+')[-1]
    if ($firstWord -cne $Version) { $problems += "its first line ends with '$firstWord', not '$Version'" }
    foreach ($expected in @($Tag, $Commit)) {
        if ($result.Stdout.IndexOf($expected, [StringComparison]::Ordinal) -lt 0) { $problems += "it does not name '$expected'" }
    }
    if ($Version.IndexOf($script:UntaggedMarker, [StringComparison]::Ordinal) -lt 0 -and $result.Stdout.IndexOf($script:UntaggedMarker, [StringComparison]::Ordinal) -ge 0) {
        $problems += "it reports an untagged build ('$script:UntaggedMarker')"
    }
    if ($result.Stdout.IndexOf($script:MetadataNoteLabel, [StringComparison]::Ordinal) -ge 0) {
        $problems += 'it carries a release-metadata note, so VERSION.txt was not read'
    }
    if ($problems.Count -gt 0) {
        Write-BuildFailure -What "The staged exe's --version output is wrong ($($problems -join '; ')):`n$(Format-OutputExcerpt $result.Stdout)" `
            -Why 'Users and support read --version to learn which release they run; the release must name its own version, tag and commit.' `
            -Fix 'Check VERSION.txt in the staged tree and the -Version, -Tag and -Commit passed to the packaging, then run it again.'
    }
}

function Get-ClassifiedToolNames {
    param([string]$ClassesPath)
    $classes = Read-ToolClasses -Path $ClassesPath
    return @((Get-ClassList $classes 'allow') + (Get-ClassList $classes 'prompt'))
}

function Assert-ToolList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExePath, [Parameter(Mandatory)][string]$ClassesPath, [Parameter(Mandatory)][string]$RegistryPath)
    $result = Invoke-SmokeCommand $ExePath @('--list-tools', '--json')
    try {
        $listed = @($result.Stdout | ConvertFrom-Json | ForEach-Object { $_ })
    } catch {
        Write-BuildFailure -What "--list-tools --json did not print a JSON array: $(Format-OutputExcerpt $result.Stdout)" `
            -Why 'The release checks and the hook classification read this list; text on stdout that is not JSON breaks them.' `
            -Fix 'Run the staged exe by hand with --list-tools --json and check that nothing else writes to stdout.'
    }
    $classified = Get-ClassifiedToolNames $ClassesPath
    $registered = @(Get-RegisteredToolNames -RegistryPath $RegistryPath)
    $unclassified = @($listed | Where-Object { $classified -cnotcontains $_ })
    $notListed = @($classified | Where-Object { $listed -cnotcontains $_ })
    if ($unclassified.Count -gt 0 -or $notListed.Count -gt 0 -or $listed.Count -ne $registered.Count) {
        $detail = @("the exe lists $($listed.Count) tools, the registry has $($registered.Count)")
        if ($unclassified.Count -gt 0) { $detail += "listed by the exe but not classified: $($unclassified -join ', ')" }
        if ($notListed.Count -gt 0) { $detail += "classified but not listed by the exe: $($notListed -join ', ')" }
        Write-BuildFailure -What "--list-tools --json does not match plugin/hooks/tool-classes.json ($($detail -join '; '))." `
            -Why 'The auto-allow hook decides per tool name; a tool the exe serves but the classification lacks would prompt unreviewed, and a stale entry hides that a tool was removed.' `
            -Fix 'Put every registered tool in exactly one of the allow and prompt lists of plugin/hooks/tool-classes.json (build/tests/ToolClassification.Tests.ps1 names the rule), then run the packaging again.'
    }
}

# Starts the exe, sends one initialize request on stdin, and returns the reply line and what reached stderr.
function Invoke-InitializeExchange {
    param([string]$ExePath, [int]$TimeoutSeconds)
    $process = [Diagnostics.Process]::Start((New-ChildProcessStartInfo -FilePath $ExePath))
    try {
        $stderr = $process.StandardError.ReadToEndAsync()
        $reply = $process.StandardOutput.ReadLineAsync()
        $request = (Get-Utf8NoBomEncoding).GetBytes($script:InitializeRequest + "`n")
        $answered = $false
        try {
            $process.StandardInput.BaseStream.Write($request, 0, $request.Length)
            $process.StandardInput.BaseStream.Flush()
            $answered = $reply.Wait($TimeoutSeconds * 1000)
        } catch [System.IO.IOException] {
            # the exe ended before it read the request: reported below as "no reply"
        }
        $process.StandardInput.Close()
        [void]$process.WaitForExit($script:ExitAfterEofSeconds * 1000)
        $errorText = ''
        if ($stderr.Wait($script:StderrDrainMilliseconds)) { $errorText = $stderr.Result }
        return [pscustomobject]@{ Answered = $answered; Reply = $(if ($answered) { $reply.Result } else { $null }); Stderr = $errorText }
    } finally {
        Stop-ChildProcess $process
        $process.Dispose()
    }
}

# The startup log line names the version: read from stderr when it arrives there, otherwise from the
# source (see the module header for why the log does not reach a redirected stderr).
function Assert-StartupLogVersion {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$StderrText, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$ProgramSourcePath)
    $why = 'The startup log is what a user pastes into a bug report; it must name the release that wrote it.'
    if ($StderrText.Trim().Length -gt 0) {
        if ($StderrText.IndexOf($Version, [StringComparison]::Ordinal) -ge 0) { return }
        Write-BuildFailure -What "The startup log (stderr) does not name version ${Version}:`n$(Format-OutputExcerpt $StderrText)" -Why $why `
            -Fix 'Check that Program.cs logs VersionInfo.Current.Version, then run the packaging again.'
    }
    if ((Read-Utf8Text $ProgramSourcePath) -cnotmatch $script:StartupLogSourcePattern) {
        Write-BuildFailure -What "Nothing reached stderr, and $ProgramSourcePath has no startup log line that prints VersionInfo.Current.Version." -Why $why `
            -Fix 'Log the version in the startup line of Program.cs with VersionInfo.Current.Version.'
    }
}

function Assert-InitializeRoundTrip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$ProgramSourcePath,
        [int]$TimeoutSeconds = $script:InitializeTimeoutSeconds
    )
    $exchange = Invoke-InitializeExchange -ExePath $ExePath -TimeoutSeconds $TimeoutSeconds
    if (-not $exchange.Answered) {
        Write-BuildFailure -What "The staged exe did not answer an MCP initialize request within $TimeoutSeconds s (stderr: $(Format-OutputExcerpt $exchange.Stderr))." `
            -Why 'This is the first thing Claude Code does with the server; if it is not answered the plugin shows as failed to start.' `
            -Fix 'Start the staged exe by hand with the request on stdin and read what it prints.'
    }
    try {
        $actual = (($exchange.Reply | ConvertFrom-Json).result.serverInfo.version)
    } catch {
        $actual = "(unreadable reply: $($exchange.Reply))"
    }
    if ($actual -cne $Version) {
        Write-BuildFailure -What "The initialize reply carries serverInfo.version '$actual' but version $Version was built." `
            -Why 'Clients show and log serverInfo.version; it must be the release the user installed.' `
            -Fix 'Check that McpServer.cs answers with VersionInfo.Current.ToServerInfo(), then run the packaging again.'
    }
    Assert-StartupLogVersion -StderrText $exchange.Stderr -Version $Version -ProgramSourcePath $ProgramSourcePath
}

# All three smoke tests against the staged exe.
function Invoke-SmokeTests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StageDir, [Parameter(Mandatory)][hashtable]$Release,
        [Parameter(Mandatory)][string]$ClassesPath, [Parameter(Mandatory)][string]$RegistryPath, [Parameter(Mandatory)][string]$ProgramSourcePath
    )
    $exe = Join-Path $StageDir 'bin\TestStandMCP.exe'
    Assert-VersionOutput -ExePath $exe -Version $Release.version -Tag $Release.tag -Commit $Release.commit
    Assert-ToolList -ExePath $exe -ClassesPath $ClassesPath -RegistryPath $RegistryPath
    Assert-InitializeRoundTrip -ExePath $exe -Version $Release.version -ProgramSourcePath $ProgramSourcePath
}

Export-ModuleMember -Function Assert-VersionOutput, Assert-ToolList, Assert-StartupLogVersion, Assert-InitializeRoundTrip, Invoke-SmokeTests
