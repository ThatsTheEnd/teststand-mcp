# ============================================================================
#  PluginArchive.psm1 - what build/Build-PluginArchive.ps1 does, one function per stage so each
#  stage can be tested on its own:
#    1. the inputs (version, tag, commit, layout) and the source checks that need no build;
#    2. dotnet publish in the chosen exe layout, and the proof that the exe carries the version;
#    3. staging: the archive's directory tree, the converted agents, the stamped plugin.json,
#       bin/CLAUDE.md with the skill inlined and VERSION.txt, and every assertion on that tree.
#  The ONE layout table holds everything that differs per exe layout; the ONE staging table drives
#  both what is staged and what is asserted.
#  Every failure goes through Write-BuildFailure (What / Why / Fix).
#  Compatible with Windows PowerShell 5.1 and PowerShell 7 (no PowerShell 7 is installed on the
#  maintainer's station, so nothing here may need it).
# ============================================================================
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'ToolClassification.psm1')
Import-Module (Join-Path $PSScriptRoot 'PluginIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot 'ReleaseAssets.psm1')

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
    Assert-ManifestPlaceholder -ManifestPath (Join-Path $RepoRoot $script:PluginManifestPath)
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

# ----------------------------------------------------------------------------
#  The release record: what VERSION.txt carries
# ----------------------------------------------------------------------------
# The URL of the CI run that builds the archive, or 'local' outside GitHub Actions.
function Get-RunUrl {
    [CmdletBinding()]
    param()
    if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
        return "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
    }
    return 'local'
}

function New-ReleaseRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Commit)
    return @{
        tag     = $Tag
        version = $Version
        commit  = $Commit
        built   = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        run     = (Get-RunUrl)
    }
}

# ----------------------------------------------------------------------------
#  The staging table: ONE table drives both what is staged and what is asserted (spec AC-4, AC-5).
#  A row describes one directory of the archive:
#    Target    the directory inside the archive ('.' is the archive root);
#    Source    where its files come from: a repository folder, ':publish' (the dotnet publish
#              output) or $null (generated, or staged by another row);
#    Copy      'All' (every file below Source, minus the top-level names in Exclude), 'Listed'
#              (just the names in Exact) or 'None';
#    Required  files (relative to Target) that must exist;
#    Forbidden files that must NOT exist;
#    Exact     the COMPLETE set of files the directory may hold (null = not checked);
#    Why/Fix   what a violation means and how to repair it.
# ----------------------------------------------------------------------------
$script:HookFiles = @('allow-readonly.ps1', 'hook-common.ps1', 'hooks.json', 'platform-guard.ps1', 'tool-classes.json', 'update-notify.ps1')
$script:DocScriptFiles = @('generate_teststand_doc.py', 'generate_teststand_presentation.py', 'presentation_template.html')
$script:BinCopyExclude = @('CLAUDE.md', 'README.md', 'scripts', '.claude')   # staged from the repository, not from the publish output
$script:SourceAgentDir = '.claude\agents'
$script:PluginManifestPath = 'plugin\.claude-plugin\plugin.json'

function New-StagingRow {
    param(
        [Parameter(Mandatory)][string]$Target, $Source = $null, [string]$Copy = 'None', [string[]]$Exclude = @(),
        [string[]]$Required = @(), [string[]]$Forbidden = @(), $Exact = $null, [string]$Why = '', [string]$Fix = ''
    )
    return [pscustomobject]@{ Target = $Target; Source = $Source; Copy = $Copy; Exclude = $Exclude; Required = $Required; Forbidden = $Forbidden; Exact = $Exact; Why = $Why; Fix = $Fix }
}

# The names (relative to $Dir, forward slashes, ordinal order) of every file below a directory.
function Get-FileSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)
    $resolved = Resolve-BuildPath $Dir
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return , [string[]]@() }
    $root = [IO.Path]::GetFullPath($resolved).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $names = [string[]]@(Get-ChildItem -LiteralPath $resolved -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($root.Length).Replace('\', '/') })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return , $names
}

function Get-StagingTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Layout)
    $layoutSettings = Get-ArchiveLayout $Layout
    $agentDir = Join-Path $RepoRoot $script:SourceAgentDir
    $sourceAgents = [string[]]@(Get-ChildItem -LiteralPath $agentDir -File -Filter '*.md' | ForEach-Object { $_.Name } | Sort-Object { $_ })
    $agentFiles = Get-FileSet $agentDir
    return @(
        (New-StagingRow -Target '.' -Source 'plugin' -Copy 'All' `
            -Required @('.claude-plugin/plugin.json', '.mcp.json', 'VERSION.txt', 'skills/teststand-rules/SKILL.md') `
            -Why 'The archive layout requires it (spec AC-4); without it Claude Code cannot load the plugin or start its server.' `
            -Fix 'Run the packaging again. If the file is a source file, restore it with git checkout -- plugin/<path>.'),
        (New-StagingRow -Target 'hooks' -Exact $script:HookFiles `
            -Why 'hooks/ is what Claude Code runs on the user''s machine on every session start and tool call. It must hold exactly the runtime hook files, never a test, a build script or a leftover.' `
            -Fix 'Remove the unexpected file from plugin/hooks, or add a new runtime hook to $script:HookFiles in build/PluginArchive.psm1; restore a missing one with git checkout -- plugin/hooks.'),
        (New-StagingRow -Target 'agents' -Exact $sourceAgents `
            -Why 'The plugin ships one converted agent per source agent (spec AC-5); a different number means an agent was dropped or one was added without a source.' `
            -Fix 'Run the packaging again; the plugin agents are generated from .claude/agents, so fix the source folder, never agents/.'),
        (New-StagingRow -Target 'bin' -Source ':publish' -Copy 'All' -Exclude $script:BinCopyExclude `
            -Required (@('TestStandMCP.exe', 'appsettings.json', 'CLAUDE.md') + @($layoutSettings.BinRequired)) -Forbidden @($layoutSettings.BinForbidden) `
            -Why "The exe layout '$Layout' requires these files (and none of the forbidden ones); a layout with a missing runtime file does not start on the user's station." `
            -Fix "Run the packaging again with -Layout $Layout; if it repeats, compare the dotnet publish output with the layout table in build/PluginArchive.psm1."),
        (New-StagingRow -Target 'bin/scripts' -Source 'scripts' -Copy 'Listed' -Exact $script:DocScriptFiles `
            -Why 'The archive ships only the documentation and presentation generators and their template. A maintainer script would run from a user''s installation and expose paths nobody should depend on.' `
            -Fix 'Remove the unexpected file from the staged tree, or add a generator deliberately to $script:DocScriptFiles in build/PluginArchive.psm1.'),
        (New-StagingRow -Target 'bin/.claude/agents' -Source $script:SourceAgentDir -Copy 'All' -Exact $agentFiles `
            -Why 'The direct installation route (link-agents.bat) needs the source agents unchanged next to the exe (spec AC-5).' `
            -Fix 'Run the packaging again; bin/.claude/agents is copied from .claude/agents.')
    )
}

# ----------------------------------------------------------------------------
#  Staging
# ----------------------------------------------------------------------------
# Copies the files below $SourceDir to $DestDir (same relative paths), skipping top-level names in
# $Exclude and, when $OnlyNames is given, every file not named there.
function Copy-FileTree {
    param([string]$SourceDir, [string]$DestDir, [string[]]$Exclude = @(), [string[]]$OnlyNames = $null)
    foreach ($relative in (Get-FileSet $SourceDir)) {
        if ($Exclude -contains ($relative -split '/')[0]) { continue }
        if ($null -ne $OnlyNames -and $OnlyNames -cnotcontains $relative) { continue }
        $destination = Join-Path $DestDir $relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
        Copy-Item -LiteralPath (Join-Path $SourceDir $relative) -Destination $destination -Force
    }
}

# A file's bytes read as ISO-8859-1: one char per byte, so a text edit can never change another byte.
$script:ByteTextEncoding = [Text.Encoding]::GetEncoding(28591)

# plugin.json: the committed text with ONLY the placeholder's value replaced by the version.
function Write-StampedManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$DestPath, [Parameter(Mandatory)][string]$Version)
    $text = $script:ByteTextEncoding.GetString([IO.File]::ReadAllBytes($SourcePath))
    $placeholder = Find-VersionPlaceholder -Text $text -Path $SourcePath
    $stamped = $placeholder.Value -replace '"0\.0\.0"\z', ('"' + $Version + '"')
    $result = $text.Remove($placeholder.Index, $placeholder.Length).Insert($placeholder.Index, $stamped)
    [IO.File]::WriteAllBytes($DestPath, $script:ByteTextEncoding.GetBytes($result))
}

# The staged manifest equals the source byte for byte once its version is put back.
function Assert-StampedManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$StagedPath, [Parameter(Mandatory)][string]$Version)
    $source = $script:ByteTextEncoding.GetString([IO.File]::ReadAllBytes($SourcePath))
    $staged = $script:ByteTextEncoding.GetString([IO.File]::ReadAllBytes($StagedPath))
    $sourceToken = (Find-VersionPlaceholder -Text $source -Path $SourcePath).Value
    $stagedTokens = @([regex]::Matches($staged, '"version"\s*:\s*"' + [regex]::Escape($Version) + '"'))
    $restored = $null
    if ($stagedTokens.Count -eq 1) { $restored = $staged.Remove($stagedTokens[0].Index, $stagedTokens[0].Length).Insert($stagedTokens[0].Index, $sourceToken) }
    if ($restored -cne $source) {
        Write-BuildFailure -What "The staged plugin.json is not the source with only `"version`": `"$Version`" changed (it holds $($stagedTokens.Count) such version entries)." `
            -Why 'Claude Code takes the plugin version from plugin.json; a manifest that differs from the reviewed source in anything else would ship an unreviewed change.' `
            -Fix 'Run the packaging again; it stamps the manifest from plugin/.claude-plugin/plugin.json.'
    }
}

# ---- VERSION.txt: key: value lines, the format src/VersionInfo.cs reads ----------------------
$script:VersionTxtKeys = @('tag', 'version', 'commit', 'built', 'run')

function Write-VersionTxt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Values)
    $lines = @($script:VersionTxtKeys | ForEach-Object { "${_}: $($Values[$_])" })
    [IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), (Get-Utf8NoBomEncoding))
}

function Read-VersionTxtValues {
    param([string]$Path)
    $values = @{}
    foreach ($line in ((Read-Utf8Text $Path) -split '\r?\n')) {
        $separator = $line.IndexOf(':')
        if ($separator -le 0) { continue }
        $values[$line.Substring(0, $separator).Trim()] = $line.Substring($separator + 1).Trim()
    }
    return $values
}

function Assert-VersionTxt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Expected)
    $values = Read-VersionTxtValues $Path
    $missing = @($script:VersionTxtKeys | Where-Object { -not $values.ContainsKey($_) -or $values[$_].Length -eq 0 })
    if ($missing.Count -gt 0) {
        Write-BuildFailure -What "VERSION.txt lacks $($missing -join ', ') (it must carry $($script:VersionTxtKeys -join ', '))." `
            -Why '--version prints these lines, and the exe reports "release metadata incomplete" when the tag is missing.' `
            -Fix 'Run the packaging again; VERSION.txt is written by it and must never be edited by hand.'
    }
    foreach ($key in @('tag', 'version', 'commit')) {
        if ($values[$key] -cne $Expected[$key]) {
            Write-BuildFailure -What "VERSION.txt says $key '$($values[$key])' but '$($Expected[$key])' was requested." `
                -Why 'The archive would name a different release than the one being built.' `
                -Fix 'Run the packaging again.'
        }
    }
}

# ---- agents -------------------------------------------------------------------------------
# The plugin flavour of every source agent (spec AC-5), written to <StageDir>/agents.
function Write-PluginAgents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$StageDir, [Parameter(Mandatory)]$Identity)
    $targetDir = Join-Path $StageDir 'agents'
    [void](New-Item -ItemType Directory -Path $targetDir -Force)
    foreach ($agent in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot $script:SourceAgentDir) -File -Filter '*.md' | Sort-Object Name)) {
        try {
            $text = ConvertTo-PluginAgent -Path $agent.FullName -Identity $Identity
        } catch {
            Write-BuildFailure -What "The agent $($agent.Name) cannot be converted to the plugin flavour: $($_.Exception.Message)" `
                -Why 'The plugin ships the converted agents; one that does not convert would ship tool names a plugin install does not have.' `
                -Fix "Fix .claude/agents/$($agent.Name) (the mapping rules are in build/PluginIdentity.psm1), then run the packaging again."
        }
        [IO.File]::WriteAllText((Join-Path $targetDir $agent.Name), $text, (Get-Utf8NoBomEncoding))
    }
}

# No plugin agent names the direct tool prefix or CLAUDE.md (a plugin install has neither); the direct agents are unchanged.
function Assert-AgentFlavours {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$StageDir, [Parameter(Mandatory)]$Identity)
    $pluginAgents = Get-FileSet (Join-Path $StageDir 'agents')
    foreach ($forbidden in @($Identity.directToolPrefix, 'CLAUDE.md')) {
        foreach ($name in $pluginAgents) {
            if ((Read-Utf8Text (Join-Path $StageDir "agents/$name")).IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Write-BuildFailure -What "The plugin agent agents/$name still contains '$forbidden'." `
                    -Why 'A plugin install has no direct MCP server of that name and no CLAUDE.md, so the agent would call tools that do not exist or read rules that are not there.' `
                    -Fix "Map the term in build/PluginIdentity.psm1 (Get-AgentMappingTable) or remove it from .claude/agents/$name, then run the packaging again."
            }
        }
    }
    foreach ($name in (Get-FileSet (Join-Path $RepoRoot $script:SourceAgentDir))) {
        $staged = Join-Path $StageDir "bin/.claude/agents/$name"
        if (-not (Test-Path -LiteralPath $staged) -or (Get-FileSha256 (Join-Path $RepoRoot "$script:SourceAgentDir\$name")) -cne (Get-FileSha256 $staged)) {
            Write-BuildFailure -What "bin/.claude/agents/$name is missing or differs from .claude/agents/$name." `
                -Why 'The direct installation route (link-agents.bat) must find the source agents unchanged.' `
                -Fix 'Run the packaging again.'
        }
    }
}

# ---- bin/CLAUDE.md ------------------------------------------------------------------------
$script:ImportsBeginMarker = '<!-- skill-imports:begin -->'
$script:ImportsEndMarker = '<!-- skill-imports:end -->'
$script:ImportLinePattern = '\A@(\S+)\s*\z'
$script:FencePattern = '\A\s*```'
$script:FrontmatterBlockPattern = '(?s)\A' + [regex]::Escape([string][char]0xFEFF) + '?---\r?\n.*?\r?\n---\r?\n'

# The lines of a text that are @path imports, outside code fences: { Number; Path }.
function Get-ImportLine {
    param([string[]]$Lines)
    $inFence = $false
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match $script:FencePattern) { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        $import = [regex]::Match($Lines[$index], $script:ImportLinePattern)
        if ($import.Success) { [pscustomobject]@{ Number = $index + 1; Path = $import.Groups[1].Value } }
    }
}

# A skill file's text for inlining: BOM and YAML frontmatter dropped, LF line ends, no trailing blank lines.
function Read-SkillFileText {
    param([string]$Path)
    $text = [regex]::Replace((Read-Utf8Text $Path), $script:FrontmatterBlockPattern, '')
    return ($text.TrimStart([char]0xFEFF) -replace '\r\n', "`n").TrimEnd()
}

# CLAUDE.md with the block between the skill-import markers replaced by the text of every imported
# file, in order. The rest (the developer sections) is kept, as the direct route always had it.
function ConvertTo-ResolvedClaudeMd {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $lines = @((Read-Utf8Text (Join-Path $RepoRoot 'CLAUDE.md')).TrimStart([char]0xFEFF) -split '\r?\n')
    $begin = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -ceq $script:ImportsBeginMarker })
    $end = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -ceq $script:ImportsEndMarker })
    if ($begin.Count -ne 1 -or $end.Count -ne 1 -or $end[0] - $begin[0] -lt 2) {
        Write-BuildFailure -What "CLAUDE.md does not hold exactly one '$script:ImportsBeginMarker' before exactly one '$script:ImportsEndMarker' with lines between them." `
            -Why 'The packaging swaps that block for the skill text; without the markers it cannot tell what to inline, and bin/CLAUDE.md would keep dangling @ imports.' `
            -Fix 'Restore the markers around the @plugin/skills/teststand-rules/... lines of CLAUDE.md (see build/Test-SkillSources.ps1).'
    }
    $imports = @(Get-ImportLine @($lines[($begin[0] + 1)..($end[0] - 1)]))
    if ($imports.Count -eq 0) {
        Write-BuildFailure -What 'CLAUDE.md has no @ import between its skill-import markers.' `
            -Why 'bin/CLAUDE.md would then carry no rules at all.' -Fix 'Restore the @plugin/skills/teststand-rules/... import lines.'
    }
    $inlined = @($imports | ForEach-Object {
        $importPath = Join-Path $RepoRoot $_.Path
        if (-not (Test-Path -LiteralPath $importPath -PathType Leaf)) {
            Write-BuildFailure -What "CLAUDE.md imports @$($_.Path) but $importPath does not exist." `
                -Why 'The import cannot be inlined, so bin/CLAUDE.md would lose part of the rules.' -Fix 'Fix the import path or restore the file.'
        }
        Read-SkillFileText $importPath
    })
    $before = @($lines[0..($begin[0] - 1)])
    $after = if ($end[0] -lt $lines.Count - 1) { @($lines[($end[0] + 1)..($lines.Count - 1)]) } else { @() }
    return ((@($before) + ($inlined -join "`n`n") + @($after)) -join "`n")
}

# No @ import is left, and the skill text is really inside.
function Assert-ClaudeMdResolved {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SkillMdPath)
    $text = Read-Utf8Text $Path
    $left = @(Get-ImportLine @($text -split '\r?\n'))
    if ($left.Count -gt 0) {
        $shown = ($left | Select-Object -First 3 | ForEach-Object { "line $($_.Number) @$($_.Path)" }) -join '; '
        Write-BuildFailure -What "bin/CLAUDE.md still contains $($left.Count) unresolved import(s): $shown" `
            -Why 'An installed copy has no such file next to it, so the rules would silently not load.' `
            -Fix 'Run the packaging again; bin/CLAUDE.md is generated from CLAUDE.md with every import inlined.'
    }
    $firstSkillLine = @((Read-SkillFileText $SkillMdPath) -split "`n" | Where-Object { $_.Trim().Length -gt 0 })[0]
    if ($text.IndexOf($firstSkillLine, [StringComparison]::Ordinal) -lt 0) {
        Write-BuildFailure -What "bin/CLAUDE.md does not contain the skill text (its first line '$firstSkillLine' is missing)." `
            -Why 'The direct installation route reads its rules from bin/CLAUDE.md; without the skill text it would have none.' `
            -Fix 'Run the packaging again.'
    }
}

# ----------------------------------------------------------------------------
#  Stage and assert
# ----------------------------------------------------------------------------
function Get-StagingIdentity {
    param([string]$RepoRoot)
    return Get-PluginIdentity -PluginJsonPath (Join-Path $RepoRoot $script:PluginManifestPath) -McpJsonPath (Join-Path $RepoRoot 'plugin\.mcp.json')
}

# Builds the archive's directory tree from the publish output and the repository.
# $Release: the VERSION.txt values (tag, version, commit, built, run).
function New-StagedPlugin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$PublishDir, [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][string]$Layout, [Parameter(Mandatory)][hashtable]$Release
    )
    $identity = Get-StagingIdentity $RepoRoot
    Remove-BuildTempTree -Path $StageDir
    [void](New-Item -ItemType Directory -Path $StageDir -Force)
    foreach ($row in (Get-StagingTable -RepoRoot $RepoRoot -Layout $Layout)) {
        if ($null -eq $row.Source) { continue }
        $sourceDir = if ($row.Source -ceq ':publish') { $PublishDir } else { Join-Path $RepoRoot $row.Source }
        $onlyNames = if ($row.Copy -ceq 'Listed') { [string[]]$row.Exact } else { $null }
        Copy-FileTree -SourceDir $sourceDir -DestDir (Join-Path $StageDir $row.Target) -Exclude $row.Exclude -OnlyNames $onlyNames
    }
    Write-StampedManifest -SourcePath (Join-Path $RepoRoot $script:PluginManifestPath) -DestPath (Join-Path $StageDir '.claude-plugin\plugin.json') -Version $Release.version
    Write-PluginAgents -RepoRoot $RepoRoot -StageDir $StageDir -Identity $identity
    [IO.File]::WriteAllText((Join-Path $StageDir 'bin\CLAUDE.md'), (ConvertTo-ResolvedClaudeMd -RepoRoot $RepoRoot), (Get-Utf8NoBomEncoding))
    Write-VersionTxt -Path (Join-Path $StageDir 'VERSION.txt') -Values $Release
}

function Assert-StagingRow {
    param($Row, [string]$StageDir)
    $dir = if ($Row.Target -ceq '.') { $StageDir } else { Join-Path $StageDir $Row.Target }
    $present = Get-FileSet $dir
    $label = if ($Row.Target -ceq '.') { 'the archive root' } else { "$($Row.Target)/" }
    foreach ($name in $Row.Required) {
        if ($present -cnotcontains $name) {
            Write-BuildFailure -What "The staged tree is missing $name in $label" -Why $Row.Why -Fix $Row.Fix
        }
    }
    foreach ($name in $Row.Forbidden) {
        if ($present -ccontains $name) {
            Write-BuildFailure -What "The staged tree holds $name in $label, which belongs to another exe layout." -Why $Row.Why -Fix $Row.Fix
        }
    }
    if ($null -eq $Row.Exact) { return }
    $unexpected = @($present | Where-Object { $Row.Exact -cnotcontains $_ })
    $missing = @($Row.Exact | Where-Object { $present -cnotcontains $_ })
    if ($unexpected.Count -eq 0 -and $missing.Count -eq 0) { return }
    $detail = @()
    if ($unexpected.Count -gt 0) { $detail += "unexpected: $($unexpected -join ', ')" }
    if ($missing.Count -gt 0) { $detail += "missing: $($missing -join ', ')" }
    Write-BuildFailure -What "$label holds $($present.Count) file(s) but exactly $(@($Row.Exact).Count) are expected ($($detail -join '; '))." -Why $Row.Why -Fix $Row.Fix
}

# Every layout, agent, manifest, VERSION.txt and CLAUDE.md assertion on a staged tree.
function Assert-StagedPlugin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][string]$Layout, [Parameter(Mandatory)][hashtable]$Release
    )
    foreach ($row in (Get-StagingTable -RepoRoot $RepoRoot -Layout $Layout)) { Assert-StagingRow -Row $row -StageDir $StageDir }
    Assert-StampedManifest -SourcePath (Join-Path $RepoRoot $script:PluginManifestPath) -StagedPath (Join-Path $StageDir '.claude-plugin\plugin.json') -Version $Release.version
    Assert-VersionTxt -Path (Join-Path $StageDir 'VERSION.txt') -Expected $Release
    Assert-AgentFlavours -RepoRoot $RepoRoot -StageDir $StageDir -Identity (Get-StagingIdentity $RepoRoot)
    Assert-ClaudeMdResolved -Path (Join-Path $StageDir 'bin\CLAUDE.md') -SkillMdPath (Join-Path $RepoRoot 'plugin\skills\teststand-rules\SKILL.md')
}

Export-ModuleMember -Function Get-ArchiveLayoutName, Get-DefaultArchiveLayout, Get-ArchiveLayout,
    Assert-BuildVersion, Get-VersionCore, Assert-BuildCommit, Assert-BuildTag,
    Assert-SkillSources, Assert-AllToolsClassified, Find-VersionPlaceholder, Assert-ManifestPlaceholder, Invoke-SourceChecks,
    Publish-PluginExe, Assert-PublishedVersion,
    Get-RunUrl, New-ReleaseRecord, Get-FileSet, Get-StagingTable, New-StagedPlugin, Write-StampedManifest, Assert-StagedPlugin, Assert-StampedManifest, Assert-VersionTxt, Assert-AgentFlavours,
    ConvertTo-ResolvedClaudeMd, Assert-ClaudeMdResolved
