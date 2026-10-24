# ============================================================================
#  PluginArchive.psm1 - what build/Build-PluginArchive.ps1 does, one function per stage so each
#  stage can be tested on its own:
#    1. the inputs (version, tag, commit, layout) and the source checks that need no build;
#    2. dotnet publish in the chosen exe layout, and the proof that the exe carries the version.
#  The ONE layout table below holds everything that differs per exe layout.
#  Every failure goes through Write-BuildFailure (What / Why / Fix).
#  Compatible with Windows PowerShell 5.1 and PowerShell 7 (no PowerShell 7 is installed on the
#  maintainer's station, so nothing here may need it).
# ============================================================================
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'ToolClassification.psm1')

$script:HostPath = (Get-Process -Id $PID).Path   # the PowerShell that runs this module also runs the child scripts
$script:SkillCheckScript = Join-Path $PSScriptRoot 'Test-SkillSources.ps1'

$script:ProjectFile = 'TestStandMCP.csproj'
$script:ExeName = 'TestStandMCP.exe'
$script:RuntimeIdentifier = 'win-x86'
$script:BuildPlatform = 'x86'
$script:BuildConfiguration = 'Release'
$script:PublishTimeoutSeconds = 900
$script:SkillCheckTimeoutSeconds = 180
$script:MaxOutputLinesShown = 25

# ----------------------------------------------------------------------------
#  The exe layouts. 'folder' is the default (docs/validation/self-contained-x86.md): the
#  TestStand engine resolves the .NET runtime from the host's runtimeconfig.json, so a layout that
#  has none on disk is not self-contained against the engine. Everything that differs per layout:
#    PublishArguments : the extra dotnet publish arguments;
#    BinRequired      : files bin/ must hold besides the exe and appsettings.json;
#    BinForbidden     : files bin/ must NOT hold (they would show a different layout was built).
# ----------------------------------------------------------------------------
$script:DefaultLayout = 'folder'
$script:ArchiveLayouts = [ordered]@{
    'folder'              = @{ PublishArguments = @('--self-contained', 'true'); BinRequired = @('TestStandMCP.runtimeconfig.json', 'coreclr.dll'); BinForbidden = @() }
    'single-file'         = @{ PublishArguments = @('--self-contained', 'true', '-p:PublishSingleFile=true'); BinRequired = @(); BinForbidden = @('TestStandMCP.runtimeconfig.json', 'coreclr.dll') }
    'framework-dependent' = @{ PublishArguments = @('--self-contained', 'false'); BinRequired = @('TestStandMCP.runtimeconfig.json'); BinForbidden = @('coreclr.dll') }
}

function Get-ArchiveLayoutName {
    [CmdletBinding()]
    param()
    return @($script:ArchiveLayouts.Keys)
}

function Get-DefaultArchiveLayout {
    [CmdletBinding()]
    param()
    return $script:DefaultLayout
}

function Get-ArchiveLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:ArchiveLayouts.Contains($Name)) {
        Write-BuildFailure -What "Unknown exe layout '$Name'." `
            -Why 'The layout decides how the exe is published and which files the archive must hold, so there is no safe guess.' `
            -Fix "Pass -Layout with one of: $((Get-ArchiveLayoutName) -join ', ') (default: $script:DefaultLayout)."
    }
    return $script:ArchiveLayouts[$Name]
}

# ----------------------------------------------------------------------------
#  Inputs
# ----------------------------------------------------------------------------
$script:VersionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?\z'
$script:CommitPattern = '\A[0-9a-f]{40}\z'

# X.Y.Z with an optional pre-release suffix (0.0.0-ci for a local or pull-request build).
function Assert-BuildVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Version)
    if ($Version -cnotmatch $script:VersionPattern) {
        Write-BuildFailure -What "The version '$Version' is not X.Y.Z (or X.Y.Z-suffix)." `
            -Why 'The version is stamped into the exe, the plugin manifest and the archive names; a malformed one would publish a release nobody can update to.' `
            -Fix 'Pass -Version 1.9.0 (no leading v), or -Version 0.0.0-ci for a local build.'
    }
}

# The numeric X.Y.Z of a version: the release tag format, the versioned archive name and the release
# verifier know only that part, so a pre-release build (0.0.0-ci) names its assets after it.
function Get-VersionCore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)
    Assert-BuildVersion $Version
    return ($Version -split '-', 2)[0]
}

function Assert-BuildCommit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Commit)
    if ($Commit -cnotmatch $script:CommitPattern) {
        Write-BuildFailure -What "The commit '$Commit' is not a full 40-character SHA." `
            -Why 'The commit is stamped into the exe (SourceRevisionId) and into VERSION.txt, and --version prints it, so an abbreviation could not be told apart later.' `
            -Fix 'Pass -Commit with the output of: git rev-parse HEAD'
    }
}

# The tag stamped into VERSION.txt: v<version>, or a rehearsal of it (v<version>-rehearsal).
function Assert-BuildTag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tag, [Parameter(Mandatory)][string]$Version)
    if (-not $Tag.StartsWith("v$Version", [StringComparison]::Ordinal) -or $Tag -cnotmatch '\Av[0-9A-Za-z][0-9A-Za-z.+-]*\z') {
        Write-BuildFailure -What "The tag '$Tag' does not belong to version $Version." `
            -Why 'VERSION.txt and --version print the tag next to the version; a tag that disagrees with it would mislabel the release.' `
            -Fix "Pass -Tag v$Version, or omit -Tag."
    }
}

# ----------------------------------------------------------------------------
#  Source checks: everything that can be refused before a minute-long publish
# ----------------------------------------------------------------------------
function Select-FailureLines {
    param([AllowEmptyString()][string]$Text, [string]$Pattern = '.')
    return @(($Text -split '\r?\n') | Where-Object { $_ -match $Pattern } | Select-Object -First $script:MaxOutputLinesShown)
}

# The skill source check (Test-SkillSources.ps1): the rules skill, its imports and the moved headings.
function Assert-SkillSources {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $result = Invoke-ChildProcess -FilePath $script:HostPath -TimeoutSeconds $script:SkillCheckTimeoutSeconds `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:SkillCheckScript, '-RepoRoot', $RepoRoot)
    if ($result.TimedOut) {
        Write-BuildFailure -What "The skill source check did not finish within $script:SkillCheckTimeoutSeconds s and was stopped." `
            -Why 'Without its verdict the archive could ship a rules skill that disagrees with its sources. Running it again may help only if the machine was busy.' `
            -Fix "Run it by hand to see where it stalls: powershell -NoProfile -File build\Test-SkillSources.ps1"
    }
    if ($result.ExitCode -eq 0) { return }
    $failed = (Select-FailureLines $result.Stdout '^(FAIL|\s{6}\S)') -join "`n"
    Write-BuildFailure -What "The skill source check (build\Test-SkillSources.ps1) failed:`n$failed" `
        -Why 'The archive ships the teststand-rules skill and a bin/CLAUDE.md built from it; a skill that breaks its own source rules would publish rules that disagree with the repository.' `
        -Fix 'Run powershell -NoProfile -File build\Test-SkillSources.ps1, fix what it reports, and run the packaging again.'
}

# Every tool the server registers is on purpose allowed or prompted (plugin/hooks/tool-classes.json).
function Assert-AllToolsClassified {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClassesPath, [Parameter(Mandatory)][string]$RegistryPath)
    Assert-ToolClassification -Classes (Read-ToolClasses -Path $ClassesPath) `
        -RegisteredTools (Get-RegisteredToolNames -RegistryPath $RegistryPath) `
        -ClassesPath $ClassesPath -ToolParameters (Get-RegisteredToolParameters -RegistryPath $RegistryPath)
}

# The plugin.json that is committed carries "version": "0.0.0"; the staging step replaces exactly that.
$script:VersionPlaceholderPattern = '"version"\s*:\s*"0\.0\.0"'

# The single placeholder match in the manifest text; fails when there is none or more than one.
function Find-VersionPlaceholder {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Path)
    $found = @([regex]::Matches($Text, $script:VersionPlaceholderPattern))
    if ($found.Count -ne 1) {
        Write-BuildFailure -What "$Path holds $($found.Count) occurrences of `"version`": `"0.0.0`" instead of exactly one." `
            -Why 'The build replaces that placeholder with the release version. Without it the stamped manifest could not be proven identical to the source apart from the version, and a hand-edited version would ship unchanged.' `
            -Fix 'Restore the committed manifest: git checkout -- plugin/.claude-plugin/plugin.json (the version stays "0.0.0" in git).'
    }
    return $found[0]
}

function Assert-ManifestPlaceholder {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath)
    [void](Find-VersionPlaceholder -Text (Read-Utf8Text $ManifestPath) -Path $ManifestPath)
}

# All source checks, in order, before anything is built.
function Invoke-SourceChecks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    Assert-SkillSources -RepoRoot $RepoRoot
    Assert-AllToolsClassified -ClassesPath (Join-Path $RepoRoot 'plugin\hooks\tool-classes.json') `
        -RegistryPath (Join-Path $RepoRoot 'src\Tools\TestStandToolRegistry.cs')
    Assert-ManifestPlaceholder -ManifestPath (Join-Path $RepoRoot 'plugin\.claude-plugin\plugin.json')
}

# ----------------------------------------------------------------------------
#  Publish
# ----------------------------------------------------------------------------
# dotnet publish into a fresh directory; returns the path of the published exe.
function Publish-PluginExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Layout,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$PublishDir
    )
    $layoutSettings = Get-ArchiveLayout $Layout
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $dotnet) {
        Write-BuildFailure -What 'dotnet was not found on the PATH.' `
            -Why 'The exe is built with dotnet publish.' `
            -Fix 'Install the .NET SDK (https://dotnet.microsoft.com/download), open a new shell and run the packaging again.'
    }
    Remove-BuildTempTree -Path $PublishDir
    if (Test-Path -LiteralPath $PublishDir) {
        Write-BuildFailure -What "The old publish directory $PublishDir could not be removed." `
            -Why 'Publishing over leftovers could ship files of an earlier build.' `
            -Fix 'Close whatever holds files in it (a running TestStandMCP.exe from that folder) and delete it by hand.'
    }
    $arguments = @('publish', (Join-Path $RepoRoot $script:ProjectFile), '-c', $script:BuildConfiguration,
        "-p:Platform=$script:BuildPlatform", '-r', $script:RuntimeIdentifier) + @($layoutSettings.PublishArguments) +
        @("-p:Version=$Version", "-p:SourceRevisionId=$Commit", '-o', $PublishDir, '--nologo', '-v:minimal', '--disable-build-servers')
    $result = Invoke-ChildProcess -FilePath $dotnet.Source -ArgumentList $arguments -WorkingDirectory $RepoRoot -TimeoutSeconds $script:PublishTimeoutSeconds
    $shown = (Select-FailureLines ($result.Stdout + "`n" + $result.Stderr) '\S' | Select-Object -Last $script:MaxOutputLinesShown) -join "`n"
    if ($result.TimedOut) {
        Write-BuildFailure -What "dotnet publish did not finish within $script:PublishTimeoutSeconds s and was stopped.`n$shown" `
            -Why 'Without the exe nothing can be packaged. Running it again may help if the machine was busy or the NuGet feed was slow.' `
            -Fix 'Run the same dotnet publish command by hand (dotnet publish TestStandMCP.csproj -c Release -p:Platform=x86 -r win-x86) to see where it stalls.'
    }
    if ($result.ExitCode -ne 0) {
        Write-BuildFailure -What "dotnet publish failed (exit code $($result.ExitCode)):`n$shown" `
            -Why 'Without the exe nothing can be packaged.' `
            -Fix 'Fix the build error above. To reproduce: dotnet publish TestStandMCP.csproj -c Release -p:Platform=x86 -r win-x86'
    }
    $exePath = Join-Path $PublishDir $script:ExeName
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        Write-BuildFailure -What "dotnet publish succeeded but $script:ExeName is not in $PublishDir." `
            -Why 'The apphost is what the plugin starts (plugin/.mcp.json names bin/TestStandMCP.exe).' `
            -Fix 'Check that the project still has OutputType Exe and AssemblyName TestStandMCP.'
    }
    return $exePath
}

# The exe's ProductVersion is the version stamped at build time: "<version>+<commit>".
function Assert-PublishedVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Commit
    )
    $actual = [Diagnostics.FileVersionInfo]::GetVersionInfo((Resolve-BuildPath $ExePath)).ProductVersion
    $expected = "$Version+$Commit"
    if ($actual -cne $expected) {
        Write-BuildFailure -What "The published exe reports ProductVersion '$actual' but version $Version at commit $Commit was requested (expected '$expected')." `
            -Why 'The exe is what users run and what --version, serverInfo and the startup log report; shipping one that names another version would make every later update check wrong.' `
            -Fix 'Check that nothing overrides the Version or SourceRevisionId MSBuild properties (Directory.Build.props, environment variables), then run the packaging again.'
    }
}

Export-ModuleMember -Function Get-ArchiveLayoutName, Get-DefaultArchiveLayout, Get-ArchiveLayout,
    Assert-BuildVersion, Get-VersionCore, Assert-BuildCommit, Assert-BuildTag,
    Assert-SkillSources, Assert-AllToolsClassified, Find-VersionPlaceholder, Assert-ManifestPlaceholder, Invoke-SourceChecks,
    Publish-PluginExe, Assert-PublishedVersion
