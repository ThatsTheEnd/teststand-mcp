# ============================================================================
#  Assert-ReleaseAssetSet.ps1 - checks that a release holds exactly the assets that were verified.
#  The release workflow runs it twice on the body of GET repos/<repo>/releases/<id>: just BEFORE the
#  verified draft is published (-Stage BeforePublish: still a draft, the same asset ids) and just AFTER
#  the publish call (-Stage AfterPublish: no longer a draft, the same asset ids). Exit 0, or one
#  three-part failure and exit 1; an AfterPublish failure says that the release is live and names the
#  rollback. The comparison itself is Assert-ReleaseAssetSet in ReleaseAssets.psm1.
#    -ReleaseJson       the response body of GET releases/{id}
#    -ExpectedAssetIds  the verifier's step output asset_ids, {"<name>": <id>, ...}
#    -ReleaseId         the id the verifier reported (its release_id output)
#  The parameters are not Mandatory on purpose: an unset step output arrives as an empty string, and a
#  prompt would hang the run instead of failing it with the three parts.
#  Windows PowerShell 5.1 and PowerShell 7 compatible.
# ============================================================================
param(
    [string]$ReleaseJson = '',
    [string]$ExpectedAssetIds = '',
    [string]$ReleaseId = '',
    [ValidateSet('BeforePublish', 'AfterPublish')][string]$Stage = 'BeforePublish'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1') -Force
try {
    Import-Module (Join-Path $PSScriptRoot 'ReleaseAssets.psm1') -Force
    Assert-ReleaseAssetSet -ReleaseJson $ReleaseJson -ExpectedAssetIds $ExpectedAssetIds -ReleaseId $ReleaseId -Stage $Stage
    exit 0
} catch {
    Write-Host (Get-ScriptFailureText -ErrorRecord $_)
    exit 1
}
