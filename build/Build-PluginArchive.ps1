# ============================================================================
#  Build-PluginArchive.ps1 - builds the plugin archive (teststand-mcp.zip) from this checkout:
#    1. refuses a malformed version, tag, commit or layout;
#    2. runs the source checks that need no build (skill sources, tool classification, the
#       plugin.json version placeholder);
#    3. dotnet publish in the chosen exe layout, and proves the exe carries the version.
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
Import-Module (Join-Path $PSScriptRoot 'PluginArchive.psm1') -Force

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PublishDirName = 'publish'
$StepClock = [Diagnostics.Stopwatch]::StartNew()
$StepCount = 3

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
    try {
        $publishedExe = Publish-PluginExe -RepoRoot $RepoRoot -Layout $Layout -Version $Version -Commit $Commit -PublishDir $publishDir

        Write-Step 3 'Checking the published exe'
        Assert-PublishedVersion -ExePath $publishedExe -Version $Version -Commit $Commit
    } finally {
        Remove-BuildTempTree -Path $publishDir
    }
    exit 0
} catch {
    Write-Host (Get-ScriptFailureText -ErrorRecord $_)
    exit 1
}
