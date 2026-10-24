# ============================================================================
#  Assert-PublishedRelease.ps1 - verifies a release the way a user would download it.
#  Exit 0 only when ALL of these hold; otherwise one three-part failure (what / why
#  incl. whether a re-run can help / fix) and exit 1:
#    - the four assets exist: teststand-mcp.zip, teststand-mcp-v<version>.zip,
#      teststand-mcp.sha256, teststand-mcp.manifest.sha256;
#    - every asset was uploaded by github-actions[bot];
#    - the zip's SHA-256 equals the digest file;
#    - every zip entry equals the manifest (no extra, no missing, no changed entry);
#    - the version-named copy is byte-identical to the fixed zip.
#  One retry after RetryDelaySeconds, ONLY when an asset cannot be downloaded
#  (HTTP error or timeout). Hash, manifest, missing-asset and uploader faults are
#  never retried.
#
#  Two sources:
#    -Repo owner/name -Tag vX.Y.Z [-Token t]   the release through the GitHub API. A DRAFT is
#                                              visible only with a token; /releases/tags/{tag} does
#                                              not return drafts, so the releases list is searched.
#    -LocalDir <dir> [-ReleaseJson <file>]     the four assets in a directory (the staged output).
#                                              -ReleaseJson is a releases-list JSON giving the
#                                              uploaders; without it the uploader check is skipped.
#  -OwnDownloadsPath records every asset download in own-downloads.json (see
#  ReleaseAssets.psm1), -Draft marks them as draft-phase downloads.
#  Test seams: -HttpGet (the HTTP boundary), -Delay (the wait before the retry).
#  Windows PowerShell 5.1 and PowerShell 7 compatible.
# ============================================================================
param(
    [string]$Repo,
    [string]$Tag,
    [string]$Token,
    [string]$LocalDir,
    [string]$ReleaseJson,
    [string]$OwnDownloadsPath,
    [switch]$Draft,
    [string]$RunId = $env:GITHUB_RUN_ID,
    [scriptblock]$HttpGet,
    [scriptblock]$Delay = { param([int]$Seconds) if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds } },
    [int]$RetryDelaySeconds = 30,
    [int]$TimeoutSeconds = 120,
    [string]$ApiBaseUrl = 'https://api.github.com'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads crawl with the progress bar on

$ExpectedUploader = 'github-actions[bot]'
$MaxAttempts = 2                           # the first try and one retry
$ListPageSize = 100
$MaxListPages = 10
$UserAgent = 'teststand-mcp-release-verifier'
$JsonAccept = 'application/vnd.github+json'
$BinaryAccept = 'application/octet-stream'
$MaxManifestProblemsShown = 5
$UnknownUploader = '(unknown)'

# ----------------------------------------------------------------------------
#  The fault texts, in ONE map. Fault: what is wrong. Why: the consequence (a re-run
#  helps only when Rerun is $true). Fix: what the maintainer does.
# ----------------------------------------------------------------------------
$Faults = @{
    'asset-missing'              = @{ Fault = '{0} is missing from the release'; Rerun = $false
                                      Why = 'the asset is not part of the release, so waiting will not add it'
                                      Fix = 'Re-run the release workflow so it uploads all four assets; do not publish this release.' }
    'uploader'                   = @{ Fault = "{0} was uploaded by '{1}', not by github-actions[bot]"; Rerun = $false
                                      Why = 'only assets built and uploaded by the release workflow may go live'
                                      Fix = 'Delete the draft and let the release workflow create it again; never attach assets by hand.' }
    'digest-malformed'           = @{ Fault = 'teststand-mcp.sha256 is malformed: {0}'; Rerun = $false
                                      Why = 'the uploaded digest cannot be read, so the zip cannot be checked against it'
                                      Fix = 'Re-run the release workflow; the digest must be one "<sha256>  teststand-mcp.zip" line.' }
    'digest-name'                = @{ Fault = "teststand-mcp.sha256 names '{0}', not teststand-mcp.zip"; Rerun = $false
                                      Why = '"sha256sum -c" would check the wrong file'
                                      Fix = 'Re-run the release workflow so the digest is generated for teststand-mcp.zip.' }
    'digest-mismatch'            = @{ Fault = 'teststand-mcp.zip does not match teststand-mcp.sha256 (digest {0}, zip {1})'; Rerun = $false
                                      Why = 'the uploaded zip is not the file the digest was made for'
                                      Fix = 'Delete the draft and re-run the release workflow; the upload was corrupted or replaced.' }
    'manifest-malformed'         = @{ Fault = 'teststand-mcp.manifest.sha256 is malformed: {0}'; Rerun = $false
                                      Why = 'the uploaded manifest cannot be read, so the archive entries cannot be checked'
                                      Fix = 'Re-run the release workflow; the manifest must list "<sha256>  <path>" per line.' }
    'hash-mismatch'              = @{ Fault = "archive entry '{0}' differs from the manifest"; Rerun = $false
                                      Why = 'the archive does not contain what the build staged'
                                      Fix = 'Delete the draft and re-run the release workflow.' }
    'entry-not-in-manifest'      = @{ Fault = "archive entry '{0}' is not listed in the manifest"; Rerun = $false
                                      Why = 'the archive holds a file the build did not stage'
                                      Fix = 'Delete the draft and re-run the release workflow.' }
    'entry-missing-from-archive' = @{ Fault = "the manifest lists '{0}' but the archive has no such entry"; Rerun = $false
                                      Why = 'the archive lacks a file the build staged'
                                      Fix = 'Delete the draft and re-run the release workflow.' }
    'manifest-more'              = @{ Fault = '... and {0} more differences between the archive and the manifest'; Rerun = $false
                                      Why = 'the archive does not contain what the build staged'
                                      Fix = 'Delete the draft and re-run the release workflow.' }
    'versioned-differs'          = @{ Fault = '{0} differs from teststand-mcp.zip'; Rerun = $false
                                      Why = 'the two zips must be the same bytes, or users get a different build depending on the URL'
                                      Fix = 'Delete the draft and re-run the release workflow.' }
}

function New-Problem {
    param([string]$Code, [object[]]$Values = @())
    $entry = $Faults[$Code]
    return [pscustomobject]@{ Code = $Code; Fault = ($entry.Fault -f $Values); Rerun = $entry.Rerun; Why = $entry.Why; Fix = $entry.Fix }
}

function Get-Property {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# ----------------------------------------------------------------------------
#  JUDGE: pure. $Assets are plain objects {Name; Uploader; Path} for the assets that exist
#  and were obtained; an asset absent from the list is missing. Uploader is checked only
#  when $CheckUploader. No network, no process state: this is what the tests drive.
# ----------------------------------------------------------------------------
function Test-ReleaseData {
    param([object[]]$Assets, [string]$Version, [bool]$CheckUploader)

    $problems = New-Object System.Collections.Generic.List[object]
    $byName = @{}
    foreach ($asset in $Assets) { $byName[$asset.Name] = $asset }

    $zipName = $ReleaseArchiveName
    $versionedName = Get-VersionedArchiveName -Version $Version
    foreach ($name in (Get-RequiredAssetNames -Version $Version)) {
        if (-not $byName.ContainsKey($name)) { $problems.Add((New-Problem 'asset-missing' @($name))) }
    }
    if ($CheckUploader) {
        foreach ($asset in $Assets) {
            if ($asset.Uploader -cne $ExpectedUploader) { $problems.Add((New-Problem 'uploader' @($asset.Name, $asset.Uploader))) }
        }
    }
    if (-not $byName.ContainsKey($zipName)) { return $problems.ToArray() }   # every remaining check needs the zip
    $zipPath = $byName[$zipName].Path
    $zipHash = Get-FileSha256 $zipPath

    if ($byName.ContainsKey($ReleaseDigestName)) {
        try {
            $digest = ConvertFrom-DigestText -Text ([IO.File]::ReadAllText($byName[$ReleaseDigestName].Path))
            if ($digest.Name -cne $zipName) { $problems.Add((New-Problem 'digest-name' @($digest.Name))) }
            elseif ($digest.Hash -cne $zipHash) { $problems.Add((New-Problem 'digest-mismatch' @($digest.Hash, $zipHash))) }
        } catch {
            $problems.Add((New-Problem 'digest-malformed' @($_.Exception.Message)))
        }
    }

    if ($byName.ContainsKey($ReleaseManifestName)) {
        $differences = @(Test-ArchiveManifest -ArchivePath $zipPath -ManifestText ([IO.File]::ReadAllText($byName[$ReleaseManifestName].Path)))
        foreach ($difference in ($differences | Select-Object -First $MaxManifestProblemsShown)) {
            $value = $difference.Path
            if ($difference.Kind -eq 'manifest-malformed') { $value = $difference.Detail }
            $problems.Add((New-Problem $difference.Kind @($value)))
        }
        if ($differences.Count -gt $MaxManifestProblemsShown) { $problems.Add((New-Problem 'manifest-more' @($differences.Count - $MaxManifestProblemsShown))) }
    }

    if ($byName.ContainsKey($versionedName) -and ((Get-FileSha256 $byName[$versionedName].Path) -cne $zipHash)) {
        $problems.Add((New-Problem 'versioned-differs' @($versionedName)))
    }
    return $problems.ToArray()
}

# ----------------------------------------------------------------------------
#  FETCH: obtains the assets and the facts about them; judges nothing. Returns
#  { Assets; Attempted (every asset requested); DownloadError (first failure or $null) }.
#  A problem with the release itself (no such tag, listing failed) is a hard failure,
#  not a download error: it is never retried.
# ----------------------------------------------------------------------------
# ConvertFrom-Json emits a JSON array as ONE object in Windows PowerShell 5.1 and unrolled in 7; this is always the items.
function ConvertFrom-JsonList {
    param([string]$Text)
    return @($Text | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
}

function Find-ReleaseInList {
    param($Releases, [string]$Tag)
    return @($Releases | Where-Object { $null -ne $_ -and (Get-Property $_ 'tag_name') -ceq $Tag }) | Select-Object -First 1
}

function Get-UploaderLogin {
    param($ReleaseAsset)
    $login = Get-Property (Get-Property $ReleaseAsset 'uploader') 'login'
    if ([string]::IsNullOrEmpty($login)) { return $UnknownUploader }
    return [string]$login
}

function Get-LocalReleaseData {
    param([string]$LocalDir, [string]$Tag, [string]$ReleaseJson, [string[]]$AssetNames)
    $listed = $null
    if ($ReleaseJson) {
        if (-not (Test-Path -LiteralPath $ReleaseJson -PathType Leaf)) {
            Write-BuildFailure -What "The release metadata file $ReleaseJson does not exist." `
                -Why 'It supplies the uploader of each asset; without it the uploader check cannot run.' -Fix 'Pass an existing releases-list JSON, or omit -ReleaseJson to skip the uploader check.'
        }
        $release = Find-ReleaseInList -Releases (ConvertFrom-JsonList ([IO.File]::ReadAllText($ReleaseJson))) -Tag $Tag
        if ($null -eq $release) {
            Write-BuildFailure -What "The release metadata file $ReleaseJson has no release tagged $Tag." `
                -Why 'The uploaders cannot be checked for a release that is not in the file.' -Fix 'Pass the releases-list JSON that contains this tag.'
        }
        $listed = @{}
        foreach ($asset in @(Get-Property $release 'assets')) { $listed[[string](Get-Property $asset 'name')] = $asset }
    }
    $assets = @()
    foreach ($name in $AssetNames) {
        $path = Join-Path $LocalDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $uploader = $null
        if ($null -ne $listed) {
            $uploader = $UnknownUploader
            if ($listed.ContainsKey($name)) { $uploader = Get-UploaderLogin $listed[$name] }
        }
        $assets += [pscustomobject]@{ Name = $name; Uploader = $uploader; Path = $path }
    }
    return [pscustomobject]@{ Assets = $assets; Attempted = @(); DownloadError = $null; CheckUploader = ($null -ne $listed) }
}

function New-ApiHeaders {
    param([string]$Token, [string]$Accept)
    $headers = @{ 'User-Agent' = $UserAgent; 'Accept' = $Accept }
    if (-not [string]::IsNullOrEmpty($Token)) { $headers['Authorization'] = "Bearer $Token" }
    return $headers
}

function Get-ApiReleaseData {
    param([string]$Repo, [string]$Tag, [string]$Token, [string[]]$AssetNames, [string]$DestDir, [scriptblock]$HttpGet, [int]$TimeoutSeconds, [string]$ApiBaseUrl)

    $release = $null
    for ($page = 1; $page -le $MaxListPages -and $null -eq $release; $page++) {
        $uri = "$ApiBaseUrl/repos/$Repo/releases?per_page=$ListPageSize&page=$page"
        try {
            $text = & $HttpGet -Uri $uri -Headers (New-ApiHeaders $Token $JsonAccept) -OutFile $null -TimeoutSeconds $TimeoutSeconds
            $releases = ConvertFrom-JsonList $text
        } catch {
            Write-BuildFailure -What "Could not read the releases of $Repo from the GitHub API: $($_.Exception.Message)" `
                -Why 'The release list is needed to find the draft and its assets. A re-run may help if the cause is transient (network, rate limit); it will not help for a bad token.' `
                -Fix 'Check the network and that the token is valid and allowed to read the repository, then re-run.'
        }
        $release = Find-ReleaseInList -Releases $releases -Tag $Tag
        if ($releases.Count -lt $ListPageSize) { break }
    }
    if ($null -eq $release) {
        Write-BuildFailure -What "No release tagged $Tag was found in $Repo." `
            -Why 'A draft release is visible through the API only with a token that may write the repository contents, and the tag must match exactly. A re-run will not help until the release exists.' `
            -Fix "Pass -Token (the workflow's GITHUB_TOKEN with contents: write) for a draft, and check the tag spelling with: gh release list --repo $Repo"
    }

    $listed = @{}
    foreach ($asset in @(Get-Property $release 'assets')) { $listed[[string](Get-Property $asset 'name')] = $asset }

    $assets = @()
    $attempted = @()
    $downloadError = $null
    foreach ($name in $AssetNames) {
        if (-not $listed.ContainsKey($name)) { continue }
        $id = [string](Get-Property $listed[$name] 'id')
        if ($id -cnotmatch '\A[0-9]+\z') {
            Write-BuildFailure -What "The release lists $name with an unusable asset id '$id'." `
                -Why 'The asset cannot be downloaded through the API without its numeric id. A re-run will not help.' -Fix 'Check the release in the GitHub UI; recreate the draft if the asset is broken.'
        }
        $path = Join-Path $DestDir $name
        $attempted += $name
        try {
            [void](& $HttpGet -Uri "$ApiBaseUrl/repos/$Repo/releases/assets/$id" -Headers (New-ApiHeaders $Token $BinaryAccept) -OutFile $path -TimeoutSeconds $TimeoutSeconds)
        } catch {
            $downloadError = [pscustomobject]@{ Name = $name; Message = $_.Exception.Message }
            break
        }
        $assets += [pscustomobject]@{ Name = $name; Uploader = (Get-UploaderLogin $listed[$name]); Path = $path }
    }
    return [pscustomobject]@{ Assets = $assets; Attempted = $attempted; DownloadError = $downloadError; CheckUploader = $true }
}

# The real HTTP boundary: TLS 1.2, a timeout on every call, no progress bar.
function Invoke-ReleaseHttp {
    param($Uri, $Headers, $OutFile, $TimeoutSeconds)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $parameters = @{ Uri = $Uri; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = $TimeoutSeconds; ErrorAction = 'Stop' }
    if ($OutFile) {
        Invoke-WebRequest @parameters -OutFile $OutFile
        return
    }
    return (Invoke-WebRequest @parameters).Content
}

# ----------------------------------------------------------------------------
#  Orchestration
# ----------------------------------------------------------------------------
function Format-ProblemFailure {
    param([string]$Tag, [object[]]$Problems)
    # One problem a re-run cannot fix is enough to say a re-run will not help.
    $explained = @($Problems | Where-Object { -not $_.Rerun })
    $advice = 'A re-run will not help'
    if ($explained.Count -eq 0) { $explained = $Problems; $advice = 'A re-run may help' }
    $reasons = @($explained | ForEach-Object { $_.Why } | Select-Object -Unique)
    return @{
        What = "Release $Tag must not go live: " + ((@($Problems | ForEach-Object { $_.Fault })) -join '; ') + '.'
        Why  = "${advice}: " + ($reasons -join '; ') + '.'
        Fix  = ((@($Problems | ForEach-Object { $_.Fix }) | Select-Object -Unique) -join "`n")
    }
}

function Add-AttemptDownloads {
    param([string[]]$Names, [string]$Path, [string]$RunId, [bool]$IsDraft)
    foreach ($name in $Names) { Add-OwnDownload -Path $Path -AssetName $name -RunId $RunId -Draft:$IsDraft }
}

try {
    Import-Module (Join-Path $PSScriptRoot 'ReleaseAssets.psm1') -Force

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        Write-BuildFailure -What 'No release tag was given.' -Why 'The tag names the release and the version-named asset to check.' -Fix 'Pass -Tag vX.Y.Z.'
    }
    $localMode = -not [string]::IsNullOrEmpty($LocalDir)
    if ($localMode -eq (-not [string]::IsNullOrEmpty($Repo))) {
        Write-BuildFailure -What 'Give exactly one source: -Repo or -LocalDir.' -Why 'The verifier reads either a release through the GitHub API or a directory of staged assets, not both.' `
            -Fix 'Use -Repo owner/name -Tag vX.Y.Z [-Token t] for a release, or -LocalDir <dir> for staged output.'
    }
    if ($localMode -and -not (Test-Path -LiteralPath $LocalDir -PathType Container)) {
        Write-BuildFailure -What "The directory $LocalDir does not exist." -Why 'It should hold the four release assets.' -Fix 'Pass the directory the build wrote the assets to.'
    }
    if ($null -eq $HttpGet) { $HttpGet = ${function:Invoke-ReleaseHttp} }

    $version = $Tag -creplace '\Av', ''
    $assetNames = @(Get-RequiredAssetNames -Version $version)
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('release-verify-' + [Guid]::NewGuid().ToString('N'))
    $downloaded = 0
    $attempt = 0
    try {
        while ($true) {
            $attempt++
            if ($localMode) {
                $data = Get-LocalReleaseData -LocalDir $LocalDir -Tag $Tag -ReleaseJson $ReleaseJson -AssetNames $assetNames
            } else {
                $destDir = Join-Path $tempRoot "attempt$attempt"
                [void](New-Item -ItemType Directory -Path $destDir -Force)
                $data = Get-ApiReleaseData -Repo $Repo -Tag $Tag -Token $Token -AssetNames $assetNames -DestDir $destDir -HttpGet $HttpGet -TimeoutSeconds $TimeoutSeconds -ApiBaseUrl $ApiBaseUrl
            }
            $downloaded += @($data.Attempted).Count
            if ($OwnDownloadsPath -and @($data.Attempted).Count -gt 0) {
                Add-AttemptDownloads -Names $data.Attempted -Path $OwnDownloadsPath -RunId $RunId -IsDraft ([bool]$Draft)
            }
            if ($null -eq $data.DownloadError) { break }
            if ($attempt -ge $MaxAttempts) {
                Write-BuildFailure -What "Release $Tag could not be downloaded for verification after $attempt attempts: could not download $($data.DownloadError.Name): $($data.DownloadError.Message)" `
                    -Why 'A re-run may help: this is a download error (HTTP error or timeout), not a fault found in the release; GitHub may still be settling the upload, or the network failed.' `
                    -Fix 'Re-run the verification. If it keeps failing, check that the token can read the release and that the asset is listed on it.'
            }
            Write-Host "Attempt $attempt could not download $($data.DownloadError.Name) ($($data.DownloadError.Message)); waiting $RetryDelaySeconds s and retrying once."
            & $Delay $RetryDelaySeconds
        }

        $problems = @(Test-ReleaseData -Assets $data.Assets -Version $version -CheckUploader $data.CheckUploader)
        if ($problems.Count -gt 0) {
            $failure = Format-ProblemFailure -Tag $Tag -Problems $problems
            Write-BuildFailure @failure
        }
    } finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $uploaderNote = if ($data.CheckUploader) { "every asset uploaded by $ExpectedUploader" } else { 'uploader check skipped (no release metadata given)' }
    Write-Host "Release $Tag verified: $(@($data.Assets).Count) assets, digest and manifest match, versioned copy identical, $uploaderNote."
    Write-Host "Downloaded $downloaded asset(s) in $attempt attempt(s)."
    exit 0
} catch {
    Write-Host (Get-ScriptFailureText -ErrorRecord $_)
    exit 1
}
