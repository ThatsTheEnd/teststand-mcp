# ============================================================================
#  ReleaseVerdict.psm1 - the verdict on a release, with no network and no process state.
#    Get-ReleaseProblems   the judge: plain asset data in, a list of problems out;
#    New-Problem           builds one problem from the fault catalog (ONE map);
#    Format-ReleaseFailure the What/Why/Fix of a list of problems.
#  An asset is a plain object { Name; Uploader; Size; Path }. A release is judged in two scopes so
#  nothing is downloaded for a fault the listing already shows:
#    Listing  presence, who uploaded EVERY asset, versioned-vs-plugin archive size;
#    Content  digest, manifest (archive entries), versioned archive bytes.
#  Terms: plugin archive (teststand-mcp.zip), versioned archive, archive digest, archive manifest.
#  Compatible with Windows PowerShell 5.1 and PowerShell 7.
# ============================================================================
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'ReleaseAssets.psm1')

$script:MaxManifestProblemsShown = 5
$script:UnknownUploader = '(unknown)'
$script:NeverRetriesWhy = 'Running the verifier again will not help'

# What the maintainer does after a fault, by where the assets came from. Local mode never talks about a draft.
$script:RestartFix = @{
    Api   = 'Start a new release run (delete the draft first).'
    Local = ('Run the packaging script again so it produces all {0} assets.' -f (Get-RequiredAssetNames -Version '0.0.0').Count)
}

# ----------------------------------------------------------------------------
#  The fault catalog: one entry per problem code. Fault is a format string over the problem's values;
#  Fix is EXTRA advice after the common restart step (OwnFix: it replaces that step).
#  Every Kind of Compare-ArchiveManifest has an entry (a test asserts it).
# ----------------------------------------------------------------------------
$script:Faults = @{
    'asset-missing'                = @{ Fault = '{0} is missing from the release'
                                        Why = 'the asset is not part of the release, so waiting will not add it'
                                        Fix = '' }
    'hand-uploaded-asset'          = @{ Fault = ("{0} was uploaded by '{1}', not by $ReleaseUploaderLogin")
                                        Why = 'only assets built and uploaded by the release workflow may go live'
                                        Fix = 'Never attach assets by hand.' }
    'versioned-size-differs'       = @{ Fault = '{0} is {1} bytes but the plugin archive is {2} bytes'
                                        Why = 'the two archives must be the same bytes, or users get a different build depending on the URL'
                                        Fix = '' }
    'digest-malformed'             = @{ Fault = 'the archive digest is malformed: {0}'
                                        Why = 'the uploaded digest cannot be read, so the plugin archive cannot be checked against it'
                                        Fix = "The digest must be one `"<sha256>  $ReleaseArchiveName`" line." }
    'digest-name'                  = @{ Fault = "the archive digest names '{0}', not $ReleaseArchiveName"
                                        Why = '"sha256sum -c" would check the wrong file'
                                        Fix = '' }
    'digest-mismatch'              = @{ Fault = "the plugin archive $ReleaseArchiveName does not match the archive digest $ReleaseDigestName (digest {0}, archive {1})"
                                        Why = 'the uploaded archive is not the file the digest was made for'
                                        Fix = '' }
    'versioned-differs'            = @{ Fault = 'the versioned archive {0} differs from the plugin archive ' + $ReleaseArchiveName
                                        Why = 'the two archives must be the same bytes, or users get a different build depending on the URL'
                                        Fix = '' }
    'archive-unreadable'           = @{ Fault = 'the plugin archive cannot be read as a zip file: {1}'
                                        Why = 'its entries cannot be checked against the archive manifest, and users could not install it'
                                        Fix = '' }
    'manifest-malformed'           = @{ Fault = 'the archive manifest is malformed: {1}'
                                        Why = 'the uploaded manifest cannot be read, so the archive entries cannot be checked'
                                        Fix = "The manifest must list `"<sha256>  <path>`" per line." }
    'hash-mismatch'                = @{ Fault = "archive entry '{0}' differs from the manifest"
                                        Why = 'the archive does not contain what the build staged'
                                        Fix = '' }
    'entry-not-in-manifest'        = @{ Fault = "archive entry '{0}' is not listed in the manifest"
                                        Why = 'the archive holds a file the build did not stage'
                                        Fix = '' }
    'entry-missing-from-archive'   = @{ Fault = "the manifest lists '{0}' but the archive has no such entry"
                                        Why = 'the archive lacks a file the build staged'
                                        Fix = '' }
    'archive-entry-duplicate'      = @{ Fault = "the archive holds the entry '{0}' more than once"
                                        Why = 'an extractor keeps either copy, so the installed file is not what was verified'
                                        Fix = '' }
    'archive-entry-case-collision' = @{ Fault = "archive entry '{0}' collides in case with another entry ({1})"
                                        Why = 'two entries that differ only in case overwrite each other when extracted on Windows'
                                        Fix = '' }
    'archive-entry-unsafe'         = @{ Fault = "archive entry '{0}' has an unsafe name ({1})"
                                        Why = 'an entry like this can extract outside the plugin folder'
                                        Fix = '' }
    'manifest-more'                = @{ Fault = '... and {0} more differences between the archive and the manifest'
                                        Why = 'the archive does not contain what the build staged'
                                        Fix = '' }
    'latest-mismatch'              = @{ Fault = "the plugin archive users download from releases/latest (hash {0}) does not match the published archive digest ({1})"
                                        Why = 'users would install a different file than the one the release was verified for'
                                        OwnFix = $true
                                        Fix = 'Check what releases/latest points at. If a bad release is live, delete it so latest falls back to the previous release, or release the next patch version (see CONTRIBUTING).' }
}

function Get-ReleaseFaultCodes {
    [CmdletBinding()]
    param()
    return @($script:Faults.Keys)
}

# An unknown code is a bug in the verifier, so it throws instead of producing a silent blank fault.
function New-Problem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Code, [object[]]$Values = @())
    if (-not $script:Faults.ContainsKey($Code)) { throw "Unknown release fault code '$Code'" }
    $entry = $script:Faults[$Code]
    return [pscustomobject]@{ Code = $Code; Fault = ([string]::Format($entry.Fault, $Values)); Why = $entry.Why; Fix = $entry.Fix; OwnFix = $entry.ContainsKey('OwnFix') }
}

# ----------------------------------------------------------------------------
#  Small checks. Each takes plain data and returns an array of problems.
# ----------------------------------------------------------------------------
function Get-AssetLabel {
    param([string]$Name, [string]$Version)
    $role = 'asset'
    if ($Name -ceq $ReleaseArchiveName) { $role = 'plugin archive' }
    elseif ($Name -ceq $ReleaseDigestName) { $role = 'archive digest' }
    elseif ($Name -ceq $ReleaseManifestName) { $role = 'archive manifest' }
    elseif ($Name -ceq (Get-VersionedArchiveName -Version $Version)) { $role = 'versioned archive' }
    return "the $role $Name"
}

function Get-PresenceProblems {
    param($AssetsByName, [string]$Version)
    $problems = @()
    foreach ($name in (Get-RequiredAssetNames -Version $Version)) {
        if (-not $AssetsByName.ContainsKey($name)) { $problems += New-Problem 'asset-missing' @((Get-AssetLabel $name $Version)) }
    }
    return $problems
}

# EVERY asset of the release, including ones this workflow never builds: a hand-attached extra is also a fault.
function Get-UploaderProblems {
    param([object[]]$Assets, [string]$Version)
    $problems = @()
    foreach ($asset in $Assets) {
        if ($asset.Uploader -cne $ReleaseUploaderLogin) { $problems += New-Problem 'hand-uploaded-asset' @((Get-AssetLabel $asset.Name $Version), $asset.Uploader) }
    }
    return $problems
}

function Get-VersionedSizeProblems {
    param($AssetsByName, [string]$Version)
    $versionedName = Get-VersionedArchiveName -Version $Version
    if (-not ($AssetsByName.ContainsKey($versionedName) -and $AssetsByName.ContainsKey($ReleaseArchiveName))) { return @() }
    $versioned = $AssetsByName[$versionedName]
    $plugin = $AssetsByName[$ReleaseArchiveName]
    if ($null -eq $versioned.Size -or $null -eq $plugin.Size -or $versioned.Size -eq $plugin.Size) { return @() }
    return @(New-Problem 'versioned-size-differs' @((Get-AssetLabel $versionedName $Version), $versioned.Size, $plugin.Size))
}

function Get-DigestProblems {
    param($AssetsByName, [string]$ArchiveHash)
    if (-not $AssetsByName.ContainsKey($ReleaseDigestName)) { return @() }
    try {
        $digest = ConvertFrom-DigestText -Text (Read-Utf8Text $AssetsByName[$ReleaseDigestName].Path)
    } catch {
        return @(New-Problem 'digest-malformed' @($_.Exception.Message))
    }
    if ($digest.Name -cne $ReleaseArchiveName) { return @(New-Problem 'digest-name' @($digest.Name)) }
    if ($digest.Hash -cne $ArchiveHash) { return @(New-Problem 'digest-mismatch' @($digest.Hash, $ArchiveHash)) }
    return @()
}

function Get-ManifestProblems {
    param($AssetsByName, [string]$ArchivePath)
    if (-not $AssetsByName.ContainsKey($ReleaseManifestName)) { return @() }
    $differences = @(Compare-ArchiveManifest -ArchivePath $ArchivePath -ManifestText (Read-Utf8Text $AssetsByName[$ReleaseManifestName].Path))
    $problems = @()
    foreach ($difference in ($differences | Select-Object -First $script:MaxManifestProblemsShown)) {
        $problems += New-Problem $difference.Kind @($difference.Path, $difference.Detail)
    }
    if ($differences.Count -gt $script:MaxManifestProblemsShown) { $problems += New-Problem 'manifest-more' @($differences.Count - $script:MaxManifestProblemsShown) }
    return $problems
}

function Get-VersionedArchiveProblems {
    param($AssetsByName, [string]$Version, [string]$ArchiveHash)
    $versionedName = Get-VersionedArchiveName -Version $Version
    if (-not $AssetsByName.ContainsKey($versionedName)) { return @() }
    if ((Get-FileSha256 $AssetsByName[$versionedName].Path) -ceq $ArchiveHash) { return @() }
    return @(New-Problem 'versioned-differs' @($versionedName))
}

# ----------------------------------------------------------------------------
#  The judge
# ----------------------------------------------------------------------------
function Get-ReleaseProblems {
    [CmdletBinding()]
    param(
        [object[]]$Assets = @(),
        [Parameter(Mandatory)][string]$Version,
        [bool]$CheckUploader = $true,
        [ValidateSet('Listing', 'Content', 'All')][string]$Scope = 'All'
    )
    # Asset names match exactly: 'Teststand-MCP.zip' is not 'teststand-mcp.zip'.
    $assetsByName = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($asset in $Assets) { $assetsByName[$asset.Name] = $asset }

    $problems = @()
    if ($Scope -ne 'Content') {
        $problems += @(Get-PresenceProblems $assetsByName $Version)
        if ($CheckUploader) { $problems += @(Get-UploaderProblems $Assets $Version) }
        $problems += @(Get-VersionedSizeProblems $assetsByName $Version)
    }
    if ($Scope -ne 'Listing' -and $assetsByName.ContainsKey($ReleaseArchiveName)) {
        $archivePath = $assetsByName[$ReleaseArchiveName].Path
        $archiveHash = Get-FileSha256 $archivePath
        $problems += @(Get-DigestProblems $assetsByName $archiveHash)
        $problems += @(Get-ManifestProblems $assetsByName $archivePath)
        $problems += @(Get-VersionedArchiveProblems $assetsByName $Version $archiveHash)
    }
    return $problems
}

# ----------------------------------------------------------------------------
#  Report
# ----------------------------------------------------------------------------
# -Mode Api (a release on GitHub) or Local (staged assets): the fix differs, the faults do not.
function Format-ReleaseFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Subject, [Parameter(Mandatory)][object[]]$Problems, [ValidateSet('Api', 'Local')][string]$Mode = 'Api')
    $reasons = @($Problems | ForEach-Object { $_.Why } | Select-Object -Unique)
    # The common step (start over) once, then each fault's own extra advice; a fault with OwnFix needs no restart.
    $fixes = @()
    if (@($Problems | Where-Object { -not $_.OwnFix }).Count -gt 0) { $fixes += $script:RestartFix[$Mode] }
    $fixes += @($Problems | ForEach-Object { $_.Fix } | Where-Object { $_ } | Select-Object -Unique)
    return @{
        What = "$Subject must not go live: " + ((@($Problems | ForEach-Object { $_.Fault })) -join '; ') + '.'
        Why  = "$($script:NeverRetriesWhy): " + ($reasons -join '; ') + '.'
        Fix  = ($fixes -join "`n")
    }
}

Export-ModuleMember -Function Get-ReleaseProblems, New-Problem, Get-ReleaseFaultCodes, Format-ReleaseFailure
