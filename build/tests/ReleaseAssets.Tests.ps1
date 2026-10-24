# ============================================================================
#  ReleaseAssets.Tests.ps1 - plain PowerShell asserts for build/ReleaseAssets.psm1,
#  build/Assert-ReleaseTag.ps1 and build/Assert-PublishedRelease.ps1.
#  Runs under Windows PowerShell 5.1 and PowerShell 7:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\tests\ReleaseAssets.Tests.ps1
#  Prints PASS/FAIL per case and exits non-zero when any case fails.
#  NO network: the verifier's HTTP layer is replaced by a scriptblock.
#  ASCII only on purpose: 5.1 reads a BOM-less script as ANSI.
# ============================================================================
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ModulePath = Join-Path $RepoRoot 'build\ReleaseAssets.psm1'
$TagGatePath = Join-Path $RepoRoot 'build\Assert-ReleaseTag.ps1'
$VerifierPath = Join-Path $RepoRoot 'build\Assert-PublishedRelease.ps1'
$MarketplacePath = Join-Path $RepoRoot '.claude-plugin\marketplace.json'
$OwnDownloadsFixturePath = Join-Path $PSScriptRoot 'fixtures\own-downloads.json'

$ExpectedRepoSlug = 'Zuehlke/teststand-mcp'
$ExpectedLatestUrl = 'https://github.com/Zuehlke/teststand-mcp/releases/latest/download/teststand-mcp.zip'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ShaCrypto = [System.Security.Cryptography.SHA256]::Create()
$SampleCommit = ('0123456789abcdef' * 2) + '01234567'   # 40 hex characters
$ArabicIndicOne = [string][char]0x0661                  # a digit that \d matches in .NET but is not 0-9

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

$script:Failures = 0
$script:TempDirs = @()

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS  $Name"
    } catch {
        $script:Failures++
        Write-Host "FAIL  $Name"
        Write-Host "      $($_.Exception.Message)"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What = 'value')
    if ($Expected -cne $Actual) { throw "$What : expected [$Expected] but got [$Actual]" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$What = 'text')
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) { throw "$What does not contain [$Needle]. Text was:`n$Text" }
}

function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$What = 'text')
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) { throw "$What unexpectedly contains [$Needle]. Text was:`n$Text" }
}

# The three parts of every build failure: labelled What / Why / Fix lines, each with content.
function Assert-ThreePartFailure {
    param([string]$Text)
    foreach ($label in @('What', 'Why', 'Fix')) {
        Assert-True ($Text -cmatch "(?m)^${label}: +\S") "failure output has no '${label}:' line with content. Output was:`n$Text"
    }
}

function New-TempDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('ReleaseAssetsTests_' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $script:TempDirs += $dir
    return $dir
}

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

# Runs a script in-process; returns its exit code and everything it printed.
function Invoke-Script {
    param([string]$Path, [hashtable]$Arguments = @{})
    $global:LASTEXITCODE = 0
    $lines = @(& $Path @Arguments *>&1 | ForEach-Object { "$_" })
    return @{ ExitCode = $global:LASTEXITCODE; Output = ($lines -join "`n") }
}

# Runs an environment-variable override around a block, restoring the old value.
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

# Zip entries are named with '/'. ZipFile.CreateFromDirectory is NOT used: under Windows PowerShell 5.1 it
# writes '' separators (measured), which is a defective archive for any other extractor.
function New-ZipFromDirectory {
    param([string]$SourceDir, [string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression
    $root = [IO.Path]::GetFullPath($SourceDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $stream = [IO.File]::Create($ZipPath)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in (Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force)) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $file.FullName.Substring($root.Length).Replace('\', '/'))
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

try {
    Assert-True (Test-Path -LiteralPath $ModulePath) "build\ReleaseAssets.psm1 does not exist yet"
    Import-Module $ModulePath -Force

    # --- Asset contract ---------------------------------------------------------
    Invoke-Case 'contract: the four asset names and the repo slug are the published ones' {
        Assert-Equal $ExpectedRepoSlug $ReleaseRepoSlug 'repo slug'
        Assert-Equal 'teststand-mcp.zip' $ReleaseArchiveName 'archive'
        Assert-Equal 'teststand-mcp.sha256' $ReleaseDigestName 'digest'
        Assert-Equal 'teststand-mcp.manifest.sha256' $ReleaseManifestName 'manifest'
        Assert-Equal 'teststand-mcp-v1.9.0.zip' (Get-VersionedArchiveName -Version '1.9.0') 'versioned archive'
        Assert-Equal 'teststand-mcp-v0.0.0-ci.zip' (Get-VersionedArchiveName -Version '0.0.0-ci') 'versioned archive of a ci build'
        Assert-Equal 'teststand-mcp.zip|teststand-mcp-v1.9.0.zip|teststand-mcp.sha256|teststand-mcp.manifest.sha256' ((Get-RequiredAssetNames -Version '1.9.0') -join '|') 'required assets in download order'
    }

    Invoke-Case 'contract: the latest-download URL builder gives the fixed archive URL' {
        Assert-Equal $ExpectedLatestUrl (Get-LatestDownloadUrl) 'default asset'
        Assert-Equal 'https://github.com/Zuehlke/teststand-mcp/releases/latest/download/teststand-mcp.sha256' (Get-LatestDownloadUrl -AssetName $ReleaseDigestName) 'digest asset'
    }

    Invoke-Case 'contract: marketplace.json source.url equals the URL builder output (ties slice 2 to this owner)' {
        $marketplace = [IO.File]::ReadAllText($MarketplacePath, $Utf8NoBom) | ConvertFrom-Json
        Assert-Equal (Get-LatestDownloadUrl) $marketplace.plugins[0].source.url 'marketplace archive url'
    }

    # --- Scenario Outline: Tag validation ---------------------------------------
    foreach ($row in $TagTable) {
        Invoke-Case "tag table: [$($row.Tag)] -> $($row.Verdict)" {
            $result = ConvertFrom-ReleaseTag -Tag $row.Tag
            Assert-Equal $row.Verdict $result.Verdict 'verdict'
            Assert-Equal $row.Verdict.StartsWith('valid') $result.Valid 'valid flag'
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
        Assert-True (-not (ConvertFrom-ReleaseTag -Tag "v1.9.0`n").Valid) 'trailing newline accepted'
        Assert-True (-not (ConvertFrom-ReleaseTag -Tag ' v1.9.0').Valid) 'leading space accepted'
        Assert-True (-not (ConvertFrom-ReleaseTag -Tag "v${ArabicIndicOne}.9.0").Valid) 'a non-ASCII digit accepted'
    }

    Invoke-Case 'tag: only a case or missing-v mistake gets a suggested tag' {
        Assert-Equal 'v1.9.0' (ConvertFrom-ReleaseTag -Tag 'V1.9.0').SuggestedTag 'upper-case V'
        Assert-Equal 'v1.9.0' (ConvertFrom-ReleaseTag -Tag '1.9.0').SuggestedTag 'no v'
        foreach ($tag in @('v1.9', 'V1.9', 'v01.9.0', 'v1.9.0-rc', 'v1.9.0.1', 'latest', '1.9', '')) {
            Assert-True ($null -eq (ConvertFrom-ReleaseTag -Tag $tag).SuggestedTag) "no version may be invented for [$tag]"
        }
    }

    # --- Tag gate script ----------------------------------------------------------
    Invoke-Case 'gate: a valid tag exits 0 and writes version= and tag= to GITHUB_OUTPUT' {
        $outFile = Join-Path (New-TempDir) 'github_output'
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile {
            $run = Invoke-Script $TagGatePath @{ Tag = 'v1.10.0' }
            Assert-Equal 0 $run.ExitCode 'exit code'
        }
        $bytes = [IO.File]::ReadAllBytes($outFile)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'GITHUB_OUTPUT file starts with a BOM'
        $lines = @($Utf8NoBom.GetString($bytes) -split "`n" | Where-Object { $_ })
        Assert-Equal 'version=1.10.0|tag=v1.10.0' ($lines -join '|') 'GITHUB_OUTPUT lines'
    }

    Invoke-Case 'gate: a valid tag without GITHUB_OUTPUT still exits 0' {
        Use-EnvironmentVariable 'GITHUB_OUTPUT' $null {
            $run = Invoke-Script $TagGatePath @{ Tag = 'v1.9.0' }
            Assert-Equal 0 $run.ExitCode 'exit code'
            Assert-Contains $run.Output '1.9.0' 'gate output'
        }
    }

    foreach ($row in @($TagTable | Where-Object { -not $_.Verdict.StartsWith('valid') })) {
        Invoke-Case "gate: [$($row.Tag)] exits 1, says '$($row.Verdict)' and writes nothing to GITHUB_OUTPUT" {
            $outFile = Join-Path (New-TempDir) 'github_output'
            Use-EnvironmentVariable 'GITHUB_OUTPUT' $outFile {
                $run = Invoke-Script $TagGatePath @{ Tag = $row.Tag }
                Assert-Equal 1 $run.ExitCode 'exit code'
                Assert-Contains $run.Output $row.Verdict 'gate output'
                Assert-ThreePartFailure $run.Output
            }
            Assert-True (-not (Test-Path -LiteralPath $outFile)) 'GITHUB_OUTPUT must not be written for a rejected tag'
        }
    }

    # --- Scenario: A fixable tag gets the fix in a safe order ----------------------
    Invoke-Case 'gate: V1.9.0 says why the format is required and lists delete remote, delete local, create, push in order' {
        $run = Invoke-Script $TagGatePath @{ Tag = 'V1.9.0'; Commit = $SampleCommit }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'exactly v<major>.<minor>.<patch>' 'why the format is required'
        Assert-Contains $run.Output 'case-sensitive' 'why an upper-case V gets no answer from GitHub'
        $steps = @(
            'git push --delete origin V1.9.0'
            'git tag -d V1.9.0'
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
    }

    Invoke-Case 'gate: without a known commit the retag falls back to HEAD and says to check it' {
        Use-EnvironmentVariable 'GITHUB_SHA' $null {
            $run = Invoke-Script $TagGatePath @{ Tag = '1.9.0' }
            Assert-Contains $run.Output 'git tag v1.9.0 HEAD' 'create command'
            Assert-Contains $run.Output 'HEAD' 'commit note'
            Assert-Contains $run.Output 'git rev-list -n 1' 'how to check the commit'
        }
    }

    Invoke-Case 'gate: the commit comes from GITHUB_SHA when it is a full sha' {
        Use-EnvironmentVariable 'GITHUB_SHA' $SampleCommit {
            $run = Invoke-Script $TagGatePath @{ Tag = 'V1.9.0' }
            Assert-Contains $run.Output "git tag v1.9.0 $SampleCommit" 'create command'
        }
    }

    # --- Scenario: An unfixable tag asks for a choice --------------------------------
    Invoke-Case 'gate: v1.9 asks the maintainer to choose a vX.Y.Z and shows only the delete commands' {
        $run = Invoke-Script $TagGatePath @{ Tag = 'v1.9'; Commit = $SampleCommit }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'Choose the version you mean' 'asks for a choice'
        Assert-Contains $run.Output 'vX.Y.Z' 'names the format'
        Assert-Contains $run.Output 'git push --delete origin v1.9' 'remote delete'
        Assert-Contains $run.Output 'git tag -d v1.9' 'local delete'
        Assert-True ($run.Output.IndexOf('git push --delete origin v1.9') -lt $run.Output.IndexOf('git tag -d v1.9')) 'remote delete must come first'
        Assert-True ($run.Output -cnotmatch 'git tag (?!-d)') 'a create-tag command was invented'
        Assert-True ($run.Output -cnotmatch 'git push origin') 'a push-new-tag command was invented'
    }

    Invoke-Case 'gate: an unusual tag is quoted in the printed commands and control characters are not echoed raw' {
        $run = Invoke-Script $TagGatePath @{ Tag = "v1.9`$(x)`a" }
        Assert-Contains $run.Output "git tag -d 'v1.9`$(x)?'" 'quoted local delete'
        Assert-True ($run.Output.IndexOf([char]7) -lt 0) 'a control character was echoed'
    }

    Invoke-Case 'gate: a child process under -File exits 1 for a bad tag and 0 for a good one' {
        $powershell = (Get-Process -Id $PID).Path
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $TagGatePath -Tag 'V1.9.0' *> $null
        Assert-Equal 1 $LASTEXITCODE 'exit code for V1.9.0'
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $TagGatePath -Tag 'v1.9.0' *> $null
        Assert-Equal 0 $LASTEXITCODE 'exit code for v1.9.0'
    }

    # --- Digest and manifest ----------------------------------------------------------
    Invoke-Case 'digest: sha256sum -c format, lower-case hash, two spaces, LF' {
        $zip = Join-Path (New-TempDir) 'teststand-mcp.zip'
        [IO.File]::WriteAllBytes($zip, [byte[]](1, 2, 3, 4))
        $expected = (Get-Sha256Of ([byte[]](1, 2, 3, 4))) + '  teststand-mcp.zip' + "`n"
        Assert-Equal $expected (New-ArchiveDigest -ArchivePath $zip) 'digest text'
    }

    Invoke-Case 'manifest: sorted, forward slashes, one "<hash>  <path>" line per file of the staged tree' {
        $staged = New-StagedTree
        $lines = @((New-ArchiveManifest -StagedDir $staged) -split "`n" | Where-Object { $_ })
        Assert-Equal 5 $lines.Count 'one line per file'
        $paths = @($lines | ForEach-Object { $_.Substring(66) })
        Assert-Equal '.claude-plugin/plugin.json|VERSION.txt|bin/TestStandMCP.exe|bin/appsettings.json|bin/scripts/with space.txt' ($paths -join '|') 'ordinal path order'
        $exeLine = $lines | Where-Object { $_.EndsWith('  bin/TestStandMCP.exe') }
        Assert-Equal ((Get-Sha256Of ([byte[]](0, 1, 2, 253, 254, 255, 0, 77))) + '  bin/TestStandMCP.exe') $exeLine 'hash line of the exe'
    }

    Invoke-Case 'manifest: round trip - a zip of the tree passes Test-ArchiveManifest with no problems' {
        $staged = New-StagedTree
        $zip = Join-Path (New-TempDir) 'archive.zip'
        New-ZipFromDirectory $staged $zip
        $problems = @(Test-ArchiveManifest -ArchivePath $zip -ManifestText (New-ArchiveManifest -StagedDir $staged))
        Assert-Equal 0 $problems.Count "problems: $(($problems | ForEach-Object { $_.Kind + ' ' + $_.Path }) -join '; ')"
    }

    Invoke-Case 'manifest: a changed file, an extra archive entry and a missing archive entry are each named' {
        $staged = New-StagedTree
        $manifest = New-ArchiveManifest -StagedDir $staged
        $zip = Join-Path (New-TempDir) 'archive.zip'
        New-ZipFromDirectory $staged $zip
        # Edit the manifest to differ from the zip in three ways.
        $edited = @($manifest -split "`n" | Where-Object { $_ })
        $edited = @($edited | Where-Object { -not $_.EndsWith('  VERSION.txt') })                                   # archive has an entry the manifest lacks
        $edited = @($edited | ForEach-Object { if ($_.EndsWith('  bin/appsettings.json')) { ('0' * 64) + '  bin/appsettings.json' } else { $_ } })   # hash differs
        $edited += ((Get-Sha256Of ([byte[]](9))) + '  bin/ghost.dll')                                                # manifest lists an entry the archive lacks
        $problems = @(Test-ArchiveManifest -ArchivePath $zip -ManifestText (($edited -join "`n") + "`n"))
        $byKind = @{}
        foreach ($problem in $problems) { $byKind[$problem.Kind] = $problem.Path }
        Assert-Equal 3 $problems.Count 'problem count'
        Assert-Equal 'bin/appsettings.json' $byKind['hash-mismatch'] 'hash mismatch path'
        Assert-Equal 'VERSION.txt' $byKind['entry-not-in-manifest'] 'extra archive entry path'
        Assert-Equal 'bin/ghost.dll' $byKind['entry-missing-from-archive'] 'missing archive entry path'
    }

    Invoke-Case 'manifest: an archive entry named with backslashes is reported with the reason' {
        $staged = New-StagedTree
        $zip = Join-Path (New-TempDir) 'backslash.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staged, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
        $problems = @(Test-ArchiveManifest -ArchivePath $zip -ManifestText (New-ArchiveManifest -StagedDir $staged))
        $backslash = @($problems | Where-Object { $_.Kind -eq 'entry-not-in-manifest' -and $_.Path.Contains('\') })
        # Windows PowerShell 5.1 writes backslashes here; PowerShell 7 writes '/', so only assert the hint when it happened.
        foreach ($problem in $backslash) { Assert-Contains $problem.Detail 'backslash' 'detail of a backslash entry' }
    }

    Invoke-Case 'manifest: a malformed manifest line is reported, not skipped' {
        $zip = Join-Path (New-TempDir) 'archive.zip'
        New-ZipFromDirectory (New-StagedTree) $zip
        $problems = @(Test-ArchiveManifest -ArchivePath $zip -ManifestText "not a hash line`n")
        Assert-True (@($problems | Where-Object { $_.Kind -eq 'manifest-malformed' }).Count -eq 1) 'expected one manifest-malformed problem'
    }

    Invoke-Case 'manifest: an empty staged tree is refused with a three-part failure' {
        $empty = Join-Path (New-TempDir) 'empty'
        [void](New-Item -ItemType Directory -Path $empty)
        $message = $null
        try { [void](New-ArchiveManifest -StagedDir $empty) } catch { $message = $_.Exception.Message }
        Assert-True ($null -ne $message) 'expected a failure'
        Assert-ThreePartFailure $message
    }

    # --- Write-BuildFailure -----------------------------------------------------------
    Invoke-Case 'Write-BuildFailure: throws a message with all three labelled parts' {
        $message = $null
        try { Write-BuildFailure -What 'the thing broke' -Why 'because of X' -Fix "do Y`nthen Z" } catch { $message = $_.Exception.Message }
        Assert-True ($null -ne $message) 'expected a throw'
        Assert-ThreePartFailure $message
        Assert-Contains $message 'the thing broke' 'what'
        Assert-Contains $message 'because of X' 'why'
        Assert-Contains $message 'then Z' 'second fix line'
    }

    Invoke-Case 'Write-BuildFailure: an empty part is refused, so no failure can lack one' {
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

    # --- Own-downloads record ----------------------------------------------------------
    Invoke-Case 'own-downloads: verify + retry + final fetch count 3 for the zip and equal the shared fixture' {
        $path = Join-Path (New-TempDir) 'own-downloads.json'
        $common = @{ Path = $path; RunId = '1234567890'; Date = '2026-08-20' }
        # verify attempt 1: the zip arrives, the digest download fails (still a request)
        Add-OwnDownload @common -AssetName 'teststand-mcp.zip' -Draft
        Add-OwnDownload @common -AssetName 'teststand-mcp.sha256' -Draft
        # retry: all four assets
        foreach ($name in @('teststand-mcp.zip', 'teststand-mcp-v1.9.0.zip', 'teststand-mcp.sha256', 'teststand-mcp.manifest.sha256')) {
            Add-OwnDownload @common -AssetName $name -Draft
        }
        # final public fetch of the fixed zip
        Add-OwnDownload @common -AssetName 'teststand-mcp.zip'

        $record = Read-OwnDownloads -Path $path
        Assert-Equal 3 $record.Assets['teststand-mcp.zip'] 'zip downloads'

        $fixture = Read-OwnDownloads -Path $OwnDownloadsFixturePath
        Assert-Equal $fixture.RunId $record.RunId 'run_id'
        Assert-Equal $fixture.Date $record.Date 'date'
        Assert-Equal $fixture.Draft $record.Draft 'draft'
        Assert-Equal (($fixture.Assets.Keys | Sort-Object) -join ',') (($record.Assets.Keys | Sort-Object) -join ',') 'asset names'
        foreach ($name in $fixture.Assets.Keys) { Assert-Equal $fixture.Assets[$name] $record.Assets[$name] "count of $name" }
    }

    Invoke-Case 'own-downloads: the file on disk has exactly the keys run_id, date, assets, draft with the right types' {
        $path = Join-Path (New-TempDir) 'own-downloads.json'
        Add-OwnDownload -Path $path -AssetName 'teststand-mcp.zip' -RunId '77' -Date '2026-01-02'
        $json = [IO.File]::ReadAllText($path, $Utf8NoBom) | ConvertFrom-Json
        Assert-Equal 'assets,date,draft,run_id' ((@($json.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ',') 'keys'
        Assert-Equal '77' $json.run_id 'run_id'
        Assert-True ($json.run_id -is [string]) 'run_id must be a string'
        Assert-Equal '2026-01-02' $json.date 'date'
        Assert-True ($json.draft -is [bool] -and $json.draft -eq $false) 'draft must be the boolean false when no draft download was recorded'
        Assert-True ($json.assets.'teststand-mcp.zip' -is [int] -or $json.assets.'teststand-mcp.zip' -is [long]) 'count must be an integer'
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'own-downloads.json starts with a BOM'
    }

    Invoke-Case 'own-downloads: a record of another run is refused instead of being merged' {
        $path = Join-Path (New-TempDir) 'own-downloads.json'
        Add-OwnDownload -Path $path -AssetName 'teststand-mcp.zip' -RunId '1' -Date '2026-01-02'
        $message = $null
        try { Add-OwnDownload -Path $path -AssetName 'teststand-mcp.zip' -RunId '2' -Date '2026-01-02' } catch { $message = $_.Exception.Message }
        Assert-True ($null -ne $message) 'expected a failure'
        Assert-ThreePartFailure $message
    }

    Invoke-Case 'own-downloads: without a run id (parameter or GITHUB_RUN_ID) the call fails' {
        Use-EnvironmentVariable 'GITHUB_RUN_ID' $null {
            $message = $null
            try { Add-OwnDownload -Path (Join-Path (New-TempDir) 'o.json') -AssetName 'teststand-mcp.zip' } catch { $message = $_.Exception.Message }
            Assert-True ($null -ne $message) 'expected a failure'
            Assert-ThreePartFailure $message
        }
    }

    Invoke-Case 'own-downloads: the run id and date default to GITHUB_RUN_ID and today (UTC)' {
        $path = Join-Path (New-TempDir) 'o.json'
        Use-EnvironmentVariable 'GITHUB_RUN_ID' '4242' {
            Add-OwnDownload -Path $path -AssetName 'teststand-mcp.zip'
        }
        $record = Read-OwnDownloads -Path $path
        Assert-Equal '4242' $record.RunId 'run id'
        Assert-Equal ([DateTime]::UtcNow.ToString('yyyy-MM-dd')) $record.Date 'date'
    }

    Invoke-Case 'own-downloads: an unreadable record is a three-part failure naming the file' {
        $path = Join-Path (New-TempDir) 'bad.json'
        Write-TextFile $path '{"run_id":"1"}'
        $message = $null
        try { [void](Read-OwnDownloads -Path $path) } catch { $message = $_.Exception.Message }
        Assert-True ($null -ne $message) 'expected a failure'
        Assert-ThreePartFailure $message
        Assert-Contains $message 'bad.json' 'file name'
    }
}
finally {
    Remove-Module ReleaseAssets -ErrorAction SilentlyContinue
    foreach ($dir in $script:TempDirs) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($script:Failures -gt 0) {
    Write-Host ''
    Write-Host "$script:Failures case(s) FAILED"
    exit 1
}
Write-Host ''
Write-Host 'All cases passed'
exit 0
