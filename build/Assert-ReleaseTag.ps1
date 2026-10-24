# ============================================================================
#  Assert-ReleaseTag.ps1 - the release tag gate. A tag must be exactly
#  v<major>.<minor>.<patch>. Exit 0 and (when GITHUB_OUTPUT is set) append
#  "version=<X.Y.Z>" and "tag=<vX.Y.Z>" for later workflow steps; otherwise print
#  what is wrong, why the format is required and the retag commands in a safe
#  order, and exit 1. The same verdict locally and in CI.
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\Assert-ReleaseTag.ps1 -Tag v1.9.0
#  In CI pass the tag through the environment, never inline: tag names are user input.
#    -Tag $env:TAG
#  -Commit is the commit the retag commands point at (default: GITHUB_SHA when set).
#  Windows PowerShell 5.1 and PowerShell 7 compatible.
# ============================================================================
param(
    [AllowNull()][AllowEmptyString()][string]$Tag = '',
    [string]$Commit = $env:GITHUB_SHA
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'ReleaseAssets.psm1') -Force

    $result = ConvertFrom-ReleaseTag -Tag $Tag
    if (-not $result.Valid) {
        $failure = Get-TagRejection -Result $result -Commit $Commit
        Write-BuildFailure @failure
    }

    if ($env:GITHUB_OUTPUT) {
        # No BOM: the runner would read it as part of the first key.
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "version=$($result.Version)`ntag=$($result.Tag)`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host "Tag $($result.Tag) is valid: version $($result.Version)"
    exit 0
} catch {
    Write-Host $_.Exception.Message
    exit 1
}
