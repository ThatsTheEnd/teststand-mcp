# ============================================================================
#  Build-PluginArchive.ps1 - builds the plugin archive (teststand-mcp.zip) from this checkout:
#    1. refuses a malformed version, tag, commit or layout;
#    2. runs the source checks that need no build (skill sources, tool classification, the
#       plugin.json version placeholder);
#    3. dotnet publish in the chosen exe layout, and proves the exe carries the version;
#    4. stages the archive tree (converted agents, stamped plugin.json, bin/CLAUDE.md with the skill
#       inlined, VERSION.txt) and asserts the layout, the agent flavours and the version stamp;
#    5. smoke-tests the STAGED exe: --version, --list-tools --json, a stdio initialize round trip;
#    6. zips the tree (forward-slash entry names, written entry by entry) and checks the entry names;
#    7. writes the versioned copy, the digest and the per-file manifest (names from ReleaseAssets.psm1);
#    8. runs build\Assert-PublishedRelease.ps1 in local mode on the result.
#  The assets (teststand-mcp.zip, teststand-mcp-v<X.Y.Z>.zip, .sha256, .manifest.sha256) end up in
#  -OutDir next to the stage\ tree they were built from.
#  Every failure is three parts - what is wrong, why it matters, the command that fixes it -
#  printed to the host, with exit code 1.
#
#  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File build\Build-PluginArchive.ps1 -Version 0.0.0-ci
#  -Version  X.Y.Z, or X.Y.Z-suffix for a local / pull-request build (0.0.0-ci).
#  -Tag      defaults to v<Version>.
#  -Commit   the full 40-character SHA; defaults to git rev-parse HEAD.
#  -OutDir   where everything is written (default: <repo>\artifacts, which git ignores).
#  -Layout   folder (default, see docs/validation/self-contained-x86.md), single-file, framework-dependent.
#  Windows PowerShell 5.1 and PowerShell 7 compatible.
# ============================================================================
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Tag,
    [string]$Commit,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts'),
    [string]$Layout
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReleaseAssets.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PluginArchive.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PluginSmoke.psm1') -Force

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PublishDirName = 'publish'
$StageDirName = 'stage'
$StepClock = [Diagnostics.Stopwatch]::StartNew()
$StepCount = 8

function Write-Step {
    param([int]$Number, [string]$Text)
    Write-Host ("[{0}/{1}] {2} (+{3:N1}s)" -f $Number, $StepCount, $Text, $StepClock.Elapsed.TotalSeconds)
}

# The commit of the checkout, when none was given.
function Get-HeadCommit {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-BuildFailure -What 'No -Commit was given and git was not found.' -Why 'The commit is stamped into the exe and VERSION.txt.' -Fix 'Pass -Commit with the 40-character SHA.'
    }
    $result = Invoke-ChildProcess -FilePath $git.Source -ArgumentList @('-C', $RepoRoot, 'rev-parse', 'HEAD') -TimeoutSeconds 30
    if ($result.ExitCode -ne 0) {
        Write-BuildFailure -What "git rev-parse HEAD failed: $($result.Stderr.Trim())" -Why 'The commit is stamped into the exe and VERSION.txt.' -Fix 'Run from a git checkout, or pass -Commit with the 40-character SHA.'
    }
    return $result.Stdout.Trim()
}

try {
    if (-not $Layout) { $Layout = Get-DefaultArchiveLayout }
    if (-not $Tag) { $Tag = "v$Version" }
    if (-not $Commit) { $Commit = Get-HeadCommit }
    Assert-BuildVersion $Version
    Assert-BuildTag -Tag $Tag -Version $Version
    Assert-BuildCommit $Commit
    [void](Get-ArchiveLayout $Layout)
    $OutDir = Resolve-BuildPath $OutDir
    Write-Host "Packaging version $Version ($Tag, commit $Commit), layout $Layout, into $OutDir"

    Write-Step 1 'Checking the sources'
    Invoke-SourceChecks -RepoRoot $RepoRoot

    Write-Step 2 "Publishing the exe ($Layout)"
    [void](New-Item -ItemType Directory -Path $OutDir -Force)
    $publishDir = Join-Path $OutDir $PublishDirName
    $stageDir = Join-Path $OutDir $StageDirName
    $release = New-ReleaseRecord -Tag $Tag -Version $Version -Commit $Commit
    try {
        $publishedExe = Publish-PluginExe -RepoRoot $RepoRoot -Layout $Layout -Version $Version -Commit $Commit -PublishDir $publishDir

        Write-Step 3 'Checking the published exe'
        Assert-PublishedVersion -ExePath $publishedExe -Version $Version -Commit $Commit

        Write-Step 4 'Staging the plugin tree'
        New-StagedPlugin -RepoRoot $RepoRoot -PublishDir $publishDir -StageDir $stageDir -Layout $Layout -Release $release
        Assert-StagedPlugin -RepoRoot $RepoRoot -StageDir $stageDir -Layout $Layout -Release $release
    } finally {
        Remove-BuildTempTree -Path $publishDir
    }

    Write-Step 5 'Smoke-testing the staged exe'
    Invoke-SmokeTests -StageDir $stageDir -Release $release `
        -ClassesPath (Join-Path $RepoRoot 'plugin\hooks\tool-classes.json') `
        -RegistryPath (Join-Path $RepoRoot 'src\Tools\TestStandToolRegistry.cs') `
        -ProgramSourcePath (Join-Path $RepoRoot 'Program.cs')

    Write-Step 6 "Zipping $ReleaseArchiveName"
    $zipPath = Join-Path $OutDir $ReleaseArchiveName
    New-PluginZip -StageDir $stageDir -ZipPath $zipPath
    Assert-PluginZip -ZipPath $zipPath -StageDir $stageDir

    Write-Step 7 'Writing the versioned copy, the digest and the manifest'
    Write-ReleaseAssets -StageDir $stageDir -OutDir $OutDir -Version $Version

    Write-Step 8 'Verifying the output the way the release is verified'
    Assert-LocalRelease -OutDir $OutDir -Version $Version

    Write-Host ("Done in {0:N1}s: {1} ({2:N1} MB) and its digest and manifest are in {3}" -f $StepClock.Elapsed.TotalSeconds, $ReleaseArchiveName, ((Get-Item -LiteralPath $zipPath).Length / 1MB), $OutDir)
    exit 0
} catch {
    Write-Host (Get-ScriptFailureText -ErrorRecord $_)
    exit 1
}
