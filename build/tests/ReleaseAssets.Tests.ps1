# ============================================================================
#  ReleaseAssets.Tests.ps1 - plain PowerShell asserts for build/BuildCommon.psm1,
#  build/ReleaseAssets.psm1, build/ReleaseVerdict.psm1, build/Assert-ReleaseTag.ps1 and
#  build/Assert-PublishedRelease.ps1.
#  Runs under Windows PowerShell 5.1 and PowerShell 7:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\tests\ReleaseAssets.Tests.ps1
#  Prints PASS/FAIL per case and exits non-zero when any case fails.
#  NO network: the verifier's HTTP layer is replaced by a scriptblock.
#  ASCII only on purpose: 5.1 reads a BOM-less script as ANSI.
# ============================================================================
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$BuildDir = Join-Path $RepoRoot 'build'
$CommonModulePath = Join-Path $BuildDir 'BuildCommon.psm1'
$ModulePath = Join-Path $BuildDir 'ReleaseAssets.psm1'
$VerdictModulePath = Join-Path $BuildDir 'ReleaseVerdict.psm1'
$TagGatePath = Join-Path $BuildDir 'Assert-ReleaseTag.ps1'
$VerifierPath = Join-Path $BuildDir 'Assert-PublishedRelease.ps1'
$MarketplacePath = Join-Path $RepoRoot '.claude-plugin\marketplace.json'
$OwnDownloadsFixturePath = Join-Path $PSScriptRoot 'fixtures\own-downloads.json'

$ExpectedRepoSlug = 'Zuehlke/teststand-mcp'
$ExpectedLatestUrl = 'https://github.com/Zuehlke/teststand-mcp/releases/latest/download/teststand-mcp.zip'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ShaCrypto = [System.Security.Cryptography.SHA256]::Create()
$SampleCommit = ('0123456789abcdef' * 2) + '01234567'   # 40 hex characters
$ArabicIndicOne = [string][char]0x0661                  # a digit that \d matches in .NET but is not 0-9
$Utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)

$BotLogin = 'github-actions[bot]'
$ApiAssetUrlFormat = 'https://api.github.com/repos/Zuehlke/teststand-mcp/releases/assets/{0}'
$FirstAssetId = 1000
$ReleaseId = 777
$DefaultRetryDelay = 30
$FakeToken = 'ghs_FAKE_TOKEN_FOR_TESTS'
$ListPageSize = 100
$MaxListPages = 10
$NeverHelps = 'Running the verifier again will not help'
$MayHelp = 'Running the verifier again may help'
$ZeroHash = '0' * 64
$FixtureRunId = '1234567890'
$FixtureVerifyDate = '2026-08-20'
$FixtureLatestDate = '2026-08-21'

# The tag table of the Gherkin outline, verbatim.
$TagTable = @(
    @{ Tag = 'v1.9.0';     Verdict = 'valid, version 1.9.0' }
    @{ Tag = 'v1.10.0';    Verdict = 'valid, version 1.10.0' }
    @{ Tag = 'V1.9.0';     Verdict = 'rejected: upper-case V' }
    @{ Tag = 'v1.9';       Verdict = 'rejected: two components' }
    @{ Tag = 'v1.9.0.1';   Verdict = 'rejected: four components' }
    @{ Tag = 'v1.9.0-rc';  Verdict = 'rejected: suffix' }
    @{ Tag = 'v01.9.0';    Verdict = 'rejected: leading zero' }
    @{ Tag = '1.9.0';      Verdict = 'rejected: no v' }
    @{ Tag = 'latest';     Verdict = 'rejected: not a version' }
    @{ Tag = '';           Verdict = 'rejected: empty' }
)

. (Join-Path $PSScriptRoot 'TestHarness.ps1')
$script:TempDirPrefix = 'ReleaseAssetsTests_'

# --- Asserts ---------------------------------------------------------------------------------------
# The three parts of every build failure: labelled What / Why / Fix lines, each with content.
function Assert-ThreePartFailure {
    param([string]$Text)
    foreach ($label in @('What', 'Why', 'Fix')) {
        Assert-True ($Text -cmatch "(?m)^${label}: +\S") "failure output has no '${label}:' line with content. Output was:`n$Text"
    }
}

function Assert-NoBom {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq $Utf8Bom[0] -and $bytes[1] -eq $Utf8Bom[1] -and $bytes[2] -eq $Utf8Bom[2])) "$Path starts with a UTF-8 BOM"
}

# The record's flat rows ("date|asset|draft|published"), for comparison with the shared fixture.
function Get-OwnDownloadRows {
    param($Record)
    $rows = @()
    foreach ($date in $Record.Counts.Keys) {
        foreach ($asset in $Record.Counts[$date].Keys) {
            $cell = $Record.Counts[$date][$asset]
            $rows += "$date|$asset|$($cell['draft'])|$($cell['published'])"
        }
    }
    return (($rows | Sort-Object) -join "`n")
}

function Assert-RecordMatchesFixture {
    param($Record)
    $fixture = Read-OwnDownloads -Path $OwnDownloadsFixturePath
    Assert-Equal $fixture.RunId $Record.RunId 'run_id'
    Assert-Equal (Get-OwnDownloadRows $fixture) (Get-OwnDownloadRows $Record) 'counts per date, asset and phase'
}

# --- Files and processes ----------------------------------------------------------------------------
function Write-TextFile {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Get-Sha256Of {
    param([byte[]]$Bytes)
    return ([BitConverter]::ToString($ShaCrypto.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
}

# Runs a script in-process; returns its exit code and everything it printed. EVERY failing run must
# print the three parts, so that is checked here, once, for every script and every case.
function Invoke-Script {
    param([string]$Path, [hashtable]$Arguments = @{})
    $global:LASTEXITCODE = 0
    $lines = @(& $Path @Arguments *>&1 | ForEach-Object { "$_" })
    $run = @{ ExitCode = $global:LASTEXITCODE; Output = ($lines -join "`n") }
    if ($run.ExitCode -ne 0) {
        try { Assert-ThreePartFailure $run.Output } catch { throw "$(Split-Path -Leaf $Path) exited $($run.ExitCode) without a three-part failure: $($_.Exception.Message)" }
    }
    return $run
}

# Overrides an environment variable around a block, restoring the old value.
function Use-EnvironmentVariable {
    param([string]$Name, $Value, [scriptblock]$Body)
    $old = [Environment]::GetEnvironmentVariable($Name)
    try {
        [Environment]::SetEnvironmentVariable($Name, $Value)
        & $Body
    } finally {
        [Environment]::SetEnvironmentVariable($Name, $old)
    }
}

# --- Zip and release fixtures -------------------------------------------------------------------------
# Zip entries are named with '/'. ZipFile.CreateFromDirectory is NOT used: under Windows PowerShell 5.1 it
# writes '\' separators (measured). Entries are written verbatim, so a test can ask for a bad name.
function New-ZipFromEntries {
    param([string]$ZipPath, [object[]]$Entries)
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Create($ZipPath)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $Entries) {
                $zipEntry = $archive.CreateEntry($entry.Name)
                $entryStream = $zipEntry.Open()
                try { $entryStream.Write($entry.Bytes, 0, $entry.Bytes.Length) } finally { $entryStream.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-DirectoryEntries {
    param([string]$SourceDir)
    $root = [IO.Path]::GetFullPath($SourceDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return @(Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force | ForEach-Object {
        @{ Name = $_.FullName.Substring($root.Length).Replace('\', '/'); Bytes = [IO.File]::ReadAllBytes($_.FullName) }
    })
}

function New-ZipFromDirectory {
    param([string]$SourceDir, [string]$ZipPath)
    New-ZipFromEntries -ZipPath $ZipPath -Entries (Get-DirectoryEntries $SourceDir)
}

# A small staged tree: nested folders, a name with a space and non-text bytes.
function New-StagedTree {
    $dir = Join-Path (New-TempDir) 'staged'
    Write-TextFile (Join-Path $dir 'VERSION.txt') "tag=v1.9.0`n"
    Write-TextFile (Join-Path $dir '.claude-plugin\plugin.json') '{"name":"teststand-mcp"}'
    Write-TextFile (Join-Path $dir 'bin\appsettings.json') '{}'
    Write-TextFile (Join-Path $dir 'bin\scripts\with space.txt') 'spaced'
    [IO.File]::WriteAllBytes((Join-Path $dir 'bin\TestStandMCP.exe'), [byte[]](0, 1, 2, 253, 254, 255, 0, 77))
    return $dir
}

function Set-ZeroDigest {
    param($Fixture)
    Write-TextFile (Join-Path $Fixture.Dir 'teststand-mcp.sha256') ($ZeroHash + '  teststand-mcp.zip' + "`n")
}

# Rewrites the manifest asset: $Edit receives the manifest's lines and returns the new lines.
function Edit-ManifestLines {
    param($Fixture, [scriptblock]$Edit)
    $path = Join-Path $Fixture.Dir 'teststand-mcp.manifest.sha256'
    $lines = @([IO.File]::ReadAllText($path, $Utf8NoBom) -split "`n" | Where-Object { $_ })
    $edited = @(& $Edit $lines)
    Write-TextFile $path (($edited -join "`n") + "`n")
}

# A release as a user would download it: the four assets of version 1.9.0 in one directory.
# -ExtraEntries puts additional entries (verbatim names) into the zip that the manifest does not know.
function New-ReleaseFixture {
    param([string]$Version = '1.9.0', [object[]]$ExtraEntries = @(), [switch]$CorruptZip)
    $staged = New-StagedTree
    $dir = Join-Path (New-TempDir) 'assets'
    [void](New-Item -ItemType Directory -Path $dir)
    $zip = Join-Path $dir 'teststand-mcp.zip'
    if ($CorruptZip) { [IO.File]::WriteAllBytes($zip, [byte[]](80, 75, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8)) }
    else { New-ZipFromEntries -ZipPath $zip -Entries ((Get-DirectoryEntries $staged) + $ExtraEntries) }
    Write-TextFile (Join-Path $dir 'teststand-mcp.sha256') (New-ArchiveDigest -ArchivePath $zip)
    Write-TextFile (Join-Path $dir 'teststand-mcp.manifest.sha256') (New-ArchiveManifest -StagedDir $staged)
    Copy-Item -LiteralPath $zip -Destination (Join-Path $dir "teststand-mcp-v$Version.zip")
    return @{ Dir = $dir; Version = $Version; Tag = "v$Version"; Staged = $staged }
}

function Get-AssetSizes {
    param($Fixture)
    $sizes = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $Fixture.Dir -File)) { $sizes[$file.Name] = [int64]$file.Length }
    return $sizes
}

# The GitHub releases-list JSON: a decoy plus one release carrying the tag.
function New-ReleaseJsonText {
    param(
        [string]$Tag, [string[]]$AssetNames, [hashtable]$UploaderByAsset = @{}, [bool]$IsDraft = $true,
        [hashtable]$SizeByAsset = @{}, [hashtable]$IdByAsset = @{}, [string[]]$NoUploaderFor = @()
    )
    $assets = @()
    for ($index = 0; $index -lt $AssetNames.Count; $index++) {
        $name = $AssetNames[$index]
        $login = $BotLogin
        if ($UploaderByAsset.ContainsKey($name)) { $login = $UploaderByAsset[$name] }
        $id = $FirstAssetId + $index
        if ($IdByAsset.ContainsKey($name)) { $id = $IdByAsset[$name] }
        $asset = @{ id = $id; name = $name; url = ($ApiAssetUrlFormat -f $id); uploader = @{ login = $login } }
        if ($NoUploaderFor -contains $name) { $asset.uploader = $null }
        if ($SizeByAsset.ContainsKey($name)) { $asset.size = $SizeByAsset[$name] }
        $assets += $asset
    }
    $decoy = @{ id = 1; tag_name = 'v0.0.1'; draft = $false; assets = @() }
    $release = @{ id = $ReleaseId; tag_name = $Tag; draft = $IsDraft; assets = $assets }
    return (ConvertTo-Json -InputObject @($decoy, $release) -Depth 6)
}

function Invoke-LocalVerify {
    param($Fixture, [hashtable]$UploaderByAsset = @{}, [switch]$NoReleaseJson, [hashtable]$Extra = @{}, [string[]]$ListedNames = @())
    $arguments = @{ Tag = $Fixture.Tag; LocalDir = $Fixture.Dir }
    if (-not $NoReleaseJson) {
        $names = if ($ListedNames.Count -gt 0) { $ListedNames } else { @(Get-RequiredAssetNames -Version $Fixture.Version) }
        $jsonPath = Join-Path (New-TempDir) 'release.json'
        Write-TextFile $jsonPath (New-ReleaseJsonText -Tag $Fixture.Tag -AssetNames $names -UploaderByAsset $UploaderByAsset)
        $arguments.ReleaseJson = $jsonPath
    }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    return Invoke-Script $VerifierPath $arguments
}

# A fake GitHub at the HTTP boundary. $Plan decides, per asset and per download count, whether a download
# fails (returns the failure text) or succeeds ($null). The state records every request. -Pages maps a
# page number to its releases-list JSON (default: page 1 is the release of the fixture).
function New-FakeApi {
    param(
        $Fixture, [scriptblock]$Plan = { param($Name, $Count) $null }, [string]$ReleasesFailure = $null,
        [hashtable]$Pages = $null, [hashtable]$ReleaseOptions = @{}
    )
    $names = @(Get-RequiredAssetNames -Version $Fixture.Version)
    if ($null -eq $Pages) {
        $options = @{ Tag = $Fixture.Tag; AssetNames = $names; SizeByAsset = (Get-AssetSizes $Fixture) }
        foreach ($key in $ReleaseOptions.Keys) { $options[$key] = $ReleaseOptions[$key] }
        $Pages = @{ 1 = (New-ReleaseJsonText @options) }
    }
    $nameById = @{}
    foreach ($pageText in $Pages.Values) {
        foreach ($release in @($pageText | ConvertFrom-Json | ForEach-Object { $_ })) {
            foreach ($asset in @($release.assets)) { $nameById[[string]$asset.id] = $asset.name }
        }
    }
    $dir = $Fixture.Dir
    $state = @{ Calls = (New-Object System.Collections.ArrayList); Downloads = @{} }
    $http = {
        param($Uri, $Headers, $OutFile, $TimeoutSeconds)
        [void]$state.Calls.Add(@{ Uri = $Uri; Headers = $Headers; OutFile = $OutFile; TimeoutSeconds = $TimeoutSeconds })
        $name = $null
        if ($Uri -match '/releases\?.*page=(\d+)') {
            if ($ReleasesFailure) { throw $ReleasesFailure }
            if ($Pages.ContainsKey([int]$Matches[1])) { return $Pages[[int]$Matches[1]] }
            return '[]'
        }
        if ($Uri -match '/releases/assets/(\d+)\z') { $name = $nameById[$Matches[1]] }
        elseif ($Uri -match '/releases/latest/download/([^/]+)\z') { $name = $Matches[1] }
        if ($null -eq $name) { throw "unexpected request $Uri" }
        if (-not $state.Downloads.ContainsKey($name)) { $state.Downloads[$name] = 0 }
        $state.Downloads[$name] = $state.Downloads[$name] + 1
        $failure = & $Plan $name $state.Downloads[$name]
        if ($failure) { throw $failure }
        Copy-Item -LiteralPath (Join-Path $dir $name) -Destination $OutFile
        return
    }.GetNewClosure()
    return @{ Http = $http; State = $state }
}

function Invoke-ApiVerify {
    param($Fixture, $Api, [string]$OwnDownloadsPath, [hashtable]$Extra = @{}, [switch]$ForceDraft, [switch]$OmitToken, [string]$Tag)
    $delays = New-Object System.Collections.ArrayList
    $delay = { param([int]$Seconds) [void]$delays.Add($Seconds) }.GetNewClosure()
    if (-not $Tag) { $Tag = $Fixture.Tag }
    $arguments = @{ Repo = $ExpectedRepoSlug; Tag = $Tag; HttpGet = $Api.Http; Delay = $delay }
    if (-not $OmitToken) { $arguments.Token = $FakeToken }
    if ($ForceDraft) { $arguments.Draft = $true }
    if ($OwnDownloadsPath) { $arguments.OwnDownloadsPath = $OwnDownloadsPath }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    $run = Invoke-Script $VerifierPath $arguments
    $run.Delays = @($delays)
    return $run
}

function Invoke-LatestVerify {
    param($Api, [hashtable]$Extra = @{})
    $delays = New-Object System.Collections.ArrayList
    $delay = { param([int]$Seconds) [void]$delays.Add($Seconds) }.GetNewClosure()
    $arguments = @{ Latest = $true; HttpGet = $Api.Http; Delay = $delay }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    $run = Invoke-Script $VerifierPath $arguments
    $run.Delays = @($delays)
    return $run
}

function Get-AssetRequests {
    param($Api)
    return @($Api.State.Calls | Where-Object { $_.Uri -match '/releases/assets/' })
}

# 100 decoy releases: a full page of the releases list.
function New-FullPageJson {
    $page = @()
    for ($index = 1; $index -le $ListPageSize; $index++) { $page += @{ id = (5000 + $index); tag_name = "v0.0.$index"; draft = $false; assets = @() } }
    return (ConvertTo-Json -InputObject $page -Depth 4)
}

# --- Run -----------------------------------------------------------------------------------------------
# The scripts under test write step outputs, read GITHUB_* variables: never let a real CI value leak in or out.
$savedEnvironment = @{}
foreach ($name in @('GITHUB_OUTPUT', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_TOKEN')) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

try {
    $sharedOutput = Join-Path (New-TempDir) 'shared_github_output'
    [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', $sharedOutput)
    foreach ($name in @('GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_TOKEN')) { [Environment]::SetEnvironmentVariable($name, $null) }

    foreach ($path in @($CommonModulePath, $ModulePath, $VerdictModulePath)) { Assert-True (Test-Path -LiteralPath $path) "$path does not exist" }
    Import-Module $CommonModulePath -Force
    Import-Module $ModulePath -Force
    Import-Module $VerdictModulePath -Force

    # ============================================================================================
    #  BuildCommon
    # ============================================================================================
    Invoke-Case 'BuildCommon: Write-BuildFailure throws a message with all three labelled parts' {
        $message = $null
        try { Write-BuildFailure -What 'the thing broke' -Why 'because of X' -Fix "do Y`nthen Z" } catch { $message = $_.Exception.Message }
        Assert-True ($null -ne $message) 'expected a throw'
        Assert-ThreePartFailure $message
        Assert-Contains $message 'the thing broke' 'what'
        Assert-Contains $message 'because of X' 'why'
        Assert-Contains $message 'then Z' 'second fix line'
    }

    Invoke-Case 'BuildCommon: an empty part is refused, so no failure can lack one' {
        foreach ($call in @(
            { Write-BuildFailure -What '' -Why 'w' -Fix 'f' }
            { Write-BuildFailure -What 'a' -Why '' -Fix 'f' }
            { Write-BuildFailure -What 'a' -Why 'w' -Fix '' }
        )) {
            $thrown = $false
            try { & $call } catch { $thrown = $true; Assert-True ($_.Exception.Message -notmatch '(?m)^What: ') 'an empty part still produced a failure message' }
            Assert-True $thrown 'an empty part was accepted'
        }
    }

    Invoke-Case 'BuildCommon: Get-ScriptFailureText passes a build failure through and wraps any other error into three parts' {
        $built = $null
        try { Write-BuildFailure -What 'w' -Why 'y' -Fix 'f' } catch { $built = $_ }
        Assert-Equal $built.Exception.Message (Get-ScriptFailureText -ErrorRecord $built) 'pass-through'
        $plain = $null
        try { throw 'something odd' } catch { $plain = $_ }
        $text = Get-ScriptFailureText -ErrorRecord $plain
        Assert-ThreePartFailure $text
        Assert-Contains $text 'something odd' 'the original message'
    }

    Invoke-Case 'BuildCommon: Resolve-BuildPath resolves against the PowerShell location, not the process directory' {
        $dir = New-TempDir
        Push-Location -LiteralPath $dir
        try {
            Assert-Equal (Join-Path $dir 'file.txt') (Resolve-BuildPath 'file.txt') 'relative path'
            Assert-True ([Environment]::CurrentDirectory -cne $dir) 'the process directory must differ for this test to mean anything'
            Write-TextFile (Join-Path $dir 'file.txt') 'hello'
            Assert-Equal 'hello' (Read-Utf8Text 'file.txt') 'relative read'
        } finally { Pop-Location }
    }

    Invoke-Case 'BuildCommon: Read-Utf8Text keeps a leading BOM visible, rejects invalid UTF-8 and names a missing file' {
        $dir = New-TempDir
        [IO.File]::WriteAllBytes((Join-Path $dir 'bom.txt'), [byte[]](0xEF, 0xBB, 0xBF, 0x41))
        Assert-Equal ([string][char]0xFEFF + 'A') (Read-Utf8Text (Join-Path $dir 'bom.txt')) 'BOM kept'
        [IO.File]::WriteAllBytes((Join-Path $dir 'bad.txt'), [byte[]](0xC3, 0x28))
        $message = $null
        try { [void](Read-Utf8Text (Join-Path $dir 'bad.txt')) } catch { $message = $_.Exception.Message }
        Assert-True ($null -ne $message) 'invalid UTF-8 was accepted'
        Assert-ThreePartFailure $message
        Assert-Contains $message 'not valid UTF-8' 'reason'
        $message = $null
        try { [void](Read-Utf8Text (Join-Path $dir 'absent.txt')) } catch { $message = $_.Exception.Message }
        Assert-ThreePartFailure $message
        Assert-Contains $message 'absent.txt' 'file name'
    }

    Invoke-Case 'BuildCommon: Add-GitHubOutput appends name=value lines without a BOM and does nothing outside Actions' {
        $outFile = Join-Path (New-TempDir) 'out'
        Write-TextFile $outFile "seed=1`n"
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile {
            Add-GitHubOutput -Name 'release_id' -Value '42'
            Add-GitHubOutput -Name 'tag' -Value 'v1.9.0'
        }
        Assert-NoBom $outFile
        Assert-Equal "seed=1`nrelease_id=42`ntag=v1.9.0`n" ([IO.File]::ReadAllText($outFile, $Utf8NoBom)) 'file text'
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $null { Add-GitHubOutput -Name 'x' -Value 'y' }
    }

    Invoke-Case 'BuildCommon: Add-GitHubOutput refuses a name or value that could inject a second output' {
        foreach ($call in @(
            { Add-GitHubOutput -Name 'bad name' -Value 'x' }
            { Add-GitHubOutput -Name 'ok' -Value "a`nevil=1" }
        )) {
            $message = $null
            try { & $call } catch { $message = $_.Exception.Message }
            Assert-True ($null -ne $message) 'expected a failure'
            Assert-ThreePartFailure $message
        }
    }

    Invoke-Case 'BuildCommon: Remove-BuildTempTree retries, then warns with the path that is left behind' {
        $dir = New-TempDir
        $inner = Join-Path $dir 'cache'
        Write-TextFile (Join-Path $inner 'locked.bin') 'x'
        $lock = [IO.File]::Open((Join-Path $inner 'locked.bin'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $warnings = @(& { Remove-BuildTempTree -Path $inner -Attempts 2 -DelayMilliseconds 0 } 3>&1 | ForEach-Object { "$_" })
            Assert-True ($warnings.Count -eq 1 -and $warnings[0].Contains($inner)) "expected one warning naming $inner, got: $($warnings -join '|')"
        } finally { $lock.Dispose() }
        $quiet = @(& { Remove-BuildTempTree -Path $inner -Attempts 2 -DelayMilliseconds 0 } 3>&1)
        Assert-Equal 0 $quiet.Count 'warnings once the lock is gone'
        Assert-True (-not (Test-Path -LiteralPath $inner)) 'the directory should be gone'
    }

    # ============================================================================================
    #  Asset contract
    # ============================================================================================
    Invoke-Case 'contract: the four asset names and the repo slug are the published ones' {
        Assert-Equal $ExpectedRepoSlug $ReleaseRepoSlug 'repo slug'
        Assert-Equal 'teststand-mcp.zip' $ReleaseArchiveName 'archive'
        Assert-Equal 'teststand-mcp.sha256' $ReleaseDigestName 'digest'
        Assert-Equal 'teststand-mcp.manifest.sha256' $ReleaseManifestName 'manifest'
        Assert-Equal 'github-actions[bot]' $ReleaseUploaderLogin 'uploader'
        Assert-Equal 'teststand-mcp-v1.9.0.zip' (Get-VersionedArchiveName -Version '1.9.0') 'versioned archive'
        Assert-Equal 'teststand-mcp-v0.0.0-ci.zip' (Get-VersionedArchiveName -Version '0.0.0-ci') 'versioned archive of a ci build'
        Assert-Equal 'teststand-mcp.zip|teststand-mcp.sha256|teststand-mcp.manifest.sha256|teststand-mcp-v1.9.0.zip' ((Get-RequiredAssetNames -Version '1.9.0') -join '|') 'required assets in download order'
    }

    Invoke-Case 'contract: the exported constants are read-only' {
        foreach ($name in @('ReleaseRepoSlug', 'ReleaseArchiveName', 'ReleaseDigestName', 'ReleaseManifestName', 'ReleaseUploaderLogin', 'ArchiveProblemKinds')) {
            $before = (Get-Variable -Name $name -ValueOnly) -join ','
            $thrown = $false
            try { Set-Variable -Name $name -Value 'changed' -Scope Script } catch { $thrown = $true }
            Assert-True $thrown "$name could be overwritten"
            Assert-Equal $before ((Get-Variable -Name $name -ValueOnly) -join ',') "$name after the attempt"
        }
    }

    Invoke-Case 'contract: the latest-download URL builder gives the fixed archive URL' {
        Assert-Equal $ExpectedLatestUrl (Get-LatestDownloadUrl) 'default asset'
        Assert-Equal 'https://github.com/Zuehlke/teststand-mcp/releases/latest/download/teststand-mcp.sha256' (Get-LatestDownloadUrl -AssetName $ReleaseDigestName) 'digest asset'
    }

    Invoke-Case 'contract: marketplace.json source.url equals the URL builder output (ties slice 2 to this owner)' {
        Assert-True (Test-Path -LiteralPath $MarketplacePath) "$MarketplacePath does not exist"
        $marketplace = [IO.File]::ReadAllText($MarketplacePath, $Utf8NoBom) | ConvertFrom-Json
        $plugin = @($marketplace.plugins | Where-Object { $_.name -ceq 'teststand-mcp' })
        Assert-Equal 1 $plugin.Count 'plugins named teststand-mcp'
        Assert-Equal (Get-LatestDownloadUrl) $plugin[0].source.url 'marketplace archive url'
    }

    # ============================================================================================
    #  Tag rule
    # ============================================================================================
    foreach ($row in $TagTable) {
        Invoke-Case "tag table: [$($row.Tag)] -> $($row.Verdict)" {
            $result = ConvertFrom-ReleaseTag -Tag $row.Tag
            Assert-Equal $row.Verdict $result.Verdict 'verdict'
            Assert-Equal $row.Verdict.StartsWith('valid') $result.IsValid 'IsValid'
            Assert-Equal $false $result.IsRehearsal 'IsRehearsal'
        }
    }

    Invoke-Case 'tag: a valid tag yields the plain version; a rejected one has none' {
        Assert-Equal '1.10.0' (ConvertFrom-ReleaseTag -Tag 'v1.10.0').Version 'version'
        Assert-Equal '0.0.0' (ConvertFrom-ReleaseTag -Tag 'v0.0.0').Version 'version of v0.0.0'
        Assert-True ($null -eq (ConvertFrom-ReleaseTag -Tag 'v1.9').Version) 'a rejected tag must have no version'
    }

    Invoke-Case 'tag: null and whitespace are empty' {
        Assert-Equal 'rejected: empty' (ConvertFrom-ReleaseTag -Tag $null).Verdict 'null'
        Assert-Equal 'rejected: empty' (ConvertFrom-ReleaseTag -Tag '   ').Verdict 'whitespace'
    }

    Invoke-Case 'tag: a trailing newline, a leading space and non-ASCII digits are not a version' {
        Assert-True (-not (ConvertFrom-ReleaseTag -Tag "v1.9.0`n").IsValid) 'trailing newline accepted'
        Assert-True (-not (ConvertFrom-ReleaseTag -Tag ' v1.9.0').IsValid) 'leading space accepted'
        Assert-True (-not (ConvertFrom-ReleaseTag -Tag "v${ArabicIndicOne}.9.0").IsValid) 'a non-ASCII digit accepted'
    }

    Invoke-Case 'tag: only a case or missing-v mistake gets a suggested tag' {
        Assert-Equal 'v1.9.0' (ConvertFrom-ReleaseTag -Tag 'V1.9.0').SuggestedTag 'upper-case V'
        Assert-Equal 'v1.9.0' (ConvertFrom-ReleaseTag -Tag '1.9.0').SuggestedTag 'no v'
        foreach ($tag in @('v1.9', 'V1.9', 'v01.9.0', 'v1.9.0-rc', 'v1.9.0.1', 'latest', '1.9', '')) {
            Assert-True ($null -eq (ConvertFrom-ReleaseTag -Tag $tag).SuggestedTag) "no version may be invented for [$tag]"
        }
    }

    Invoke-Case 'tag: -AllowRehearsal accepts only v<X.Y.Z>-rehearsal with a valid base' {
        $rehearsal = ConvertFrom-ReleaseTag -Tag 'v0.0.1-rehearsal' -AllowRehearsal
        Assert-Equal $true $rehearsal.IsValid 'IsValid'
        Assert-Equal $true $rehearsal.IsRehearsal 'IsRehearsal'
        Assert-Equal '0.0.1' $rehearsal.Version 'Version is the plain X.Y.Z'
        Assert-Equal 'v0.0.1-rehearsal' $rehearsal.Tag 'Tag'
        foreach ($tag in @('V0.0.1-rehearsal', 'v0.0-rehearsal', 'v01.0.1-rehearsal', 'v0.0.1-rehearsal2', 'v0.0.1-rc', 'v0.0.1-rehearsal-rehearsal', '-rehearsal')) {
            Assert-Equal $false (ConvertFrom-ReleaseTag -Tag $tag -AllowRehearsal).IsValid "[$tag] with -AllowRehearsal"
        }
        Assert-Equal 'rejected: suffix' (ConvertFrom-ReleaseTag -Tag 'v0.0.1-rehearsal').Verdict 'without -AllowRehearsal'
        Assert-Equal $true (ConvertFrom-ReleaseTag -Tag 'v1.9.0' -AllowRehearsal).IsValid 'a normal tag still passes'
        Assert-Equal $false (ConvertFrom-ReleaseTag -Tag 'v1.9.0' -AllowRehearsal).IsRehearsal 'a normal tag is no rehearsal'
    }

    # ============================================================================================
    #  Tag gate script
    # ============================================================================================
    Invoke-Case 'gate: a valid tag exits 0 and appends version= and tag= to GITHUB_OUTPUT' {
        $outFile = Join-Path (New-TempDir) 'github_output'
        Write-TextFile $outFile "seed=1`n"
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile {
            $run = Invoke-Script $TagGatePath @{ Tag = 'v1.10.0' }
            Assert-Equal 0 $run.ExitCode 'exit code'
        }
        Assert-NoBom $outFile
        Assert-Equal "seed=1`nversion=1.10.0`ntag=v1.10.0`n" ([IO.File]::ReadAllText($outFile, $Utf8NoBom)) 'GITHUB_OUTPUT text'
    }

    Invoke-Case 'gate: a valid tag without GITHUB_OUTPUT still exits 0' {
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $null {
            $run = Invoke-Script $TagGatePath @{ Tag = 'v1.9.0' }
            Assert-Equal 0 $run.ExitCode 'exit code'
            Assert-Contains $run.Output '1.9.0' 'gate output'
        }
    }

    Invoke-Case 'gate: -Rehearsal accepts v0.0.1-rehearsal, writes the plain version, the tag and rehearsal=true' {
        $outFile = Join-Path (New-TempDir) 'github_output'
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile {
            $run = Invoke-Script $TagGatePath @{ Tag = 'v0.0.1-rehearsal'; Rehearsal = $true }
            Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        }
        Assert-Equal "version=0.0.1`ntag=v0.0.1-rehearsal`nrehearsal=true`n" ([IO.File]::ReadAllText($outFile, $Utf8NoBom)) 'GITHUB_OUTPUT text'
    }

    Invoke-Case 'gate: a rehearsal tag without -Rehearsal is rejected like any suffix' {
        $outFile = Join-Path (New-TempDir) 'github_output'
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile {
            $run = Invoke-Script $TagGatePath @{ Tag = 'v0.0.1-rehearsal' }
            Assert-Equal 1 $run.ExitCode 'exit code'
            Assert-Contains $run.Output 'rejected: suffix' 'verdict'
        }
        Assert-True (-not (Test-Path -LiteralPath $outFile)) 'GITHUB_OUTPUT must not be written for a rejected tag'
    }

    foreach ($row in @($TagTable | Where-Object { -not $_.Verdict.StartsWith('valid') })) {
        Invoke-Case "gate: [$($row.Tag)] exits 1, says '$($row.Verdict)' and writes nothing to GITHUB_OUTPUT" {
            $outFile = Join-Path (New-TempDir) 'github_output'
            Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile {
                $run = Invoke-Script $TagGatePath @{ Tag = $row.Tag }
                Assert-Equal 1 $run.ExitCode 'exit code'
                Assert-Contains $run.Output $row.Verdict 'gate output'
            }
            Assert-True (-not (Test-Path -LiteralPath $outFile)) 'GITHUB_OUTPUT must not be written for a rejected tag'
        }
    }

    # --- Scenario: A fixable tag gets the fix in a safe order -----------------------------------
    Invoke-Case 'gate: V1.9.0 says why the format is required and lists delete remote, delete local, create, push in order' {
        $run = Invoke-Script $TagGatePath @{ Tag = 'V1.9.0'; Commit = $SampleCommit }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'exactly v<major>.<minor>.<patch>' 'why the format is required'
        Assert-Contains $run.Output 'case-sensitive' 'why an upper-case V gets no answer from GitHub'
        Assert-Contains $run.Output 'PowerShell commands' 'which shell'
        Assert-Contains $run.Output 'only if the bad tag was pushed' 'the remote delete caveat'
        $steps = @(
            'git push origin --delete refs/tags/V1.9.0'
            'git tag -d -- V1.9.0'
            "git tag v1.9.0 $SampleCommit"
            'git push origin v1.9.0'
        )
        $previous = -1
        foreach ($step in $steps) {
            $index = $run.Output.IndexOf($step, [StringComparison]::Ordinal)
            Assert-True ($index -ge 0) "retag command missing: $step. Output was:`n$($run.Output)"
            Assert-True ($index -gt $previous) "retag command out of order: $step"
            $previous = $index
        }
        Assert-NotContains $run.Output 'rev-list' 'a commit lookup when the commit is known'
    }

    Invoke-Case 'gate: without a known commit the bad tag is resolved BEFORE it is deleted and the create step uses <commit>' {
        $run = Invoke-Script $TagGatePath @{ Tag = '1.9.0' }
        $lookup = $run.Output.IndexOf('git rev-list -n 1 refs/tags/1.9.0', [StringComparison]::Ordinal)
        $delete = $run.Output.IndexOf('git tag -d -- 1.9.0', [StringComparison]::Ordinal)
        Assert-True ($lookup -ge 0 -and $lookup -lt $delete) "the commit lookup must come before the delete. Output was:`n$($run.Output)"
        Assert-Contains $run.Output 'git tag v1.9.0 <commit>' 'create command'
    }

    Invoke-Case 'gate: the commit comes from GITHUB_SHA when it is a full sha' {
        Use-EnvironmentVariable 'GITHUB_SHA' $SampleCommit {
            $run = Invoke-Script $TagGatePath @{ Tag = 'V1.9.0' }
            Assert-Contains $run.Output "git tag v1.9.0 $SampleCommit" 'create command'
        }
    }

    # --- Scenario: An unfixable tag asks for a choice --------------------------------------------
    Invoke-Case 'gate: v1.9 asks the maintainer to choose a vX.Y.Z, shows the delete commands and the create template' {
        $run = Invoke-Script $TagGatePath @{ Tag = 'v1.9'; Commit = $SampleCommit }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'Choose the version you mean' 'asks for a choice'
        Assert-Contains $run.Output 'git push origin --delete refs/tags/v1.9' 'remote delete'
        Assert-Contains $run.Output 'git tag -d -- v1.9' 'local delete'
        Assert-True ($run.Output.IndexOf('git push origin --delete refs/tags/v1.9') -lt $run.Output.IndexOf('git tag -d -- v1.9')) 'remote delete must come first'
        Assert-Contains $run.Output "git tag vX.Y.Z $SampleCommit" 'create template'
        Assert-Contains $run.Output 'git push origin vX.Y.Z' 'push template'
        Assert-True ($run.Output -cnotmatch 'git tag v[0-9]') 'a concrete version was invented'
    }

    Invoke-Case 'gate: a tag that is not safe to paste gets an instruction, never a command' {
        foreach ($tag in @('-v1.9', 'v1.9$(x)', 'v1.9;x', "v1.9`a")) {
            $run = Invoke-Script $TagGatePath @{ Tag = $tag }
            Assert-Equal 1 $run.ExitCode "exit code for [$tag]"
            Assert-Contains $run.Output 'not safe to paste into a shell' "instruction for [$tag]"
            Assert-Contains $run.Output 'GitHub web UI' "instruction for [$tag]"
            Assert-NotContains $run.Output 'git tag -d' "delete command for [$tag]"
            Assert-NotContains $run.Output 'refs/tags/' "tag ref for [$tag]"
            Assert-True ($run.Output.IndexOf([char]7) -lt 0) 'a control character was echoed'
        }
    }

    Invoke-Case 'gate: an empty tag prints no delete commands' {
        $run = Invoke-Script $TagGatePath @{ Tag = '' }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'nothing to delete' 'explanation'
        Assert-NotContains $run.Output 'git tag -d' 'delete command'
        Assert-NotContains $run.Output '--delete' 'remote delete command'
    }

    Invoke-Case 'gate: a child process under -File exits 1 for a bad tag and 0 for a good one, appending to its own GITHUB_OUTPUT' {
        $powershell = (Get-Process -Id $PID).Path
        $outFile = Join-Path (New-TempDir) 'github_output'
        Write-TextFile $outFile "seed=1`n"
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $TagGatePath -Tag 'V1.9.0' *> $null
            Assert-Equal 1 $LASTEXITCODE 'exit code for V1.9.0'
            Assert-Equal "seed=1`n" ([IO.File]::ReadAllText($outFile, $Utf8NoBom)) 'GITHUB_OUTPUT after a rejected tag'
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $TagGatePath -Tag 'v1.9.0' *> $null
            Assert-Equal 0 $LASTEXITCODE 'exit code for v1.9.0'
        }
        Assert-Equal "seed=1`nversion=1.9.0`ntag=v1.9.0`n" ([IO.File]::ReadAllText($outFile, $Utf8NoBom)) 'GITHUB_OUTPUT after a valid tag'
    }

    # ============================================================================================
    #  Digest and manifest
    # ============================================================================================
    Invoke-Case 'digest: sha256sum -c format, lower-case hash, two spaces, LF' {
        $zip = Join-Path (New-TempDir) 'teststand-mcp.zip'
        [IO.File]::WriteAllBytes($zip, [byte[]](1, 2, 3, 4))
        $expected = (Get-Sha256Of ([byte[]](1, 2, 3, 4))) + '  teststand-mcp.zip' + "`n"
        Assert-Equal $expected (New-ArchiveDigest -ArchivePath $zip) 'digest text'
        Assert-Equal (Get-Sha256Of ([byte[]](1, 2, 3, 4))) (Get-FileSha256 $zip) 'Get-FileSha256 is lower-case'
    }

    Invoke-Case 'digest: a missing archive is a three-part failure naming the path' {
        $absent = Join-Path (New-TempDir) 'absent.zip'
        $message = $null
        try { [void](New-ArchiveDigest -ArchivePath $absent) } catch { $message = $_.Exception.Message }
        Assert-True ($null -ne $message) 'expected a failure'
        Assert-ThreePartFailure $message
        Assert-Contains $message 'absent.zip' 'path'
    }

    Invoke-Case 'manifest: sorted, forward slashes, one "<hash>  <path>" line per file of the staged tree' {
        $staged = New-StagedTree
        $lines = @((New-ArchiveManifest -StagedDir $staged) -split "`n" | Where-Object { $_ })
        Assert-Equal 5 $lines.Count 'one line per file'
        $parsed = ConvertFrom-HashLines ($lines -join "`n")
        Assert-Equal '.claude-plugin/plugin.json|VERSION.txt|bin/TestStandMCP.exe|bin/appsettings.json|bin/scripts/with space.txt' (@($parsed.Keys) -join '|') 'ordinal path order'
        Assert-Equal (Format-HashLine -Hash (Get-Sha256Of ([byte[]](0, 1, 2, 253, 254, 255, 0, 77))) -Path 'bin/TestStandMCP.exe') ($lines | Where-Object { $_.EndsWith('  bin/TestStandMCP.exe') }) 'hash line of the exe'
    }

    Invoke-Case 'manifest: round trip - a zip of the tree compares clean' {
        $staged = New-StagedTree
        $zip = Join-Path (New-TempDir) 'archive.zip'
        New-ZipFromDirectory $staged $zip
        $problems = @(Compare-ArchiveManifest -ArchivePath $zip -ManifestText (New-ArchiveManifest -StagedDir $staged))
        Assert-Equal 0 $problems.Count "problems: $(($problems | ForEach-Object { $_.Kind + ' ' + $_.Path }) -join '; ')"
    }

    Invoke-Case 'manifest: a changed file, an extra archive entry and a missing archive entry are each named' {
        $staged = New-StagedTree
        $zip = Join-Path (New-TempDir) 'archive.zip'
        New-ZipFromDirectory $staged $zip
        $lines = @((New-ArchiveManifest -StagedDir $staged) -split "`n" | Where-Object { $_ })
        $edited = @($lines | Where-Object { -not $_.EndsWith('  VERSION.txt') })
        $edited = @($edited | ForEach-Object { if ($_.EndsWith('  bin/appsettings.json')) { Format-HashLine -Hash $ZeroHash -Path 'bin/appsettings.json' } else { $_ } })
        $edited += (Format-HashLine -Hash (Get-Sha256Of ([byte[]](9))) -Path 'bin/ghost.dll')
        $problems = @(Compare-ArchiveManifest -ArchivePath $zip -ManifestText (($edited -join "`n") + "`n"))
        $byKind = @{}
        foreach ($problem in $problems) { $byKind[$problem.Kind] = $problem.Path }
        Assert-Equal 3 $problems.Count 'problem count'
        Assert-Equal 'bin/appsettings.json' $byKind['hash-mismatch'] 'hash mismatch path'
        Assert-Equal 'VERSION.txt' $byKind['entry-not-in-manifest'] 'extra archive entry path'
        Assert-Equal 'bin/ghost.dll' $byKind['entry-missing-from-archive'] 'missing archive entry path'
    }

    Invoke-Case 'manifest: an entry named with a backslash is an unsafe-name problem on every PowerShell version' {
        $zip = Join-Path (New-TempDir) 'backslash.zip'
        New-ZipFromEntries -ZipPath $zip -Entries @(@{ Name = 'bin\x.txt'; Bytes = [byte[]](1) }, @{ Name = 'ok.txt'; Bytes = [byte[]](2) })
        $problems = @(Compare-ArchiveManifest -ArchivePath $zip -ManifestText (Format-HashLine -Hash (Get-Sha256Of ([byte[]](2))) -Path 'ok.txt'))
        Assert-Equal 1 $problems.Count "problems: $(($problems | ForEach-Object { $_.Kind + ' ' + $_.Path }) -join '; ')"
        Assert-Equal 'archive-entry-unsafe' $problems[0].Kind 'kind'
        Assert-Contains $problems[0].Detail 'backslash' 'detail'
    }

    Invoke-Case 'manifest: ".." segments, absolute paths and drive letters are unsafe entry names' {
        $zip = Join-Path (New-TempDir) 'unsafe.zip'
        New-ZipFromEntries -ZipPath $zip -Entries @(
            @{ Name = '../evil.txt'; Bytes = [byte[]](1) }, @{ Name = 'a/../../evil.txt'; Bytes = [byte[]](1) },
            @{ Name = '/abs.txt'; Bytes = [byte[]](1) }, @{ Name = 'C:evil.txt'; Bytes = [byte[]](1) }, @{ Name = 'ok.txt'; Bytes = [byte[]](2) })
        $problems = @(Compare-ArchiveManifest -ArchivePath $zip -ManifestText (Format-HashLine -Hash (Get-Sha256Of ([byte[]](2))) -Path 'ok.txt'))
        Assert-Equal 4 @($problems | Where-Object { $_.Kind -eq 'archive-entry-unsafe' }).Count 'unsafe entries'
        Assert-Equal 4 $problems.Count 'nothing else is reported for them'
    }

    Invoke-Case 'manifest: a duplicate entry and a case-colliding entry are their own problems' {
        $zip = Join-Path (New-TempDir) 'dup.zip'
        New-ZipFromEntries -ZipPath $zip -Entries @(@{ Name = 'a.txt'; Bytes = [byte[]](1) }, @{ Name = 'a.txt'; Bytes = [byte[]](2) }, @{ Name = 'A.txt'; Bytes = [byte[]](3) })
        $manifest = Format-HashLine -Hash (Get-Sha256Of ([byte[]](1))) -Path 'a.txt'
        $kinds = @(@(Compare-ArchiveManifest -ArchivePath $zip -ManifestText $manifest) | ForEach-Object { $_.Kind })
        Assert-True ($kinds -ccontains 'archive-entry-duplicate') "no duplicate problem in: $($kinds -join ',')"
        Assert-True ($kinds -ccontains 'archive-entry-case-collision') "no case-collision problem in: $($kinds -join ',')"
    }

    Invoke-Case 'manifest: asset and entry names are compared case-sensitively' {
        $zip = Join-Path (New-TempDir) 'case.zip'
        New-ZipFromEntries -ZipPath $zip -Entries @(@{ Name = 'File.txt'; Bytes = [byte[]](1) })
        $problems = @(Compare-ArchiveManifest -ArchivePath $zip -ManifestText (Format-HashLine -Hash (Get-Sha256Of ([byte[]](1))) -Path 'file.txt'))
        $kinds = @($problems | ForEach-Object { $_.Kind } | Sort-Object)
        Assert-Equal 'entry-missing-from-archive,entry-not-in-manifest' ($kinds -join ',') 'kinds'
    }

    Invoke-Case 'manifest: a malformed line, an empty manifest, a repeated path and an unreadable archive are reported, not skipped' {
        $zip = Join-Path (New-TempDir) 'archive.zip'
        New-ZipFromDirectory (New-StagedTree) $zip
        $line = Format-HashLine -Hash $ZeroHash -Path 'a.txt'
        foreach ($text in @("not a hash line`n", '', "$line`n$line`n")) {
            $problems = @(Compare-ArchiveManifest -ArchivePath $zip -ManifestText $text)
            Assert-True ($problems.Count -eq 1 -and $problems[0].Kind -eq 'manifest-malformed') "expected one manifest-malformed for [$text], got: $(($problems | ForEach-Object { $_.Kind }) -join ',')"
        }
        $garbage = Join-Path (New-TempDir) 'garbage.zip'
        [IO.File]::WriteAllBytes($garbage, [byte[]](80, 75, 3, 4, 1, 2, 3))
        $problems = @(Compare-ArchiveManifest -ArchivePath $garbage -ManifestText "$line`n")
        Assert-True ($problems.Count -eq 1 -and $problems[0].Kind -eq 'archive-unreadable') "expected archive-unreadable, got: $(($problems | ForEach-Object { $_.Kind }) -join ',')"
    }

    Invoke-Case 'manifest: an empty staged tree is refused with a three-part failure' {
        $empty = Join-Path (New-TempDir) 'empty'
        [void](New-Item -ItemType Directory -Path $empty)
        $message = $null
        try { [void](New-ArchiveManifest -StagedDir $empty) } catch { $message = $_.Exception.Message }
        Assert-True ($null -ne $message) 'expected a failure'
        Assert-ThreePartFailure $message
    }

    Invoke-Case 'fault catalog: every archive problem kind has a fault entry, and an unknown code throws' {
        $codes = @(Get-ReleaseFaultCodes)
        foreach ($kind in $ArchiveProblemKinds) { Assert-True ($codes -ccontains $kind) "no fault entry for the archive problem kind '$kind'" }
        $thrown = $false
        try { [void](New-Problem -Code 'no-such-code') } catch { $thrown = $true }
        Assert-True $thrown 'New-Problem accepted an unknown code'
    }

    # ============================================================================================
    #  Own-downloads record
    # ============================================================================================
    Invoke-Case 'own-downloads: counts land in the draft or published cell of the right date and asset' {
        $path = Join-Path (New-TempDir) 'own-downloads.json'
        $common = @{ Path = $path; RunId = '77' }
        Add-OwnDownload @common -Asset 'teststand-mcp.zip' -Phase draft -Date '2026-08-20'
        Add-OwnDownload @common -Asset 'teststand-mcp.zip' -Phase draft -Date '2026-08-20'
        Add-OwnDownload @common -Asset 'teststand-mcp.zip' -Phase published -Date '2026-08-20'
        Add-OwnDownload @common -Asset 'teststand-mcp.sha256' -Phase draft -Date '2026-08-20'
        $record = Read-OwnDownloads -Path $path
        Assert-Equal '77' $record.RunId 'run id'
        Assert-Equal 2 $record.Counts['2026-08-20']['teststand-mcp.zip']['draft'] 'zip draft'
        Assert-Equal 1 $record.Counts['2026-08-20']['teststand-mcp.zip']['published'] 'zip published'
        Assert-Equal 1 $record.Counts['2026-08-20']['teststand-mcp.sha256']['draft'] 'digest draft'
        Assert-Equal 0 $record.Counts['2026-08-20']['teststand-mcp.sha256']['published'] 'digest published'
    }

    Invoke-Case 'own-downloads: a run that crosses midnight records each download under its own date' {
        $path = Join-Path (New-TempDir) 'own-downloads.json'
        Add-OwnDownload -Path $path -RunId '77' -Asset 'teststand-mcp.zip' -Phase draft -Date '2026-08-20'
        Add-OwnDownload -Path $path -RunId '77' -Asset 'teststand-mcp.zip' -Phase published -Date '2026-08-21'
        $record = Read-OwnDownloads -Path $path
        Assert-Equal '2026-08-20,2026-08-21' (@($record.Counts.Keys) -join ',') 'dates'
        Assert-Equal 1 $record.Counts['2026-08-20']['teststand-mcp.zip']['draft'] 'day one'
        Assert-Equal 0 $record.Counts['2026-08-20']['teststand-mcp.zip']['published'] 'day one published'
        Assert-Equal 1 $record.Counts['2026-08-21']['teststand-mcp.zip']['published'] 'day two'
    }

    Invoke-Case 'own-downloads: the file has exactly run_id and counts, no BOM, integer cells, and no temp file is left behind' {
        $dir = New-TempDir
        $path = Join-Path $dir 'own-downloads.json'
        1..5 | ForEach-Object { Add-OwnDownload -Path $path -RunId '77' -Asset 'teststand-mcp.zip' -Phase draft -Date '2026-01-02' }
        $json = [IO.File]::ReadAllText($path, $Utf8NoBom) | ConvertFrom-Json
        Assert-Equal 'counts,run_id' ((@($json.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ',') 'keys'
        Assert-True ($json.run_id -is [string]) 'run_id must be a string'
        $cell = $json.counts.'2026-01-02'.'teststand-mcp.zip'
        Assert-Equal 'draft,published' ((@($cell.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ',') 'cell keys'
        Assert-Equal 5 $cell.draft 'draft count'
        Assert-Equal 0 $cell.published 'published count'
        Assert-NoBom $path
        Assert-Equal 'own-downloads.json' ((Get-ChildItem -LiteralPath $dir -Force | ForEach-Object { $_.Name }) -join ',') 'files in the directory (atomic write leaves no temp file)'
    }

    Invoke-Case 'own-downloads: the shared fixture parses and has the documented shape' {
        $record = Read-OwnDownloads -Path $OwnDownloadsFixturePath
        Assert-Equal $FixtureRunId $record.RunId 'run id'
        Assert-Equal "$FixtureVerifyDate,$FixtureLatestDate" (@($record.Counts.Keys) -join ',') 'dates'
    }

    Invoke-Case 'own-downloads: a record of another run is refused instead of being merged' {
        $path = Join-Path (New-TempDir) 'own-downloads.json'
        Add-OwnDownload -Path $path -RunId '1' -Asset 'teststand-mcp.zip' -Phase draft
        $message = $null
        try { Add-OwnDownload -Path $path -RunId '2' -Asset 'teststand-mcp.zip' -Phase draft } catch { $message = $_.Exception.Message }
        Assert-True ($null -ne $message) 'expected a failure'
        Assert-ThreePartFailure $message
    }

    Invoke-Case 'own-downloads: without a run id (parameter or GITHUB_RUN_ID) or with a bad date the call fails' {
        $path = Join-Path (New-TempDir) 'o.json'
        foreach ($call in @(
            { Add-OwnDownload -Path $path -Asset 'teststand-mcp.zip' -Phase draft }
            { Add-OwnDownload -Path $path -RunId '1' -Asset 'teststand-mcp.zip' -Phase draft -Date '2026-13-40' }
            { Add-OwnDownload -Path $path -RunId '1' -Asset 'teststand-mcp.zip' -Phase draft -Date '20.08.2026' }
        )) {
            $message = $null
            try { & $call } catch { $message = $_.Exception.Message }
            Assert-True ($null -ne $message) 'expected a failure'
            Assert-ThreePartFailure $message
        }
        Assert-True (-not (Test-Path -LiteralPath $path)) 'a failed call must not create the file'
    }

    Invoke-Case 'own-downloads: the run id defaults to GITHUB_RUN_ID and the date to today (UTC, invariant format)' {
        $path = Join-Path (New-TempDir) 'o.json'
        $before = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        Use-EnvironmentVariable 'GITHUB_RUN_ID' '4242' { Add-OwnDownload -Path $path -Asset 'teststand-mcp.zip' -Phase published }
        $after = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $record = Read-OwnDownloads -Path $path
        Assert-Equal '4242' $record.RunId 'run id'
        $date = @($record.Counts.Keys)[0]
        Assert-True (($date -ceq $before) -or ($date -ceq $after)) "date $date is not today"
    }

    Invoke-Case 'own-downloads: a missing, non-JSON or malformed record is a three-part failure naming the file' {
        $dir = New-TempDir
        $files = @{
            'absent.json'    = $null
            'notjson.json'   = '{ nope'
            'norun.json'     = '{"counts":{}}'
            'nocounts.json'  = '{"run_id":"1"}'
            'baddate.json'   = '{"run_id":"1","counts":{"20.08.2026":{}}}'
            'nophase.json'   = '{"run_id":"1","counts":{"2026-08-20":{"a":{"draft":1}}}}'
            'negative.json'  = '{"run_id":"1","counts":{"2026-08-20":{"a":{"draft":-1,"published":0}}}}'
            'flag.json'      = '{"run_id":"1","counts":{"2026-08-20":{"a":{"draft":true,"published":0}}}}'
        }
        foreach ($name in $files.Keys) {
            $path = Join-Path $dir $name
            if ($null -ne $files[$name]) { Write-TextFile $path $files[$name] }
            $message = $null
            try { [void](Read-OwnDownloads -Path $path) } catch { $message = $_.Exception.Message }
            Assert-True ($null -ne $message) "$name : expected a failure"
            Assert-ThreePartFailure $message
            Assert-Contains $message $name "$name : file name"
        }
    }

    # ============================================================================================
    #  Verifier: local mode
    # ============================================================================================
    Invoke-Case 'verify local: four assets, bot uploader, matching digest and manifest -> exit 0' {
        $run = Invoke-LocalVerify (New-ReleaseFixture)
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Contains $run.Output 'verified' 'success line'
        Assert-Contains $run.Output 'Requested 0 asset download(s)' 'local mode downloads nothing and says so'
    }

    Invoke-Case 'verify local: without a release json the uploader check is skipped and the output says so' {
        $run = Invoke-LocalVerify (New-ReleaseFixture) -NoReleaseJson
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Contains $run.Output 'uploader check skipped' 'skip notice'
    }

    Invoke-Case 'verify local: -Version without a tag (the packaging step has no tag) verifies the staged assets' {
        $fixture = New-ReleaseFixture
        $run = Invoke-Script $VerifierPath @{ LocalDir = $fixture.Dir; Version = '1.9.0' }
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Contains $run.Output 'staged assets of version 1.9.0' 'subject'
    }

    Invoke-Case 'verify local: a bad -Version, a tag/version disagreement and -ReleaseJson without -Tag are three-part failures' {
        $fixture = New-ReleaseFixture
        foreach ($arguments in @(
            @{ LocalDir = $fixture.Dir; Version = '1.9' }
            @{ LocalDir = $fixture.Dir; Version = 'v1.9.0' }
            @{ LocalDir = $fixture.Dir; Tag = 'v1.9.0'; Version = '2.0.0' }
            @{ LocalDir = $fixture.Dir; Version = '1.9.0'; ReleaseJson = (Join-Path $fixture.Dir 'x.json') }
            @{ LocalDir = $fixture.Dir }
        )) {
            $run = Invoke-Script $VerifierPath $arguments
            Assert-Equal 1 $run.ExitCode "exit code for $(($arguments.Keys | ForEach-Object { "$_=$($arguments[$_])" }) -join ' ')"
        }
    }

    Invoke-Case 'verify local: the rehearsal tag is accepted with -Rehearsal (version is the plain X.Y.Z) and rejected without it' {
        $fixture = New-ReleaseFixture
        $run = Invoke-Script $VerifierPath @{ LocalDir = $fixture.Dir; Tag = 'v1.9.0-rehearsal'; Rehearsal = $true }
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        $run = Invoke-Script $VerifierPath @{ LocalDir = $fixture.Dir; Tag = 'v1.9.0-rehearsal' }
        Assert-Equal 1 $run.ExitCode 'exit code without -Rehearsal'
        Assert-Contains $run.Output 'rejected: suffix' 'tag verdict'
    }

    Invoke-Case 'verify: an invalid tag fails with the tag rejection text (the rule lives once)' {
        $fixture = New-ReleaseFixture
        $run = Invoke-Script $VerifierPath @{ LocalDir = $fixture.Dir; Tag = 'V1.9.0' }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'rejected: upper-case V' 'verdict'
        Assert-Contains $run.Output 'git tag -d -- V1.9.0' 'retag command'
    }

    # --- Scenario Outline: A release that must not go live --------------------------------------
    $FaultRows = @(
        @{ Fault = 'the zip was uploaded by a person'; Uploader = @{ 'teststand-mcp.zip' = 'alice' }
           Expect = @("the plugin archive teststand-mcp.zip was uploaded by 'alice', not by github-actions[bot]") }
        @{ Fault = "the zip's hash differs from the digest"
           Mutate = { param($fx) Set-ZeroDigest $fx }
           Expect = @('the plugin archive teststand-mcp.zip does not match the archive digest teststand-mcp.sha256') }
        @{ Fault = 'one manifest entry differs from the archive'
           Mutate = { param($fx) Edit-ManifestLines $fx { param($lines) $lines | ForEach-Object { if ($_.EndsWith('  bin/appsettings.json')) { Format-HashLine -Hash $ZeroHash -Path 'bin/appsettings.json' } else { $_ } } } }
           Expect = @("archive entry 'bin/appsettings.json' differs from the manifest") }
        @{ Fault = 'the archive has an entry the manifest lacks'
           Mutate = { param($fx) Edit-ManifestLines $fx { param($lines) $lines | Where-Object { -not $_.EndsWith('  VERSION.txt') } } }
           Expect = @("archive entry 'VERSION.txt' is not listed in the manifest") }
        @{ Fault = 'the manifest lists an entry the archive lacks'
           Mutate = { param($fx) Edit-ManifestLines $fx { param($lines) $lines + (Format-HashLine -Hash (Get-Sha256Of ([byte[]](9))) -Path 'bin/ghost.dll') } }
           Expect = @("the manifest lists 'bin/ghost.dll' but the archive has no such entry") }
        @{ Fault = 'the version-named copy differs from the fixed zip'
           Mutate = { param($fx)
               $path = Join-Path $fx.Dir 'teststand-mcp-v1.9.0.zip'
               $bytes = [IO.File]::ReadAllBytes($path)
               $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 0xFF
               [IO.File]::WriteAllBytes($path, $bytes) }
           Expect = @('the versioned archive teststand-mcp-v1.9.0.zip differs from the plugin archive teststand-mcp.zip') }
        @{ Fault = 'teststand-mcp.zip is missing'
           Mutate = { param($fx) Remove-Item -LiteralPath (Join-Path $fx.Dir 'teststand-mcp.zip') }
           Expect = @('the plugin archive teststand-mcp.zip is missing from the release') }
        @{ Fault = 'teststand-mcp.sha256 is missing'
           Mutate = { param($fx) Remove-Item -LiteralPath (Join-Path $fx.Dir 'teststand-mcp.sha256') }
           Expect = @('the archive digest teststand-mcp.sha256 is missing from the release') }
        @{ Fault = 'teststand-mcp.manifest.sha256 is missing'
           Mutate = { param($fx) Remove-Item -LiteralPath (Join-Path $fx.Dir 'teststand-mcp.manifest.sha256') }
           Expect = @('the archive manifest teststand-mcp.manifest.sha256 is missing from the release') }
        @{ Fault = 'the version-named copy is missing'
           Mutate = { param($fx) Remove-Item -LiteralPath (Join-Path $fx.Dir 'teststand-mcp-v1.9.0.zip') }
           Expect = @('the versioned archive teststand-mcp-v1.9.0.zip is missing from the release') }
    )
    foreach ($row in $FaultRows) {
        Invoke-Case "verify local fault: $($row.Fault) -> exit 1, names the fault, says running it again will not help, gives a local fix" {
            $fixture = New-ReleaseFixture
            if ($row.ContainsKey('Mutate')) { & $row.Mutate $fixture }
            $uploaders = @{}
            if ($row.ContainsKey('Uploader')) { $uploaders = $row.Uploader }
            $run = Invoke-LocalVerify $fixture -UploaderByAsset $uploaders
            Assert-Equal 1 $run.ExitCode 'exit code'
            foreach ($phrase in $row.Expect) { Assert-Contains $run.Output $phrase 'fault text' }
            Assert-Contains $run.Output $NeverHelps 'run-again advice'
            Assert-Contains $run.Output 'Run the packaging script again' 'local fix'
            Assert-NotContains $run.Output 'draft' 'a local run never talks about a draft'
        }
    }

    Invoke-Case 'verify local fault: a missing plugin archive is reported alone, not as a cascade of dependent faults' {
        $fixture = New-ReleaseFixture
        Remove-Item -LiteralPath (Join-Path $fixture.Dir 'teststand-mcp.zip')
        $run = Invoke-LocalVerify $fixture
        Assert-NotContains $run.Output 'does not match' 'a hash comparison against a missing archive'
        Assert-NotContains $run.Output 'differs from' 'a comparison against a missing archive'
    }

    Invoke-Case 'verify local fault: two faults are both named in one failure' {
        $fixture = New-ReleaseFixture
        Remove-Item -LiteralPath (Join-Path $fixture.Dir 'teststand-mcp.sha256')
        Edit-ManifestLines $fixture { param($lines) $lines | Where-Object { -not $_.EndsWith('  VERSION.txt') } }
        $run = Invoke-LocalVerify $fixture
        Assert-Contains $run.Output 'the archive digest teststand-mcp.sha256 is missing from the release' 'first fault'
        Assert-Contains $run.Output "archive entry 'VERSION.txt' is not listed in the manifest" 'second fault'
    }

    Invoke-Case 'verify local fault: a versioned archive of another size is a listing fault' {
        $fixture = New-ReleaseFixture
        [IO.File]::WriteAllBytes((Join-Path $fixture.Dir 'teststand-mcp-v1.9.0.zip'), [byte[]](1, 2, 3))
        $run = Invoke-LocalVerify $fixture
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'the versioned archive teststand-mcp-v1.9.0.zip is 3 bytes but the plugin archive is' 'size fault'
    }

    Invoke-Case 'verify local fault: a digest that names another file, or is malformed, is its own fault' {
        $fixture = New-ReleaseFixture
        Write-TextFile (Join-Path $fixture.Dir 'teststand-mcp.sha256') ((Get-FileSha256 (Join-Path $fixture.Dir 'teststand-mcp.zip')) + "  other.zip`n")
        $run = Invoke-LocalVerify $fixture
        Assert-Equal 1 $run.ExitCode 'exit code for a digest naming another file'
        Assert-Contains $run.Output "the archive digest names 'other.zip'" 'digest name fault'
        Write-TextFile (Join-Path $fixture.Dir 'teststand-mcp.sha256') "garbage`n"
        $run = Invoke-LocalVerify $fixture
        Assert-Equal 1 $run.ExitCode 'exit code for a malformed digest'
        Assert-Contains $run.Output 'the archive digest is malformed' 'malformed digest fault'
    }

    Invoke-Case 'verify local fault: a malformed, empty or repeating manifest is a manifest fault' {
        $fixture = New-ReleaseFixture
        foreach ($text in @("garbage`n", "`n")) {
            Write-TextFile (Join-Path $fixture.Dir 'teststand-mcp.manifest.sha256') $text
            $run = Invoke-LocalVerify $fixture
            Assert-Equal 1 $run.ExitCode "exit code for [$text]"
            Assert-Contains $run.Output 'the archive manifest is malformed' "fault for [$text]"
        }
        $fixture = New-ReleaseFixture
        Edit-ManifestLines $fixture { param($lines) $lines + $lines[0] }
        $run = Invoke-LocalVerify $fixture
        Assert-Contains $run.Output 'repeats the path' 'duplicate manifest path'
    }

    Invoke-Case 'verify local fault: more than five differences are cut off with a count' {
        $fixture = New-ReleaseFixture
        Edit-ManifestLines $fixture { param($lines)
            $zeroed = @($lines | ForEach-Object { Format-HashLine -Hash $ZeroHash -Path $_.Substring($_.IndexOf('  ') + 2) })
            $zeroed + (Format-HashLine -Hash $ZeroHash -Path 'ghost-a.dll') + (Format-HashLine -Hash $ZeroHash -Path 'ghost-b.dll') }
        $run = Invoke-LocalVerify $fixture
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output '... and 2 more differences' 'cut-off note'
    }

    Invoke-Case 'verify local fault: a corrupt plugin archive is its own fault, not an unexpected error' {
        $fixture = New-ReleaseFixture -CorruptZip
        $run = Invoke-LocalVerify $fixture
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'the plugin archive cannot be read as a zip file' 'fault'
        Assert-NotContains $run.Output 'Unexpected error' 'unexpected-error wrapper'
    }

    Invoke-Case 'verify local fault: duplicate, case-colliding and unsafe archive entries are reported by name' {
        $fixture = New-ReleaseFixture -ExtraEntries @(
            @{ Name = 'VERSION.txt'; Bytes = [byte[]](9) }, @{ Name = 'version.TXT'; Bytes = [byte[]](9) },
            @{ Name = '../evil.txt'; Bytes = [byte[]](9) }, @{ Name = 'bin\x.txt'; Bytes = [byte[]](9) })
        $run = Invoke-LocalVerify $fixture
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output "the archive holds the entry 'VERSION.txt' more than once" 'duplicate'
        Assert-Contains $run.Output "archive entry 'version.TXT' collides in case" 'case collision'
        Assert-Contains $run.Output "archive entry '../evil.txt' has an unsafe name" 'dot-dot'
        Assert-Contains $run.Output "archive entry 'bin\x.txt' has an unsafe name" 'backslash'
    }

    Invoke-Case 'verify local fault: a hand-attached extra asset fails the uploader check, an unknown uploader does too' {
        $fixture = New-ReleaseFixture
        Write-TextFile (Join-Path $fixture.Dir 'notes.txt') 'extra'
        $names = @(Get-RequiredAssetNames -Version $fixture.Version) + 'notes.txt'
        $run = Invoke-LocalVerify $fixture -ListedNames $names -UploaderByAsset @{ 'notes.txt' = 'alice' }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output "the asset notes.txt was uploaded by 'alice'" 'extra asset fault'
        $run = Invoke-LocalVerify $fixture -ListedNames @(Get-RequiredAssetNames -Version $fixture.Version)
        Assert-Contains $run.Output "the asset notes.txt was uploaded by '(unknown)'" 'asset absent from the release metadata'
    }

    Invoke-Case 'verify local fault: an asset name that differs only in case is missing, not matched' {
        $fixture = New-ReleaseFixture
        Rename-Item -LiteralPath (Join-Path $fixture.Dir 'teststand-mcp.sha256') -NewName 'Teststand-mcp.sha256'
        $run = Invoke-LocalVerify $fixture
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'the archive digest teststand-mcp.sha256 is missing from the release' 'fault'
    }

    Invoke-Case 'verify local: a missing or foreign -ReleaseJson is a three-part failure' {
        $fixture = New-ReleaseFixture
        $run = Invoke-Script $VerifierPath @{ Tag = $fixture.Tag; LocalDir = $fixture.Dir; ReleaseJson = (Join-Path (New-TempDir) 'absent.json') }
        Assert-Equal 1 $run.ExitCode 'exit code for a missing file'
        Assert-Contains $run.Output 'absent.json' 'file name'
        $jsonPath = Join-Path (New-TempDir) 'other.json'
        Write-TextFile $jsonPath (New-ReleaseJsonText -Tag 'v9.9.9' -AssetNames @('x'))
        $run = Invoke-Script $VerifierPath @{ Tag = $fixture.Tag; LocalDir = $fixture.Dir; ReleaseJson = $jsonPath }
        Assert-Equal 1 $run.ExitCode 'exit code for a release that is not in the file'
        Assert-Contains $run.Output 'has 0 releases tagged v1.9.0' 'reason'
    }

    Invoke-Case 'verify local: a release json that is not JSON still gives a three-part failure naming the error' {
        $fixture = New-ReleaseFixture
        $jsonPath = Join-Path (New-TempDir) 'broken.json'
        Write-TextFile $jsonPath '{ this is not json'
        $run = Invoke-Script $VerifierPath @{ Tag = $fixture.Tag; LocalDir = $fixture.Dir; ReleaseJson = $jsonPath }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'Unexpected error' 'unexpected-error label'
    }

    Invoke-Case 'verify: a missing LocalDir, no source, two sources and a bad -Repo are three-part failures' {
        foreach ($arguments in @(
            @{ Tag = 'v1.9.0'; LocalDir = (Join-Path (New-TempDir) 'nope') }
            @{ Tag = 'v1.9.0' }
            @{ Tag = 'v1.9.0'; LocalDir = (New-TempDir); Repo = $ExpectedRepoSlug }
            @{ Latest = $true; Repo = $ExpectedRepoSlug }
            @{ Tag = 'v1.9.0'; Repo = 'not a repo' }
            @{ Tag = 'v1.9.0'; Repo = '../x' }
            @{ Tag = 'v1.9.0'; Repo = 'owner/..' }
            @{ Tag = 'v1.9.0'; Repo = 'a/b/c' }
            @{ Repo = $ExpectedRepoSlug }
        )) {
            $run = Invoke-Script $VerifierPath $arguments
            Assert-Equal 1 $run.ExitCode "exit code for $(($arguments.Keys | ForEach-Object { "$_=$($arguments[$_])" }) -join ' ')"
        }
    }

    Invoke-Case 'verify: a child process under -File exits 1 for a faulty release and 0 for a good one' {
        $powershell = (Get-Process -Id $PID).Path
        $good = New-ReleaseFixture
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $VerifierPath -Tag $good.Tag -LocalDir $good.Dir *> $null
        Assert-Equal 0 $LASTEXITCODE 'exit code for a good release'
        Remove-Item -LiteralPath (Join-Path $good.Dir 'teststand-mcp.sha256')
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $VerifierPath -Tag $good.Tag -LocalDir $good.Dir *> $null
        Assert-Equal 1 $LASTEXITCODE 'exit code for a faulty release'
    }

    # ============================================================================================
    #  Verifier: API mode through a fake HTTP boundary
    # ============================================================================================
    Invoke-Case 'verify api: reads the draft with the token, downloads four assets, exit 0, writes release_id and asset_ids' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture
        $outFile = Join-Path (New-TempDir) 'github_output'
        Write-TextFile $outFile "seed=1`n"
        $run = $null
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile { $script:ApiRun = Invoke-ApiVerify $fixture $api }
        $run = $script:ApiRun
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Contains $run.Output 'Requested 4 asset download(s) in 1 attempt' 'download count'
        $listing = @($api.State.Calls | Where-Object { $_.Uri -match '/releases\?' })[0]
        Assert-True ($listing.Uri.StartsWith('https://api.github.com/repos/Zuehlke/teststand-mcp/releases?')) "listing url was $($listing.Uri)"
        Assert-Equal "Bearer $FakeToken" $listing.Headers['Authorization'] 'listing authorization'
        Assert-True ($listing.TimeoutSeconds -gt 0) 'the listing call carries a timeout'
        $requests = Get-AssetRequests $api
        Assert-Equal 4 $requests.Count 'asset requests'
        foreach ($request in $requests) {
            Assert-Equal 'application/octet-stream' $request.Headers['Accept'] "accept header of $($request.Uri)"
            Assert-Equal "Bearer $FakeToken" $request.Headers['Authorization'] "authorization of $($request.Uri)"
            Assert-True ($request.TimeoutSeconds -ge 120) 'every download carries at least the base timeout'
        }
        Assert-NotContains $run.Output $FakeToken 'output (the token must never be printed)'
        Assert-NoBom $outFile
        $lines = @([IO.File]::ReadAllText($outFile, $Utf8NoBom) -split "`n" | Where-Object { $_ })
        Assert-Equal 'seed=1' $lines[0] 'the existing line stays'
        Assert-Equal "release_id=$ReleaseId" $lines[1] 'release_id'
        $ids = ($lines[2].Substring('asset_ids='.Length)) | ConvertFrom-Json
        Assert-Equal 'teststand-mcp.zip,teststand-mcp.sha256,teststand-mcp.manifest.sha256,teststand-mcp-v1.9.0.zip' (@($ids.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'asset ids by name'
        Assert-Equal $FirstAssetId $ids.'teststand-mcp.zip' 'zip asset id'
    }

    Invoke-Case 'verify api: the timeout of a big asset follows its size (1 MB/s)' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -ReleaseOptions @{ SizeByAsset = @{ 'teststand-mcp.zip' = 900MB; 'teststand-mcp-v1.9.0.zip' = 900MB } }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        $zipRequest = @(Get-AssetRequests $api | Where-Object { $_.Uri.EndsWith("/$FirstAssetId") })[0]
        Assert-Equal 900 $zipRequest.TimeoutSeconds 'timeout of a 900 MB asset'
    }

    Invoke-Case 'verify api: without a token no Authorization header is sent; GITHUB_TOKEN is the fallback' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture
        $run = Invoke-ApiVerify $fixture $api -Extra @{ Token = '' }
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        foreach ($call in $api.State.Calls) { Assert-True (-not $call.Headers.ContainsKey('Authorization')) "Authorization sent to $($call.Uri)" }
        $fallbackApi = New-FakeApi $fixture
        Use-EnvironmentVariable 'GITHUB_TOKEN' 'ghs_FROM_ENVIRONMENT' {
            $script:FallbackRun = Invoke-ApiVerify $fixture $fallbackApi -OmitToken
        }
        Assert-Equal 0 $script:FallbackRun.ExitCode "exit code. Output was:`n$($script:FallbackRun.Output)"
        Assert-Equal 'Bearer ghs_FROM_ENVIRONMENT' $fallbackApi.State.Calls[0].Headers['Authorization'] 'fallback authorization'
        Assert-NotContains $script:FallbackRun.Output 'ghs_FROM_ENVIRONMENT' 'output'
    }

    Invoke-Case 'verify api: an asset uploaded by a person fails BEFORE anything is downloaded and is not retried' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -ReleaseOptions @{ UploaderByAsset = @{ 'teststand-mcp.zip' = 'alice' } }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output "the plugin archive teststand-mcp.zip was uploaded by 'alice'" 'fault'
        Assert-Contains $run.Output 'Start a new release run (delete the draft first)' 'api fix'
        Assert-Contains $run.Output 'Never attach assets by hand' 'extra advice'
        Assert-Equal 1 ([regex]::Matches($run.Output, 'Start a new release run').Count) 'the restart step is said once'
        Assert-Equal 0 (Get-AssetRequests $api).Count 'asset requests'
        Assert-Equal 0 $run.Delays.Count 'a retry delay was used for a non-download fault'
    }

    Invoke-Case 'verify api: a hand-attached extra asset and an unknown uploader fail before any download' {
        $fixture = New-ReleaseFixture
        $names = @(Get-RequiredAssetNames -Version $fixture.Version) + 'notes.txt'
        $api = New-FakeApi $fixture -ReleaseOptions @{ AssetNames = $names; UploaderByAsset = @{ 'notes.txt' = 'alice' }; NoUploaderFor = @('teststand-mcp.sha256') }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output "the asset notes.txt was uploaded by 'alice'" 'extra asset'
        Assert-Contains $run.Output "the archive digest teststand-mcp.sha256 was uploaded by '(unknown)'" 'unknown uploader'
        Assert-Equal 0 (Get-AssetRequests $api).Count 'asset requests'
    }

    Invoke-Case 'verify api: a versioned archive of another listed size is reported before any download' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -ReleaseOptions @{ SizeByAsset = @{ 'teststand-mcp.zip' = 1000; 'teststand-mcp-v1.9.0.zip' = 999 } }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'the versioned archive teststand-mcp-v1.9.0.zip is 999 bytes but the plugin archive is 1000 bytes' 'fault'
        Assert-Equal 0 (Get-AssetRequests $api).Count 'asset requests'
    }

    Invoke-Case 'verify api: an asset name that differs only in case is missing, and an unusable asset id fails before any download' {
        $fixture = New-ReleaseFixture
        $names = @('teststand-mcp.zip', 'Teststand-mcp.sha256', 'teststand-mcp.manifest.sha256', 'teststand-mcp-v1.9.0.zip')
        $run = Invoke-ApiVerify $fixture (New-FakeApi $fixture -ReleaseOptions @{ AssetNames = $names })
        Assert-Contains $run.Output 'the archive digest teststand-mcp.sha256 is missing from the release' 'case-only name'
        $badId = New-FakeApi $fixture -ReleaseOptions @{ IdByAsset = @{ 'teststand-mcp.sha256' = 'abc' } }
        $run = Invoke-ApiVerify $fixture $badId
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'unusable asset id' 'reason'
        Assert-Equal 0 (Get-AssetRequests $badId).Count 'asset requests'
    }

    Invoke-Case 'verify api: no release for the tag explains that a draft needs -Token, and is not retried' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -ReleaseOptions @{ Tag = 'v9.9.9' }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'v1.9.0' 'tag'
        Assert-Contains $run.Output '-Token' 'draft hint'
        Assert-Equal 0 (Get-AssetRequests $api).Count 'asset requests'
    }

    Invoke-Case 'verify api: the tag on the second page of the releases list is found' {
        $fixture = New-ReleaseFixture
        $real = New-ReleaseJsonText -Tag $fixture.Tag -AssetNames (Get-RequiredAssetNames -Version $fixture.Version) -SizeByAsset (Get-AssetSizes $fixture)
        $api = New-FakeApi $fixture -Pages @{ 1 = (New-FullPageJson); 2 = $real }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        $listings = @($api.State.Calls | Where-Object { $_.Uri -match '/releases\?' })
        Assert-Equal 2 $listings.Count 'listing requests'
        Assert-Contains $listings[1].Uri 'page=2' 'second page'
    }

    Invoke-Case 'verify api: when the search runs out of pages the failure says so' {
        $fixture = New-ReleaseFixture
        $pages = @{}
        foreach ($page in 1..$MaxListPages) { $pages[$page] = (New-FullPageJson) }
        $api = New-FakeApi $fixture -Pages $pages
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output "stopped after $MaxListPages pages" 'exhaustion note'
        Assert-Equal $MaxListPages @($api.State.Calls | Where-Object { $_.Uri -match '/releases\?' }).Count 'listing requests'
    }

    Invoke-Case 'verify api: two releases with the same tag fail, naming both ids, and nothing is downloaded' {
        $fixture = New-ReleaseFixture
        $names = @(Get-RequiredAssetNames -Version $fixture.Version)
        $first = @{ id = 701; tag_name = $fixture.Tag; draft = $true; assets = @() }
        $second = @{ id = 702; tag_name = $fixture.Tag; draft = $true; assets = @() }
        $api = New-FakeApi $fixture -Pages @{ 1 = (ConvertTo-Json -InputObject @($first, $second) -Depth 4) }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output '2 releases of Zuehlke/teststand-mcp carry the tag v1.9.0' 'fault'
        Assert-Contains $run.Output '701, 702' 'ids'
        Assert-Equal 0 (Get-AssetRequests $api).Count 'asset requests'
    }

    Invoke-Case 'verify api: the releases list failing is a three-part failure and is not retried' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -ReleasesFailure 'The remote server returned an error: (403) rate limit exceeded.'
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'rate limit' 'cause'
        Assert-Equal 0 $run.Delays.Count 'retry delays'
    }

    # --- Scenario Outline: One retry for upload settling --------------------------------------
    Invoke-Case 'retry: first attempt cannot download (HTTP error), second passes -> exit 0 after a 30 s wait, re-downloading only what failed' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.sha256' -and $Count -eq 1) { 'The remote server returned an error: (502) Bad Gateway.' } }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Equal 1 $run.Delays.Count 'number of waits'
        Assert-Equal $DefaultRetryDelay $run.Delays[0] 'wait in seconds'
        Assert-Contains $run.Output 'in 2 attempt' 'attempt count'
        Assert-Equal 1 $api.State.Downloads['teststand-mcp.zip'] 'the archive that already arrived is not downloaded again'
        Assert-Equal 2 $api.State.Downloads['teststand-mcp.sha256'] 'the failed asset is requested again'
        Assert-Equal 1 $api.State.Downloads['teststand-mcp.manifest.sha256'] 'manifest'
        Assert-Equal 1 $api.State.Downloads['teststand-mcp-v1.9.0.zip'] 'versioned archive'
    }

    Invoke-Case 'retry: first attempt cannot download (timeout), second fails again -> exit non-zero, says running it again may help' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.zip') { 'The operation has timed out.' } }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'timed out' 'cause'
        Assert-Contains $run.Output $MayHelp 'advice'
        Assert-Equal 1 $run.Delays.Count 'exactly one retry'
        Assert-Equal 2 $api.State.Downloads['teststand-mcp.zip'] 'archive request count (no third attempt)'
    }

    Invoke-Case 'retry: first attempt cannot download, second downloads but the hash differs -> exit non-zero naming the hash' {
        $fixture = New-ReleaseFixture
        Set-ZeroDigest $fixture
        $api = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.manifest.sha256' -and $Count -eq 1) { 'timeout' } }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'does not match the archive digest' 'fault'
        Assert-Equal 1 $run.Delays.Count 'exactly one retry'
    }

    Invoke-Case 'retry: downloads but the hash differs on the first attempt -> exit non-zero WITHOUT retrying' {
        $fixture = New-ReleaseFixture
        Set-ZeroDigest $fixture
        $api = New-FakeApi $fixture
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'does not match the archive digest' 'fault'
        Assert-Contains $run.Output $NeverHelps 'advice'
        Assert-Equal 0 $run.Delays.Count 'no wait'
        Assert-Equal 1 $api.State.Downloads['teststand-mcp.zip'] 'archive downloaded once'
    }

    Invoke-Case 'retry: a missing asset is not retried either' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -ReleaseOptions @{ AssetNames = @('teststand-mcp.zip', 'teststand-mcp.sha256', 'teststand-mcp-v1.9.0.zip') }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'the archive manifest teststand-mcp.manifest.sha256 is missing from the release' 'fault'
        Assert-Equal 0 $run.Delays.Count 'no wait'
    }

    # ============================================================================================
    #  Own-downloads record written by the verifier; the -Latest mode
    # ============================================================================================
    Invoke-Case 'own-downloads: verify (first archive download fails) + retry + the public latest download equal the shared fixture' {
        $fixture = New-ReleaseFixture
        $recordPath = Join-Path (New-TempDir) 'own-downloads.json'
        $verifyApi = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.zip' -and $Count -eq 1) { 'The remote server returned an error: (502) Bad Gateway.' } }
        $run = Invoke-ApiVerify $fixture $verifyApi -OwnDownloadsPath $recordPath -Extra @{ RunId = $FixtureRunId; Date = $FixtureVerifyDate }
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        $latest = Invoke-LatestVerify (New-FakeApi $fixture) -Extra @{ OwnDownloadsPath = $recordPath; RunId = $FixtureRunId; Date = $FixtureLatestDate }
        Assert-Equal 0 $latest.ExitCode "exit code. Output was:`n$($latest.Output)"
        $record = Read-OwnDownloads -Path $recordPath
        Assert-RecordMatchesFixture $record
        Assert-Equal 3 ($record.Counts[$FixtureVerifyDate]['teststand-mcp.zip']['draft'] + $record.Counts[$FixtureLatestDate]['teststand-mcp.zip']['published']) 'zip downloads in total'
    }

    Invoke-Case 'own-downloads: the phase comes from the release draft flag; -Draft only forces draft' {
        $fixture = New-ReleaseFixture
        $publishedJson = @{ IsDraft = $false }
        $recordPath = Join-Path (New-TempDir) 'published.json'
        [void](Invoke-ApiVerify $fixture (New-FakeApi $fixture -ReleaseOptions $publishedJson) -OwnDownloadsPath $recordPath -Extra @{ RunId = '55'; Date = '2026-08-20' })
        $cell = (Read-OwnDownloads -Path $recordPath).Counts['2026-08-20']['teststand-mcp.zip']
        Assert-Equal 1 $cell['published'] 'published cell of a published release'
        Assert-Equal 0 $cell['draft'] 'draft cell of a published release'
        $forcedPath = Join-Path (New-TempDir) 'forced.json'
        [void](Invoke-ApiVerify $fixture (New-FakeApi $fixture -ReleaseOptions $publishedJson) -OwnDownloadsPath $forcedPath -ForceDraft -Extra @{ RunId = '55'; Date = '2026-08-20' })
        Assert-Equal 1 (Read-OwnDownloads -Path $forcedPath).Counts['2026-08-20']['teststand-mcp.zip']['draft'] 'draft cell when forced'
        $draftPath = Join-Path (New-TempDir) 'draft.json'
        [void](Invoke-ApiVerify $fixture (New-FakeApi $fixture) -OwnDownloadsPath $draftPath -Extra @{ RunId = '55'; Date = '2026-08-20' })
        Assert-Equal 1 (Read-OwnDownloads -Path $draftPath).Counts['2026-08-20']['teststand-mcp.zip']['draft'] 'draft cell of a draft release'
    }

    Invoke-Case 'own-downloads: each download is recorded BEFORE its request, so a failed request still counts' {
        $fixture = New-ReleaseFixture
        $recordPath = Join-Path (New-TempDir) 'own-downloads.json'
        $api = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.zip') { 'down' } }
        [void](Invoke-ApiVerify $fixture $api -OwnDownloadsPath $recordPath -Extra @{ RunId = '55'; Date = '2026-08-20' })
        Assert-Equal 2 (Read-OwnDownloads -Path $recordPath).Counts['2026-08-20']['teststand-mcp.zip']['draft'] 'two failed requests'
    }

    Invoke-Case 'own-downloads: local mode records nothing' {
        $localRecord = Join-Path (New-TempDir) 'local-downloads.json'
        [void](Invoke-LocalVerify (New-ReleaseFixture) -Extra @{ OwnDownloadsPath = $localRecord })
        Assert-True (-not (Test-Path -LiteralPath $localRecord)) 'local mode must not create a download record'
    }

    Invoke-Case 'latest: the unauthenticated public download of the archive matches the published digest, recorded as published' {
        $fixture = New-ReleaseFixture
        $recordPath = Join-Path (New-TempDir) 'own-downloads.json'
        $api = New-FakeApi $fixture
        $run = $null
        Use-EnvironmentVariable 'GITHUB_TOKEN' 'ghs_MUST_NOT_BE_SENT' {
            $script:LatestRun = Invoke-LatestVerify $api -Extra @{ OwnDownloadsPath = $recordPath; RunId = '9'; Date = '2026-08-21' }
        }
        $run = $script:LatestRun
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Equal 'https://github.com/Zuehlke/teststand-mcp/releases/latest/download/teststand-mcp.zip' $api.State.Calls[0].Uri 'first url'
        Assert-Equal 'https://github.com/Zuehlke/teststand-mcp/releases/latest/download/teststand-mcp.sha256' $api.State.Calls[1].Uri 'second url'
        foreach ($call in $api.State.Calls) { Assert-True (-not $call.Headers.ContainsKey('Authorization')) "a credential was sent to $($call.Uri)" }
        $cells = (Read-OwnDownloads -Path $recordPath).Counts['2026-08-21']
        Assert-Equal 1 $cells['teststand-mcp.zip']['published'] 'zip published'
        Assert-Equal 0 $cells['teststand-mcp.zip']['draft'] 'zip draft'
        Assert-Equal 1 $cells['teststand-mcp.sha256']['published'] 'digest published'
    }

    Invoke-Case 'latest: an archive that does not match the published digest fails with the three parts' {
        $fixture = New-ReleaseFixture
        Set-ZeroDigest $fixture
        $run = Invoke-LatestVerify (New-FakeApi $fixture)
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'users download from releases/latest' 'fault'
        Assert-Contains $run.Output 'delete it so latest falls back' 'fix'
    }

    Invoke-Case 'latest: a download failure is retried once and a persistent one says running it again may help' {
        $fixture = New-ReleaseFixture
        $once = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.zip' -and $Count -eq 1) { 'timeout' } }
        $run = Invoke-LatestVerify $once
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Equal 1 $run.Delays.Count 'one wait'
        $always = New-FakeApi $fixture -Plan { param($Name, $Count) 'timeout' }
        $run = Invoke-LatestVerify $always
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output $MayHelp 'advice'
    }

    # ============================================================================================
    #  Slice 7 additions: fix wording by release.draft, the expected digest of -Latest, archive_sha256
    # ============================================================================================
    Invoke-Case 'fix wording: a published release with a fault never tells the maintainer to delete the draft first' {
        $fixture = New-ReleaseFixture
        $published = @{ IsDraft = $false; UploaderByAsset = @{ 'teststand-mcp.zip' = 'alice' } }
        $run = Invoke-ApiVerify $fixture (New-FakeApi $fixture -ReleaseOptions $published)
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-NotContains $run.Output 'delete the draft first' 'the fix of a published release'
        Assert-Contains $run.Output 'already published' 'the fix says the release is public'
        Assert-Contains $run.Output 'releases/latest falls back' 'the rollback advice'
        Assert-Contains $run.Output 'next patch version' 'the fix-forward advice'
    }

    Invoke-Case 'fix wording: a draft with a fault still says to delete the draft first' {
        $fixture = New-ReleaseFixture
        $draft = @{ IsDraft = $true; UploaderByAsset = @{ 'teststand-mcp.zip' = 'alice' } }
        $run = Invoke-ApiVerify $fixture (New-FakeApi $fixture -ReleaseOptions $draft)
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'delete the draft first' 'the fix of a draft'
        Assert-NotContains $run.Output 'already published' 'the fix of a draft'
    }

    Invoke-Case 'fix wording: a published release whose content is faulty is worded as published too' {
        $fixture = New-ReleaseFixture
        Set-ZeroDigest $fixture
        $run = Invoke-ApiVerify $fixture (New-FakeApi $fixture -ReleaseOptions @{ IsDraft = $false })
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'does not match the archive digest' 'the fault'
        Assert-NotContains $run.Output 'delete the draft first' 'the fix of a published release'
    }

    Invoke-Case 'fix wording: the public latest download is always a published release, so its restart fix never mentions a draft' {
        $fixture = New-ReleaseFixture
        Write-TextFile (Join-Path $fixture.Dir 'teststand-mcp.sha256') ($ZeroHash + "  other.zip`n")
        $run = Invoke-LatestVerify (New-FakeApi $fixture)
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'names ''other.zip''' 'the fault'
        Assert-NotContains $run.Output 'delete the draft first' 'the fix of the latest download'
        Assert-Contains $run.Output 'already published' 'the fix says the release is public'
    }

    Invoke-Case 'fix wording: Format-ReleaseFailure in local mode still never talks about a draft or a published release' {
        $failure = Format-ReleaseFailure -Subject 'x' -Problems @(New-Problem 'asset-missing' @('the plugin archive teststand-mcp.zip')) -Mode Local
        Assert-NotContains $failure.Fix 'draft' 'local fix'
        Assert-NotContains $failure.Fix 'published' 'local fix'
    }

    Invoke-Case 'api: the verified archive hash is written as the step output archive_sha256, after release_id and asset_ids' {
        $fixture = New-ReleaseFixture
        $outFile = Join-Path (New-TempDir) 'github_output'
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile { $script:HashRun = Invoke-ApiVerify $fixture (New-FakeApi $fixture) }
        Assert-Equal 0 $script:HashRun.ExitCode "exit code. Output was:`n$($script:HashRun.Output)"
        $lines = @([IO.File]::ReadAllText($outFile, $Utf8NoBom) -split "`n" | Where-Object { $_ })
        $expected = (Get-FileHash -LiteralPath (Join-Path $fixture.Dir 'teststand-mcp.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Equal "archive_sha256=$expected" $lines[2] 'archive_sha256 line'
    }

    Invoke-Case 'own-downloads: run_id is a JSON string even when the run id is all digits (the collector compares strings)' {
        $fixture = New-ReleaseFixture
        $recordPath = Join-Path (New-TempDir) 'own-downloads.json'
        [void](Invoke-ApiVerify $fixture (New-FakeApi $fixture) -OwnDownloadsPath $recordPath -Extra @{ RunId = '1234567890'; Date = '2026-08-20' })
        $text = [IO.File]::ReadAllText($recordPath, $Utf8NoBom)
        Assert-True ($text -cmatch '"run_id":\s*"1234567890"') "run_id is not written as a quoted string. File was:`n$text"
    }

    Invoke-Case 'fault catalog: a propagation fault may be retried, every other fault never helps' {
        $propagation = New-Problem 'latest-not-verified' @('aaa', 'bbb')
        Assert-True $propagation.Retryable 'latest-not-verified is retryable'
        $alone = Format-ReleaseFailure -Subject 'The latest release' -Problems @($propagation) -Mode ApiPublished
        Assert-Contains $alone.Why $MayHelp 'why of a lone propagation fault'
        Assert-NotContains $alone.Why $NeverHelps 'why of a lone propagation fault'
        $mixed = Format-ReleaseFailure -Subject 'x' -Problems @($propagation, (New-Problem 'digest-mismatch' @('a', 'b'))) -Mode ApiPublished
        Assert-Contains $mixed.Why $NeverHelps 'one non-retryable fault decides'
        foreach ($code in @(Get-ReleaseFaultCodes | Where-Object { $_ -cne 'latest-not-verified' })) {
            Assert-True (-not (New-Problem $code @('a', 'b', 'c')).Retryable) "$code must not be marked retryable"
        }
    }

    Invoke-Case 'latest: an expected digest equal to the served archive passes and says so' {
        $fixture = New-ReleaseFixture
        $expected = (Get-FileHash -LiteralPath (Join-Path $fixture.Dir 'teststand-mcp.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        $api = New-FakeApi $fixture
        $run = Invoke-LatestVerify $api -Extra @{ ExpectedArchiveSha256 = $expected }
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Equal 0 $run.Delays.Count 'no wait when the first attempt matches'
        Assert-Contains $run.Output 'verified release' 'the success line names the check against the verified release'
    }

    Invoke-Case 'latest: releases/latest still serving the previous release fails after the bounded retries and records every download' {
        $previous = New-ReleaseFixture -ExtraEntries @(@{ Name = 'previous-only.txt'; Bytes = [byte[]](1, 2, 3) })
        $verified = New-ReleaseFixture
        $expected = (Get-FileHash -LiteralPath (Join-Path $verified.Dir 'teststand-mcp.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        $recordPath = Join-Path (New-TempDir) 'own-downloads.json'
        $run = Invoke-LatestVerify (New-FakeApi $previous) -Extra @{ ExpectedArchiveSha256 = $expected; OwnDownloadsPath = $recordPath; RunId = '9'; Date = '2026-08-21'; PropagationAttempts = 4; PropagationDelaySeconds = 7 }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'not the archive of the release that was just verified' 'the fault'
        Assert-Contains $run.Output $MayHelp 'the advice: this may be propagation'
        Assert-Equal 3 $run.Delays.Count 'three waits between four attempts'
        Assert-Equal '7,7,7' ($run.Delays -join ',') 'the wait between attempts'
        Assert-Equal 4 (Read-OwnDownloads -Path $recordPath).Counts['2026-08-21']['teststand-mcp.zip']['published'] 'every attempt is a recorded download'
    }

    Invoke-Case 'latest: the new release appearing on the third attempt passes (CDN propagation)' {
        $previous = New-ReleaseFixture -ExtraEntries @(@{ Name = 'previous-only.txt'; Bytes = [byte[]](1, 2, 3) })
        $verified = New-ReleaseFixture
        $expected = (Get-FileHash -LiteralPath (Join-Path $verified.Dir 'teststand-mcp.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        $served = $previous.Dir
        $newDir = $verified.Dir
        $plan = {
            param($Name, $Count)
            if ($Count -ge 3) { Get-ChildItem -LiteralPath $newDir -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $served $_.Name) -Force } }
        }.GetNewClosure()
        $run = Invoke-LatestVerify (New-FakeApi $previous -Plan $plan) -Extra @{ ExpectedArchiveSha256 = $expected }
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Equal 2 $run.Delays.Count 'two waits before the third attempt'
    }

    Invoke-Case 'latest: an asset missing from the previous latest release (the first workflow release) is waited out, not fatal' {
        $fixture = New-ReleaseFixture
        $expected = (Get-FileHash -LiteralPath (Join-Path $fixture.Dir 'teststand-mcp.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        $plan = { param($Name, $Count) if ($Name -eq 'teststand-mcp.zip' -and $Count -le 2) { 'The remote server returned an error: (404) Not Found.' } }
        $run = Invoke-LatestVerify (New-FakeApi $fixture -Plan $plan) -Extra @{ ExpectedArchiveSha256 = $expected }
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Equal 2 $run.Delays.Count 'two waits'
    }

    Invoke-Case 'latest: without an expected digest there is exactly one attempt and the old behaviour' {
        $previous = New-ReleaseFixture
        $run = Invoke-LatestVerify (New-FakeApi $previous)
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-NotContains $run.Output 'verified release' 'no expected digest, no claim about the verified release'
        Assert-Equal 0 $run.Delays.Count 'no wait'
    }

    Invoke-Case 'latest: a malformed expected digest, or one without -Latest, is a three-part failure' {
        $fixture = New-ReleaseFixture
        foreach ($bad in @('abc', ('g' * 64), (('a' * 63) + ' '))) {
            $run = Invoke-LatestVerify (New-FakeApi $fixture) -Extra @{ ExpectedArchiveSha256 = $bad }
            Assert-Equal 1 $run.ExitCode "exit code for [$bad]"
            Assert-Contains $run.Output 'ExpectedArchiveSha256' 'the failure names the parameter'
        }
        $local = Invoke-Script $VerifierPath @{ Tag = $fixture.Tag; LocalDir = $fixture.Dir; ExpectedArchiveSha256 = ('a' * 64) }
        Assert-Equal 1 $local.ExitCode 'exit code without -Latest'
        Assert-Contains $local.Output 'only with -Latest' 'the failure says where it applies'
    }

    Invoke-Case 'latest: -Repo names the repository whose releases/latest is fetched, so a fork checks itself' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture
        $run = Invoke-LatestVerify $api -Extra @{ Repo = 'someone/teststand-mcp-fork' }
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Equal 'https://github.com/someone/teststand-mcp-fork/releases/latest/download/teststand-mcp.zip' $api.State.Calls[0].Uri 'first url'
        $none = New-FakeApi $fixture
        [void](Invoke-LatestVerify $none)
        Assert-Equal $ExpectedLatestUrl $none.State.Calls[0].Uri 'without -Repo the contract repository'
    }

    Invoke-Case 'latest: -Latest with -LocalDir, or a bad -Repo, is still refused' {
        $fixture = New-ReleaseFixture
        $both = Invoke-Script $VerifierPath @{ Latest = $true; LocalDir = $fixture.Dir; Version = '1.9.0' }
        Assert-Equal 1 $both.ExitCode 'exit code for two sources'
        $bad = Invoke-LatestVerify (New-FakeApi $fixture) -Extra @{ Repo = 'not a repo' }
        Assert-Equal 1 $bad.ExitCode 'exit code for a bad repo'
    }

    Invoke-Case 'contract: Get-LatestDownloadUrl takes the repository of a fork' {
        Assert-Equal 'https://github.com/a/b/releases/latest/download/teststand-mcp.sha256' (Get-LatestDownloadUrl -AssetName 'teststand-mcp.sha256' -Repo 'a/b') 'url'
    }
}
finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    Remove-TestTempDirs
}

Complete-TestRun
