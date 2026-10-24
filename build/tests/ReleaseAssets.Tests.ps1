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
$script:FailedRuns = @()

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
    $run = @{ ExitCode = $global:LASTEXITCODE; Output = ($lines -join "`n") }
    if ($run.ExitCode -ne 0) { $script:FailedRuns += @(@{ Script = (Split-Path -Leaf $Path); Output = $run.Output }) }
    return $run
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
        Assert-Equal 'teststand-mcp.zip|teststand-mcp.sha256|teststand-mcp.manifest.sha256|teststand-mcp-v1.9.0.zip' ((Get-RequiredAssetNames -Version '1.9.0') -join '|') 'required assets in download order'
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

    Invoke-Case 'Get-ScriptFailureText: a Write-BuildFailure message passes through, any other error is wrapped into three parts' {
        $built = $null
        try { Write-BuildFailure -What 'w' -Why 'y' -Fix 'f' } catch { $built = $_ }
        Assert-Equal $built.Exception.Message (Get-ScriptFailureText -ErrorRecord $built) 'pass-through'
        $plain = $null
        try { throw 'something odd' } catch { $plain = $_ }
        $text = Get-ScriptFailureText -ErrorRecord $plain
        Assert-ThreePartFailure $text
        Assert-Contains $text 'something odd' 'the original message'
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

    # --- Verifier fixtures -------------------------------------------------------------
    $BotLogin = 'github-actions[bot]'
    $ApiAssetUrlFormat = 'https://api.github.com/repos/Zuehlke/teststand-mcp/releases/assets/{0}'
    $FirstAssetId = 1000
    $DefaultRetryDelay = 30
    $FakeToken = 'ghs_FAKE_TOKEN_FOR_TESTS'

    # A release as a user would download it: the four assets of version 1.9.0 in one directory.
    function New-ReleaseFixture {
        param([string]$Version = '1.9.0')
        $staged = New-StagedTree
        $dir = Join-Path (New-TempDir) 'assets'
        [void](New-Item -ItemType Directory -Path $dir)
        $zip = Join-Path $dir 'teststand-mcp.zip'
        New-ZipFromDirectory $staged $zip
        Write-TextFile (Join-Path $dir 'teststand-mcp.sha256') (New-ArchiveDigest -ArchivePath $zip)
        Write-TextFile (Join-Path $dir 'teststand-mcp.manifest.sha256') (New-ArchiveManifest -StagedDir $staged)
        Copy-Item -LiteralPath $zip -Destination (Join-Path $dir "teststand-mcp-v$Version.zip")
        return @{ Dir = $dir; Version = $Version; Tag = "v$Version"; Staged = $staged }
    }

    # The GitHub releases-list JSON for one release (plus a decoy), with an uploader per asset.
    function New-ReleaseJsonText {
        param([string]$Tag, [string[]]$AssetNames, [hashtable]$UploaderByAsset = @{}, [bool]$Draft = $true)
        $assets = @()
        for ($index = 0; $index -lt $AssetNames.Count; $index++) {
            $name = $AssetNames[$index]
            $login = $BotLogin
            if ($UploaderByAsset.ContainsKey($name)) { $login = $UploaderByAsset[$name] }
            $id = $FirstAssetId + $index
            $assets += @{ id = $id; name = $name; url = ($ApiAssetUrlFormat -f $id); uploader = @{ login = $login } }
        }
        $decoy = @{ tag_name = 'v0.0.1'; draft = $false; assets = @() }
        $release = @{ tag_name = $Tag; draft = $Draft; assets = $assets }
        return (ConvertTo-Json -InputObject @($decoy, $release) -Depth 6)
    }

    function Invoke-LocalVerify {
        param($Fixture, [hashtable]$UploaderByAsset = @{}, [switch]$NoReleaseJson, [hashtable]$Extra = @{})
        $arguments = @{ Tag = $Fixture.Tag; LocalDir = $Fixture.Dir }
        if (-not $NoReleaseJson) {
            $jsonPath = Join-Path (New-TempDir) 'release.json'
            Write-TextFile $jsonPath (New-ReleaseJsonText -Tag $Fixture.Tag -AssetNames (Get-RequiredAssetNames -Version $Fixture.Version) -UploaderByAsset $UploaderByAsset)
            $arguments.ReleaseJson = $jsonPath
        }
        foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
        return Invoke-Script $VerifierPath $arguments
    }

    # A fake GitHub API at the HTTP boundary. $Plan decides, per asset and per download count, whether a
    # download fails (returns the failure text) or succeeds ($null). $State records every request.
    # $ListedJson overrides the releases listing.
    function New-FakeApi {
        param($Fixture, [scriptblock]$Plan = { param($Name, $Count) $null }, [string]$ReleasesFailure = $null, [string]$ListedTag = $null, [string]$ListedJson = $null)
        if (-not $ListedTag) { $ListedTag = $Fixture.Tag }
        $names = @(Get-RequiredAssetNames -Version $Fixture.Version)
        $json = $ListedJson
        if (-not $json) { $json = New-ReleaseJsonText -Tag $ListedTag -AssetNames $names }
        $dir = $Fixture.Dir
        $nameById = @{}
        foreach ($release in @($json | ConvertFrom-Json | ForEach-Object { $_ })) {
            foreach ($asset in @($release.assets)) { $nameById[[string]$asset.id] = $asset.name }
        }
        $state = @{ Calls = (New-Object System.Collections.ArrayList); Downloads = @{} }
        $http = {
            param($Uri, $Headers, $OutFile, $TimeoutSeconds)
            [void]$state.Calls.Add(@{ Uri = $Uri; Headers = $Headers; OutFile = $OutFile; TimeoutSeconds = $TimeoutSeconds })
            if ($Uri -match '/releases\?') {
                if ($ReleasesFailure) { throw $ReleasesFailure }
                return $json
            }
            if ($Uri -match '/releases/assets/(\d+)\z') {
                $name = $nameById[$Matches[1]]
                if (-not $state.Downloads.ContainsKey($name)) { $state.Downloads[$name] = 0 }
                $state.Downloads[$name] = $state.Downloads[$name] + 1
                $failure = & $Plan $name $state.Downloads[$name]
                if ($failure) { throw $failure }
                Copy-Item -LiteralPath (Join-Path $dir $name) -Destination $OutFile
                return
            }
            throw "unexpected request $Uri"
        }.GetNewClosure()
        return @{ Http = $http; State = $state }
    }

    function Invoke-ApiVerify {
        param($Fixture, $Api, [string]$OwnDownloadsPath, [hashtable]$Extra = @{})
        $delays = New-Object System.Collections.ArrayList
        $delay = { param([int]$Seconds) [void]$delays.Add($Seconds) }.GetNewClosure()
        $arguments = @{ Repo = $ExpectedRepoSlug; Tag = $Fixture.Tag; Token = $FakeToken; HttpGet = $Api.Http; Delay = $delay; Draft = $true }
        if ($OwnDownloadsPath) { $arguments.OwnDownloadsPath = $OwnDownloadsPath }
        foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
        $run = Invoke-Script $VerifierPath $arguments
        $run.Delays = @($delays)
        return $run
    }

    function Get-AssetRequests {
        param($Api)
        return @($Api.State.Calls | Where-Object { $_.Uri -match '/releases/assets/' })
    }

    # --- Scenario: A CI-built draft verifies -------------------------------------------
    Invoke-Case 'verify local: four assets, bot uploader, matching digest and manifest -> exit 0' {
        $run = Invoke-LocalVerify (New-ReleaseFixture)
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Contains $run.Output 'verified' 'success line'
        Assert-Contains $run.Output 'Downloaded 0 asset' 'local mode downloads nothing and says so'
    }

    Invoke-Case 'verify local: without a release json the uploader check is skipped and the output says so' {
        $run = Invoke-LocalVerify (New-ReleaseFixture) -NoReleaseJson
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Contains $run.Output 'uploader check skipped' 'skip notice'
    }

    # --- Scenario Outline: A release that must not go live ------------------------------
    $RerunWillNotHelp = 'A re-run will not help'
    $FaultRows = @(
        @{ Fault = 'the zip was uploaded by a person'; Uploader = @{ 'teststand-mcp.zip' = 'alice' }
           Expect = @("teststand-mcp.zip was uploaded by 'alice'", 'github-actions[bot]') }
        @{ Fault = "the zip's hash differs from the digest"
           Mutate = { param($fx) Write-TextFile (Join-Path $fx.Dir 'teststand-mcp.sha256') (('0' * 64) + '  teststand-mcp.zip' + "`n") }
           Expect = @('teststand-mcp.zip does not match teststand-mcp.sha256') }
        @{ Fault = 'one manifest entry differs from the archive'
           Mutate = { param($fx)
               $path = Join-Path $fx.Dir 'teststand-mcp.manifest.sha256'
               $lines = @([IO.File]::ReadAllText($path, $Utf8NoBom) -split "`n" | Where-Object { $_ } | ForEach-Object { if ($_.EndsWith('  bin/appsettings.json')) { ('0' * 64) + '  bin/appsettings.json' } else { $_ } })
               Write-TextFile $path (($lines -join "`n") + "`n") }
           Expect = @("archive entry 'bin/appsettings.json' differs from the manifest") }
        @{ Fault = 'the archive has an entry the manifest lacks'
           Mutate = { param($fx)
               $path = Join-Path $fx.Dir 'teststand-mcp.manifest.sha256'
               $lines = @([IO.File]::ReadAllText($path, $Utf8NoBom) -split "`n" | Where-Object { $_ -and -not $_.EndsWith('  VERSION.txt') })
               Write-TextFile $path (($lines -join "`n") + "`n") }
           Expect = @("archive entry 'VERSION.txt' is not listed in the manifest") }
        @{ Fault = 'the manifest lists an entry the archive lacks'
           Mutate = { param($fx)
               $path = Join-Path $fx.Dir 'teststand-mcp.manifest.sha256'
               Write-TextFile $path ([IO.File]::ReadAllText($path, $Utf8NoBom) + (Get-Sha256Of ([byte[]](9))) + "  bin/ghost.dll`n") }
           Expect = @("the manifest lists 'bin/ghost.dll' but the archive has no such entry") }
        @{ Fault = 'the version-named copy differs from the fixed zip'
           Mutate = { param($fx) [IO.File]::WriteAllBytes((Join-Path $fx.Dir 'teststand-mcp-v1.9.0.zip'), [byte[]](1, 2, 3)) }
           Expect = @('teststand-mcp-v1.9.0.zip differs from teststand-mcp.zip') }
        @{ Fault = 'teststand-mcp.zip is missing'
           Mutate = { param($fx) Remove-Item -LiteralPath (Join-Path $fx.Dir 'teststand-mcp.zip') }
           Expect = @('teststand-mcp.zip is missing from the release') }
        @{ Fault = 'teststand-mcp.sha256 is missing'
           Mutate = { param($fx) Remove-Item -LiteralPath (Join-Path $fx.Dir 'teststand-mcp.sha256') }
           Expect = @('teststand-mcp.sha256 is missing from the release') }
        @{ Fault = 'teststand-mcp.manifest.sha256 is missing'
           Mutate = { param($fx) Remove-Item -LiteralPath (Join-Path $fx.Dir 'teststand-mcp.manifest.sha256') }
           Expect = @('teststand-mcp.manifest.sha256 is missing from the release') }
        @{ Fault = 'the version-named copy is missing'
           Mutate = { param($fx) Remove-Item -LiteralPath (Join-Path $fx.Dir 'teststand-mcp-v1.9.0.zip') }
           Expect = @('teststand-mcp-v1.9.0.zip is missing from the release') }
    )
    foreach ($row in $FaultRows) {
        Invoke-Case "verify local fault: $($row.Fault) -> exit 1, names the fault, says a re-run will not help, gives the fix" {
            $fixture = New-ReleaseFixture
            if ($row.ContainsKey('Mutate')) { & $row.Mutate $fixture }
            $uploaders = @{}
            if ($row.ContainsKey('Uploader')) { $uploaders = $row.Uploader }
            $run = Invoke-LocalVerify $fixture -UploaderByAsset $uploaders
            Assert-Equal 1 $run.ExitCode 'exit code'
            Assert-ThreePartFailure $run.Output
            foreach ($phrase in $row.Expect) { Assert-Contains $run.Output $phrase 'fault text' }
            Assert-Contains $run.Output $RerunWillNotHelp 're-run advice'
        }
    }

    Invoke-Case 'verify local fault: a missing zip is reported alone, not as a cascade of dependent faults' {
        $fixture = New-ReleaseFixture
        Remove-Item -LiteralPath (Join-Path $fixture.Dir 'teststand-mcp.zip')
        $run = Invoke-LocalVerify $fixture
        Assert-NotContains $run.Output 'does not match' 'a hash comparison against a missing zip'
        Assert-NotContains $run.Output 'differs from' 'a comparison against a missing zip'
    }

    Invoke-Case 'verify local fault: two faults are both named in one failure' {
        $fixture = New-ReleaseFixture
        Remove-Item -LiteralPath (Join-Path $fixture.Dir 'teststand-mcp.sha256')
        [IO.File]::WriteAllBytes((Join-Path $fixture.Dir 'teststand-mcp-v1.9.0.zip'), [byte[]](1))
        $run = Invoke-LocalVerify $fixture
        Assert-Contains $run.Output 'teststand-mcp.sha256 is missing from the release' 'first fault'
        Assert-Contains $run.Output 'teststand-mcp-v1.9.0.zip differs from teststand-mcp.zip' 'second fault'
    }

    Invoke-Case 'verify local fault: a digest that names another file or is malformed is a fault' {
        $fixture = New-ReleaseFixture
        Write-TextFile (Join-Path $fixture.Dir 'teststand-mcp.sha256') ((Get-FileSha256 (Join-Path $fixture.Dir 'teststand-mcp.zip')) + "  other.zip`n")
        $run = Invoke-LocalVerify $fixture
        Assert-Equal 1 $run.ExitCode 'exit code for a digest naming another file'
        Assert-Contains $run.Output 'other.zip' 'digest file name'
        Write-TextFile (Join-Path $fixture.Dir 'teststand-mcp.sha256') "garbage`n"
        $run = Invoke-LocalVerify $fixture
        Assert-Equal 1 $run.ExitCode 'exit code for a malformed digest'
        Assert-Contains $run.Output 'teststand-mcp.sha256' 'malformed digest names the file'
    }

    Invoke-Case 'verify local: a LocalDir that does not exist fails with the three parts' {
        $run = Invoke-Script $VerifierPath @{ Tag = 'v1.9.0'; LocalDir = (Join-Path (New-TempDir) 'nope') }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-ThreePartFailure $run.Output
    }

    Invoke-Case 'verify local: a release json that is not JSON still gives a three-part failure naming the error' {
        $fixture = New-ReleaseFixture
        $jsonPath = Join-Path (New-TempDir) 'broken.json'
        Write-TextFile $jsonPath '{ this is not json'
        $run = Invoke-Script $VerifierPath @{ Tag = $fixture.Tag; LocalDir = $fixture.Dir; ReleaseJson = $jsonPath }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-ThreePartFailure $run.Output
        Assert-Contains $run.Output 'Unexpected error' 'unexpected-error label'
    }

    Invoke-Case 'verify: neither -Repo nor -LocalDir fails with the three parts' {
        $run = Invoke-Script $VerifierPath @{ Tag = 'v1.9.0' }
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-ThreePartFailure $run.Output
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

    # --- API mode through a fake HTTP boundary --------------------------------------------
    Invoke-Case 'verify api: reads the draft through the API with the token, downloads four assets, exit 0' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Contains $run.Output 'Downloaded 4 asset(s) in 1 attempt' 'download count'
        $listing = @($api.State.Calls | Where-Object { $_.Uri -match '/releases\?' })[0]
        Assert-True ($listing.Uri.StartsWith('https://api.github.com/repos/Zuehlke/teststand-mcp/releases?')) "listing url was $($listing.Uri)"
        Assert-Equal "Bearer $FakeToken" $listing.Headers['Authorization'] 'listing authorization'
        $requests = Get-AssetRequests $api
        Assert-Equal 4 $requests.Count 'asset requests'
        foreach ($request in $requests) {
            Assert-Equal 'application/octet-stream' $request.Headers['Accept'] "accept header of $($request.Uri)"
            Assert-Equal "Bearer $FakeToken" $request.Headers['Authorization'] "authorization of $($request.Uri)"
            Assert-True ($request.TimeoutSeconds -gt 0) 'every web call carries a timeout'
        }
        Assert-True ($listing.TimeoutSeconds -gt 0) 'the listing call carries a timeout'
        Assert-NotContains $run.Output $FakeToken 'output (the token must never be printed)'
    }

    Invoke-Case 'verify api: without a token no Authorization header is sent' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture
        $run = Invoke-ApiVerify $fixture $api -Extra @{ Token = '' }
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        foreach ($call in $api.State.Calls) { Assert-True (-not $call.Headers.ContainsKey('Authorization')) "Authorization sent to $($call.Uri)" }
    }

    Invoke-Case 'verify api: an asset uploaded by a person fails and is not retried' {
        $fixture = New-ReleaseFixture
        $listJson = New-ReleaseJsonText -Tag $fixture.Tag -AssetNames (Get-RequiredAssetNames -Version $fixture.Version) -UploaderByAsset @{ 'teststand-mcp.zip' = 'alice' }
        $api = New-FakeApi $fixture -ListedJson $listJson
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output "teststand-mcp.zip was uploaded by 'alice'" 'fault'
        Assert-Equal 0 $run.Delays.Count 'a retry delay was used for a non-download fault'
    }

    Invoke-Case 'verify api: no release for the tag explains that a draft needs -Token, and is not retried' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -ListedTag 'v9.9.9'
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-ThreePartFailure $run.Output
        Assert-Contains $run.Output 'v1.9.0' 'tag'
        Assert-Contains $run.Output '-Token' 'draft hint'
        Assert-Equal 0 (Get-AssetRequests $api).Count 'asset requests'
    }

    Invoke-Case 'verify api: the releases list failing is a three-part failure and is not retried' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -ReleasesFailure 'The remote server returned an error: (403) rate limit exceeded.'
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-ThreePartFailure $run.Output
        Assert-Contains $run.Output 'rate limit' 'cause'
        Assert-Equal 0 $run.Delays.Count 'retry delays'
    }

    # --- Scenario Outline: One retry for upload settling -----------------------------------
    Invoke-Case 'retry: first attempt cannot download (HTTP error), second passes -> exit 0 after a 30 s wait' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.sha256' -and $Count -eq 1) { 'The remote server returned an error: (502) Bad Gateway.' } }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Equal 1 $run.Delays.Count 'number of waits'
        Assert-Equal $DefaultRetryDelay $run.Delays[0] 'wait in seconds'
        Assert-Contains $run.Output 'in 2 attempt' 'attempt count'
    }

    Invoke-Case 'retry: first attempt cannot download (timeout), second fails again -> exit non-zero, says a re-run may help' {
        $fixture = New-ReleaseFixture
        $api = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.zip') { 'The operation has timed out.' } }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-ThreePartFailure $run.Output
        Assert-Contains $run.Output 'timed out' 'cause'
        Assert-Contains $run.Output 'A re-run may help' 're-run advice'
        Assert-Equal 1 $run.Delays.Count 'exactly one retry'
        Assert-Equal 2 $api.State.Downloads['teststand-mcp.zip'] 'zip request count (no third attempt)'
    }

    Invoke-Case 'retry: first attempt cannot download, second downloads but the hash differs -> exit non-zero naming the hash' {
        $fixture = New-ReleaseFixture
        Write-TextFile (Join-Path $fixture.Dir 'teststand-mcp.sha256') (('0' * 64) + '  teststand-mcp.zip' + "`n")
        $api = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.manifest.sha256' -and $Count -eq 1) { 'timeout' } }
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'does not match teststand-mcp.sha256' 'fault'
        Assert-Equal 1 $run.Delays.Count 'exactly one retry'
    }

    Invoke-Case 'retry: downloads but the hash differs on the first attempt -> exit non-zero WITHOUT retrying' {
        $fixture = New-ReleaseFixture
        Write-TextFile (Join-Path $fixture.Dir 'teststand-mcp.sha256') (('0' * 64) + '  teststand-mcp.zip' + "`n")
        $api = New-FakeApi $fixture
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'does not match teststand-mcp.sha256' 'fault'
        Assert-Contains $run.Output $RerunWillNotHelp 're-run advice'
        Assert-Equal 0 $run.Delays.Count 'no wait'
        Assert-Equal 1 $api.State.Downloads['teststand-mcp.zip'] 'zip downloaded once'
    }

    Invoke-Case 'retry: a missing asset is not retried either' {
        $fixture = New-ReleaseFixture
        $listJson = New-ReleaseJsonText -Tag $fixture.Tag -AssetNames @('teststand-mcp.zip', 'teststand-mcp.sha256', 'teststand-mcp-v1.9.0.zip')
        $api = New-FakeApi $fixture -ListedJson $listJson
        $run = Invoke-ApiVerify $fixture $api
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-Contains $run.Output 'teststand-mcp.manifest.sha256 is missing from the release' 'fault'
        Assert-Equal 0 $run.Delays.Count 'no wait'
    }

    # --- Own-downloads record from the verifier ----------------------------------------------
    Invoke-Case 'own-downloads: verify + retry + final fetch count 3 for the zip and equal the shared fixture' {
        $fixture = New-ReleaseFixture
        $recordPath = Join-Path (New-TempDir) 'own-downloads.json'
        $api = New-FakeApi $fixture -Plan { param($Name, $Count) if ($Name -eq 'teststand-mcp.sha256' -and $Count -eq 1) { 'The remote server returned an error: (502) Bad Gateway.' } }
        $dateBefore = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        Use-EnvironmentVariable 'GITHUB_RUN_ID' '1234567890' {
            $script:VerifyRun = Invoke-ApiVerify $fixture $api -OwnDownloadsPath $recordPath
            # the workflow's last step: the public fetch of the fixed zip
            Add-OwnDownload -Path $recordPath -AssetName $ReleaseArchiveName
        }
        $dateAfter = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        Assert-Equal 0 $script:VerifyRun.ExitCode "exit code. Output was:`n$($script:VerifyRun.Output)"
        $record = Read-OwnDownloads -Path $recordPath
        $expected = Read-OwnDownloads -Path $OwnDownloadsFixturePath
        Assert-Equal 3 $record.Assets['teststand-mcp.zip'] 'zip downloads'
        Assert-Equal $expected.RunId $record.RunId 'run_id'
        Assert-True (($record.Date -ceq $dateBefore) -or ($record.Date -ceq $dateAfter)) "date $($record.Date) is not today"
        Assert-Equal $expected.Draft $record.Draft 'draft'
        Assert-Equal (($expected.Assets.Keys | Sort-Object) -join ',') (($record.Assets.Keys | Sort-Object) -join ',') 'asset names'
        foreach ($name in $expected.Assets.Keys) { Assert-Equal $expected.Assets[$name] $record.Assets[$name] "count of $name" }
    }

    Invoke-Case 'own-downloads: without -Draft the verifier records draft false; local mode records nothing' {
        $fixture = New-ReleaseFixture
        $recordPath = Join-Path (New-TempDir) 'own-downloads.json'
        Use-EnvironmentVariable 'GITHUB_RUN_ID' '55' {
            [void](Invoke-ApiVerify $fixture (New-FakeApi $fixture) -OwnDownloadsPath $recordPath -Extra @{ Draft = $false })
        }
        Assert-Equal $false (Read-OwnDownloads -Path $recordPath).Draft 'draft flag'
        $localRecord = Join-Path (New-TempDir) 'local-downloads.json'
        [void](Invoke-LocalVerify (New-ReleaseFixture) -Extra @{ OwnDownloadsPath = $localRecord })
        Assert-True (-not (Test-Path -LiteralPath $localRecord)) 'local mode must not create a download record'
    }

    # --- Every failing script run, anywhere above, has the three parts -------------------------
    Invoke-Case 'every failing run of every build script prints What, Why and Fix' {
        Assert-True ($script:FailedRuns.Count -ge 20) "expected at least 20 failing runs to check, found $($script:FailedRuns.Count)"
        foreach ($failed in $script:FailedRuns) {
            try { Assert-ThreePartFailure $failed.Output } catch { throw "$($failed.Script): $($_.Exception.Message)" }
        }
    }

    # --- Scenario: The existing hand-cut release is recognised (manual, needs network) -------------
    # Not part of this file: no network in tests. Run by hand:
    #   powershell -File build\Assert-PublishedRelease.ps1 -Repo Zuehlke/teststand-mcp -Tag v1.8.6
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
