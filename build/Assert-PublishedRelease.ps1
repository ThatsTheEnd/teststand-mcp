# ============================================================================
#  Assert-PublishedRelease.ps1 - verifies a release the way a user would download it.
#  Exit 0 only when ALL of these hold; otherwise one three-part failure (what / why / fix) and
#  exit 1. The judging itself is ReleaseVerdict.psm1 (no network); this script owns the
#  parameters, the fetching, the retry, the report and the exit code.
#    - the four assets exist: the plugin archive teststand-mcp.zip, the versioned archive
#      teststand-mcp-v<version>.zip, the archive digest and the archive manifest;
#    - EVERY asset of the release was uploaded by github-actions[bot];
#    - the plugin archive's SHA-256 equals the archive digest;
#    - every zip entry equals the archive manifest (none extra, none missing, none changed, none
#      duplicated, none with an unsafe name);
#    - the versioned archive is byte-identical to the plugin archive.
#  Faults visible in the release LISTING (missing or hand-uploaded assets, a versioned archive of
#  another size) are reported before anything is downloaded.
#  ONE retry after RetryDelaySeconds, ONLY for assets whose download failed (HTTP error or timeout);
#  it fetches just those, reusing the files already received. Hash, manifest, missing-asset and
#  uploader faults are never retried.
#
#  Three sources (exactly one):
#    -Repo owner/name -Tag vX.Y.Z [-Token t]   a release through the GitHub API (-Token defaults to
#                                              GITHUB_TOKEN). A DRAFT is visible only with a token;
#                                              /releases/tags/{tag} does not return drafts, so the
#                                              releases list is searched. Exactly one release must
#                                              carry the tag; its id is written as step output
#                                              release_id (asset_ids too) so the workflow publishes
#                                              exactly the release that was verified.
#    -LocalDir <dir> [-Tag vX.Y.Z | -Version X.Y.Z] [-ReleaseJson <file>]
#                                              the assets in a directory (the staged output; the
#                                              packaging step has a version, no tag).
#                                              -ReleaseJson is a releases-list JSON giving the
#                                              uploaders (needs -Tag); without it the uploader check
#                                              is skipped.
#    -Latest                                   what users get: the unauthenticated releases/latest
#                                              download of the plugin archive, hashed and compared
#                                              with the published archive digest. Recorded as a
#                                              published download.
#  -Rehearsal accepts the dry-run tag v<X.Y.Z>-rehearsal.
#  -OwnDownloadsPath records every download in own-downloads.json (see ReleaseAssets.psm1)
#  immediately BEFORE its request. The phase comes from the release's own draft flag; -Draft
#  forces draft. -Date and -RunId override the recorded date and run id (tests).
#  Test seams: -HttpGet (the HTTP boundary), -Delay (the wait before the retry).
#  Windows PowerShell 5.1 and PowerShell 7 compatible.
# ============================================================================
param(
    [string]$Repo,
    [string]$Tag,
    [string]$Version,
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$LocalDir,
    [string]$ReleaseJson,
    [switch]$Latest,
    [switch]$Rehearsal,
    [string]$OwnDownloadsPath,
    [switch]$Draft,
    [string]$RunId = $env:GITHUB_RUN_ID,
    [string]$Date,
    [scriptblock]$HttpGet,
    [scriptblock]$Delay = { param([int]$Seconds) if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds } },
    [int]$RetryDelaySeconds = 30,
    [int]$TimeoutSeconds = 120,
    [string]$ApiBaseUrl = 'https://api.github.com'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads crawl with the progress bar on

$MaxAttempts = 2                           # the first try and one retry
$ListPageSize = 100
$MaxListPages = 10
$MinTransferBytesPerSecond = 1MB           # the slowest link a download is still allowed to be on
$UserAgent = 'teststand-mcp-release-verifier'
$JsonAccept = 'application/vnd.github+json'
$BinaryAccept = 'application/octet-stream'
$RepoPattern = '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z'
$DotsOnlyPattern = '\A\.+\z'
$AssetIdPattern = '\A[0-9]+\z'
$UnknownUploader = '(unknown)'
$DraftPhase = 'draft'
$PublishedPhase = 'published'

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1') -Force

# ----------------------------------------------------------------------------
#  JSON helpers
# ----------------------------------------------------------------------------
# ConvertFrom-Json emits a JSON array as ONE object in Windows PowerShell 5.1 and unrolled in 7; this is always the items.
function ConvertFrom-JsonList {
    param([string]$Text)
    return @($Text | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
}

function Select-ReleaseByTag {
    param($Releases, [string]$Tag)
    return @($Releases | Where-Object { $null -ne $_ -and (Get-JsonProperty $_ 'tag_name') -ceq $Tag })
}

function Get-UploaderLogin {
    param($ReleaseAsset)
    $login = Get-JsonProperty (Get-JsonProperty $ReleaseAsset 'uploader') 'login'
    if ([string]::IsNullOrEmpty($login)) { return $UnknownUploader }
    return [string]$login
}

# The plain listing the judge works on: { Name; Uploader; Size; Path; Id }.
function ConvertTo-ListedAssets {
    param($Release)
    $listed = @()
    foreach ($asset in @(Get-JsonProperty $Release 'assets')) {
        if ($null -eq $asset) { continue }
        $size = Get-JsonProperty $asset 'size'
        $listed += [pscustomobject]@{
            Name = [string](Get-JsonProperty $asset 'name'); Uploader = (Get-UploaderLogin $asset)
            Size = $(if ($null -ne $size) { [int64]$size } else { $null }); Path = $null; Id = [string](Get-JsonProperty $asset 'id')
        }
    }
    return $listed
}

# ----------------------------------------------------------------------------
#  HTTP: ONE connection object (token, boundary, timeout, base URL); the boundary is a seam.
# ----------------------------------------------------------------------------
# The real HTTP boundary: TLS 1.2, a timeout on every call, no progress bar. -TimeoutSec semantics differ:
# Windows PowerShell 5.1 bounds the wait for the response (HttpWebRequest.Timeout), not the body transfer;
# PowerShell 7 maps it onto HttpClient.Timeout, which bounds the whole request unless the body is streamed.
# That is not measured here (no pwsh on this station), so every download gets a size-based timeout that is
# safe under either reading.
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

function New-Connection {
    param([string]$Token, [scriptblock]$HttpGet, [int]$TimeoutSeconds, [string]$ApiBaseUrl)
    if ($null -eq $HttpGet) { $HttpGet = ${function:Invoke-ReleaseHttp} }
    return [pscustomobject]@{ Token = $Token; HttpGet = $HttpGet; TimeoutSeconds = $TimeoutSeconds; ApiBaseUrl = $ApiBaseUrl }
}

function Invoke-ConnectionGet {
    param($Connection, [string]$Uri, [string]$Accept, [string]$OutFile, [int]$TimeoutSeconds, [bool]$UseToken = $true)
    $headers = @{ 'User-Agent' = $UserAgent; 'Accept' = $Accept }
    if ($UseToken -and -not [string]::IsNullOrEmpty($Connection.Token)) { $headers['Authorization'] = "Bearer $($Connection.Token)" }
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $Connection.TimeoutSeconds }
    return (& $Connection.HttpGet -Uri $Uri -Headers $headers -OutFile $OutFile -TimeoutSeconds $TimeoutSeconds)
}

# ----------------------------------------------------------------------------
#  FETCH: obtains the release and its files; judges nothing. A problem with the release itself (no
#  such tag, listing failed) is a hard failure, never a download error and never retried.
# ----------------------------------------------------------------------------
function Get-ReleaseFromApi {
    param($Connection, [string]$Repo, [string]$Tag)
    $found = @()
    $exhausted = $false
    for ($page = 1; $page -le $MaxListPages; $page++) {
        $uri = "$($Connection.ApiBaseUrl)/repos/$Repo/releases?per_page=$ListPageSize&page=$page"
        try {
            $releases = ConvertFrom-JsonList (Invoke-ConnectionGet $Connection $uri $JsonAccept $null 0)
        } catch {
            Write-BuildFailure -What "Could not read the releases of $Repo from the GitHub API: $($_.Exception.Message)" `
                -Why 'The release list is needed to find the draft and its assets. Running the verifier again may help if the cause is transient (network, rate limit); it will not help for a bad token.' `
                -Fix 'Check the network and that the token is valid and allowed to read the repository, then run it again.'
        }
        $found += @(Select-ReleaseByTag $releases $Tag)
        if ($releases.Count -lt $ListPageSize) { break }
        if ($page -eq $MaxListPages) { $exhausted = $true }
    }
    if ($found.Count -gt 1) {
        $ids = (@($found | ForEach-Object { Get-JsonProperty $_ 'id' }) -join ', ')
        Write-BuildFailure -What "$($found.Count) releases of $Repo carry the tag $Tag (ids: $ids)." `
            -Why 'The verifier cannot tell which one the workflow would publish, and publishing the wrong one would ship assets nobody verified. Running it again will not help.' `
            -Fix "Delete the stale draft (gh release delete $Tag --repo $Repo, or in the web UI) so exactly one release carries the tag."
    }
    if ($found.Count -eq 0) {
        $searched = if ($exhausted) { " The search stopped after $MaxListPages pages of $ListPageSize releases; an older release is not found." } else { '' }
        Write-BuildFailure -What "No release tagged $Tag was found in $Repo.$searched" `
            -Why 'A draft release is visible through the API only with a token that may write the repository contents, and the tag must match exactly. Running the verifier again will not help until the release exists.' `
            -Fix "Pass -Token (the workflow's GITHUB_TOKEN with contents: write) for a draft, and check the tag spelling with: gh release list --repo $Repo"
    }
    return $found[0]
}

function Get-LocalListing {
    param([string]$LocalDir, [string]$Tag, [string]$ReleaseJson)
    $uploaders = $null
    if ($ReleaseJson) {
        $jsonPath = Resolve-BuildPath $ReleaseJson
        if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
            Write-BuildFailure -What "The release metadata file $ReleaseJson does not exist." `
                -Why 'It supplies the uploader of each asset; without it the uploader check cannot run.' -Fix 'Pass an existing releases-list JSON, or omit -ReleaseJson to skip the uploader check.'
        }
        $matching = @(Select-ReleaseByTag (ConvertFrom-JsonList (Read-Utf8Text $jsonPath)) $Tag)
        if ($matching.Count -ne 1) {
            Write-BuildFailure -What "The release metadata file $ReleaseJson has $($matching.Count) releases tagged $Tag; exactly one is needed." `
                -Why 'The uploaders cannot be checked for a release that is not in the file, or is in it twice.' -Fix 'Pass the releases-list JSON that contains this tag once.'
        }
        $uploaders = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        foreach ($listed in (ConvertTo-ListedAssets $matching[0])) { $uploaders[$listed.Name] = $listed.Uploader }
    }
    $assets = @()
    foreach ($file in (Get-ChildItem -LiteralPath (Resolve-BuildPath $LocalDir) -File | Sort-Object Name)) {
        $uploader = $null
        if ($null -ne $uploaders) {
            $uploader = $UnknownUploader
            if ($uploaders.ContainsKey($file.Name)) { $uploader = $uploaders[$file.Name] }
        }
        $assets += [pscustomobject]@{ Name = $file.Name; Uploader = $uploader; Size = [int64]$file.Length; Path = $file.FullName; Id = $null }
    }
    return [pscustomobject]@{ Assets = $assets; CheckUploader = ($null -ne $uploaders) }
}

# One download to make: where from, with what, and how long it may take.
function New-DownloadRequest {
    param([string]$Name, [string]$Uri, [string]$Accept, [bool]$UseToken, $Size)
    return [pscustomobject]@{ Name = $Name; Uri = $Uri; Accept = $Accept; UseToken = $UseToken; Size = $Size }
}

# At most this long per asset: the base timeout, or the time the asset needs at the slowest allowed link.
function Get-DownloadTimeoutSeconds {
    param($Request, [int]$BaseSeconds)
    if ($null -eq $Request.Size) { return $BaseSeconds }
    return [int][Math]::Max($BaseSeconds, [Math]::Ceiling($Request.Size / $MinTransferBytesPerSecond))
}

# Downloads each request not yet in $Transfer.Saved, stopping at the first failure; returns the failures
# (zero or one). $Recorder runs immediately BEFORE each request, so an interrupted run still counts it.
function Save-Downloads {
    param($Connection, [object[]]$Requests, [string]$DestDir, $Transfer, [scriptblock]$Recorder)
    foreach ($request in $Requests) {
        if ($Transfer.Saved.ContainsKey($request.Name)) { continue }
        $path = Join-Path $DestDir $request.Name
        if ($null -ne $Recorder) { & $Recorder $request.Name }
        $Transfer.Requested++
        try {
            [void](Invoke-ConnectionGet $Connection $request.Uri $request.Accept $path (Get-DownloadTimeoutSeconds $request $Connection.TimeoutSeconds) $request.UseToken)
            $Transfer.Saved[$request.Name] = $path
        } catch {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue   # never keep a partial file
            return @([pscustomobject]@{ Name = $request.Name; Message = $_.Exception.Message })
        }
    }
    return @()
}

# Runs $Fetch (attempt number -> failures) up to $MaxAttempts times, waiting between tries.
function Invoke-FetchWithRetry {
    param([scriptblock]$Fetch, [scriptblock]$Delay, [int]$DelaySeconds, [int]$MaxAttempts)
    $failed = @()
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $failed = @(& $Fetch $attempt)
        if ($failed.Count -eq 0) { return [pscustomobject]@{ Attempts = $attempt; Failed = @() } }
        if ($attempt -lt $MaxAttempts) {
            Write-Host "Attempt $attempt could not download $($failed[0].Name) ($($failed[0].Message)); waiting $DelaySeconds s and trying once more."
            & $Delay $DelaySeconds
        }
    }
    return [pscustomobject]@{ Attempts = $MaxAttempts; Failed = $failed }
}

# ----------------------------------------------------------------------------
#  Orchestration
# ----------------------------------------------------------------------------
function Assert-ReleaseFailure {
    param([string]$Subject, [object[]]$Problems, [string]$Mode)
    if ($Problems.Count -eq 0) { return }
    $failure = Format-ReleaseFailure -Subject $Subject -Problems $Problems -Mode $Mode
    Write-BuildFailure @failure
}

function Assert-DownloadsSucceeded {
    param($Outcome, [string]$Subject)
    if ($Outcome.Failed.Count -eq 0) { return }
    Write-BuildFailure -What "$Subject could not be downloaded for verification after $($Outcome.Attempts) attempts: could not download $($Outcome.Failed[0].Name): $($Outcome.Failed[0].Message)" `
        -Why 'Running the verifier again may help: this is a download error (HTTP error or timeout), not a fault found in the release; GitHub may still be settling the upload, or the network failed.' `
        -Fix 'Run the verification again. If it keeps failing, check that the token can read the release and that the asset is listed on it.'
}

function Resolve-ReleaseVersion {
    param([string]$Tag, [string]$Version, [bool]$IsLocal, [bool]$AllowRehearsal)
    $tagVersion = $null
    if ($Tag) {
        $result = ConvertFrom-ReleaseTag -Tag $Tag -AllowRehearsal:$AllowRehearsal
        if (-not $result.IsValid) {
            $failure = Get-TagRejection -Result $result -Commit $env:GITHUB_SHA
            Write-BuildFailure @failure
        }
        $tagVersion = $result.Version
    }
    if ($Version) {
        if ($Version -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') {
            Write-BuildFailure -What "The version '$Version' is not X.Y.Z." -Why 'The versioned archive is named after a version of three numbers without leading zeros.' -Fix 'Pass -Version 1.9.0 (no leading v).'
        }
        if ($tagVersion -and $tagVersion -cne $Version) {
            Write-BuildFailure -What "The tag $Tag and the version $Version disagree." -Why 'They name different releases.' -Fix 'Pass only one of -Tag and -Version, or matching ones.'
        }
        $tagVersion = $Version
    }
    if (-not $tagVersion) {
        $hint = if ($IsLocal) { 'Pass -Tag vX.Y.Z or -Version X.Y.Z.' } else { 'Pass -Tag vX.Y.Z.' }
        Write-BuildFailure -What 'No release tag or version was given.' -Why 'It names the release and the versioned archive to check.' -Fix $hint
    }
    return $tagVersion
}

function Assert-SourceChoice {
    $sources = @([bool]$Latest, -not [string]::IsNullOrEmpty($Repo), -not [string]::IsNullOrEmpty($LocalDir)) | Where-Object { $_ }
    if (@($sources).Count -ne 1) {
        Write-BuildFailure -What 'Give exactly one source: -Repo, -LocalDir or -Latest.' `
            -Why 'The verifier reads a release through the GitHub API, a directory of staged assets, or the public latest download; mixing them has no meaning.' `
            -Fix 'Use -Repo owner/name -Tag vX.Y.Z [-Token t], or -LocalDir <dir> -Version X.Y.Z, or -Latest.'
    }
    if ($Repo) {
        $segments = @($Repo -split '/')
        if ($Repo -cnotmatch $RepoPattern -or @($segments | Where-Object { $_ -cmatch $DotsOnlyPattern }).Count -gt 0) {
            Write-BuildFailure -What "The repository '$Repo' is not owner/name." -Why 'It becomes part of the API URL, so it is restricted to letters, digits, dot, dash and underscore.' -Fix 'Pass -Repo Zuehlke/teststand-mcp.'
        }
    }
    if ($LocalDir -and -not (Test-Path -LiteralPath (Resolve-BuildPath $LocalDir) -PathType Container)) {
        Write-BuildFailure -What "The directory $LocalDir does not exist." -Why 'It should hold the release assets.' -Fix 'Pass the directory the build wrote the assets to.'
    }
}

function New-DownloadRecorder {
    param([string]$Phase)
    if (-not $OwnDownloadsPath) { return $null }
    $recordPath = $OwnDownloadsPath
    $optional = @{}
    if ($RunId) { $optional.RunId = $RunId }
    if ($Date) { $optional.Date = $Date }
    return { param([string]$AssetName) Add-OwnDownload -Path $recordPath -Asset $AssetName -Phase $Phase @optional }.GetNewClosure()
}

function Write-StepOutputs {
    param($Release, [object[]]$Assets, [string[]]$RequiredNames)
    $releaseId = [string](Get-JsonProperty $Release 'id')
    if ($releaseId -cmatch $AssetIdPattern) { Add-GitHubOutput -Name 'release_id' -Value $releaseId }
    $ids = [ordered]@{}
    foreach ($name in $RequiredNames) {
        $asset = @($Assets | Where-Object { $_.Name -ceq $name })[0]
        if ($null -ne $asset -and $asset.Id -cmatch $AssetIdPattern) { $ids[$name] = [int64]$asset.Id }
    }
    Add-GitHubOutput -Name 'asset_ids' -Value (ConvertTo-Json -InputObject $ids -Compress)
}

function Test-LatestDownload {
    param($Connection, [string]$TempRoot)
    $transfer = [pscustomobject]@{ Requested = 0; Saved = @{} }
    $requests = @(foreach ($name in @($ReleaseArchiveName, $ReleaseDigestName)) {
        New-DownloadRequest -Name $name -Uri (Get-LatestDownloadUrl -AssetName $name) -Accept $BinaryAccept -UseToken $false -Size $null
    })
    $recorder = New-DownloadRecorder -Phase $PublishedPhase
    $destDir = Join-Path $TempRoot 'latest'
    [void](New-Item -ItemType Directory -Path $destDir -Force)
    $outcome = Invoke-FetchWithRetry -Fetch { param($attempt) Save-Downloads $Connection $requests $destDir $transfer $recorder } `
        -Delay $Delay -DelaySeconds $RetryDelaySeconds -MaxAttempts $MaxAttempts
    Assert-DownloadsSucceeded $outcome 'The latest release'

    try {
        $digest = ConvertFrom-DigestText -Text (Read-Utf8Text $transfer.Saved[$ReleaseDigestName])
    } catch {
        Assert-ReleaseFailure 'The latest release' @(New-Problem 'digest-malformed' @($_.Exception.Message)) 'Api'
    }
    $archiveHash = Get-FileSha256 $transfer.Saved[$ReleaseArchiveName]
    if ($digest.Name -cne $ReleaseArchiveName) { Assert-ReleaseFailure 'The latest release' @(New-Problem 'digest-name' @($digest.Name)) 'Api' }
    if ($digest.Hash -cne $archiveHash) { Assert-ReleaseFailure 'The latest release' @(New-Problem 'latest-mismatch' @($archiveHash, $digest.Hash)) 'Api' }
    Write-Host "The latest download of $ReleaseArchiveName matches the published archive digest ($archiveHash)."
    Write-Host "Requested $($transfer.Requested) asset download(s) in $($outcome.Attempts) attempt(s)."
}

function Test-ApiRelease {
    param($Connection, [string]$Tag, [string]$ReleaseVersion, [string]$TempRoot)
    $release = Get-ReleaseFromApi $Connection $Repo $Tag
    $listedAssets = @(ConvertTo-ListedAssets $release)
    Assert-ReleaseFailure "Release $Tag" @(Get-ReleaseProblems -Assets $listedAssets -Version $ReleaseVersion -Scope Listing) 'Api'

    $requiredNames = @(Get-RequiredAssetNames -Version $ReleaseVersion)
    $requests = @(foreach ($name in $requiredNames) {
        $asset = @($listedAssets | Where-Object { $_.Name -ceq $name })[0]
        if ($asset.Id -cnotmatch $AssetIdPattern) {
            Write-BuildFailure -What "The release lists $name with an unusable asset id '$($asset.Id)'." `
                -Why 'The asset cannot be downloaded through the API without its numeric id. Running the verifier again will not help.' -Fix 'Check the release in the GitHub UI; start a new release run if the asset is broken.'
        }
        New-DownloadRequest -Name $name -Uri "$($Connection.ApiBaseUrl)/repos/$Repo/releases/assets/$($asset.Id)" -Accept $BinaryAccept -UseToken $true -Size $asset.Size
    })

    $isDraft = [bool]$Draft -or ((Get-JsonProperty $release 'draft') -eq $true)
    $recorder = New-DownloadRecorder -Phase $(if ($isDraft) { $DraftPhase } else { $PublishedPhase })
    $transfer = [pscustomobject]@{ Requested = 0; Saved = @{} }
    $destDir = Join-Path $TempRoot 'release'
    [void](New-Item -ItemType Directory -Path $destDir -Force)
    $outcome = Invoke-FetchWithRetry -Fetch { param($attempt) Save-Downloads $Connection $requests $destDir $transfer $recorder } `
        -Delay $Delay -DelaySeconds $RetryDelaySeconds -MaxAttempts $MaxAttempts
    Assert-DownloadsSucceeded $outcome "Release $Tag"

    foreach ($asset in $listedAssets) { if ($transfer.Saved.ContainsKey($asset.Name)) { $asset.Path = $transfer.Saved[$asset.Name] } }
    Assert-ReleaseFailure "Release $Tag" @(Get-ReleaseProblems -Assets $listedAssets -Version $ReleaseVersion -Scope Content) 'Api'

    Write-StepOutputs -Release $release -Assets $listedAssets -RequiredNames $requiredNames
    Write-Host "Release $Tag verified: the $($requiredNames.Count) required assets match (digest, manifest, versioned archive), every asset uploaded by $ReleaseUploaderLogin."
    Write-Host "Requested $($transfer.Requested) asset download(s) in $($outcome.Attempts) attempt(s)."
}

function Test-LocalRelease {
    param([string]$Tag, [string]$ReleaseVersion)
    $subject = if ($Tag) { "Release $Tag" } else { "The staged assets of version $ReleaseVersion" }
    if ($ReleaseJson -and -not $Tag) {
        Write-BuildFailure -What '-ReleaseJson needs -Tag.' -Why 'The release is looked up in the JSON by its tag.' -Fix 'Pass -Tag vX.Y.Z together with -ReleaseJson.'
    }
    $listing = Get-LocalListing -LocalDir $LocalDir -Tag $Tag -ReleaseJson $ReleaseJson
    Assert-ReleaseFailure $subject @(Get-ReleaseProblems -Assets $listing.Assets -Version $ReleaseVersion -CheckUploader $listing.CheckUploader) 'Local'
    $uploaderNote = if ($listing.CheckUploader) { "every asset uploaded by $ReleaseUploaderLogin" } else { 'uploader check skipped (no release metadata given)' }
    Write-Host "$subject verified: the $(@(Get-RequiredAssetNames -Version $ReleaseVersion).Count) required assets match (digest, manifest, versioned archive), $uploaderNote."
    Write-Host 'Requested 0 asset download(s) in 1 attempt(s) (local assets).'
}

try {
    Import-Module (Join-Path $PSScriptRoot 'ReleaseAssets.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'ReleaseVerdict.psm1') -Force

    Assert-SourceChoice
    $connection = New-Connection -Token $Token -HttpGet $HttpGet -TimeoutSeconds $TimeoutSeconds -ApiBaseUrl $ApiBaseUrl
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('release-verify-' + [Guid]::NewGuid().ToString('N'))
    try {
        if ($Latest) {
            Test-LatestDownload -Connection $connection -TempRoot $tempRoot
        } elseif ($LocalDir) {
            $releaseVersion = Resolve-ReleaseVersion -Tag $Tag -Version $Version -IsLocal $true -AllowRehearsal ([bool]$Rehearsal)
            Test-LocalRelease -Tag $Tag -ReleaseVersion $releaseVersion
        } else {
            if (-not $Tag) { Write-BuildFailure -What 'No release tag was given.' -Why 'It names the release to read from the API.' -Fix 'Pass -Tag vX.Y.Z.' }
            $releaseVersion = Resolve-ReleaseVersion -Tag $Tag -Version $Version -IsLocal $false -AllowRehearsal ([bool]$Rehearsal)
            Test-ApiRelease -Connection $connection -Tag $Tag -ReleaseVersion $releaseVersion -TempRoot $tempRoot
        }
    } finally {
        Remove-BuildTempTree -Path $tempRoot
    }
    exit 0
} catch {
    Write-Host (Get-ScriptFailureText -ErrorRecord $_)
    exit 1
}
