# ============================================================================
#  ReleaseAssets.psm1 - the release asset contract, shared by every build script:
#    - asset names, the repository slug and the "latest download" URL;
#    - the release-tag format rule and its diagnosis texts (ONE map);
#    - the archive digest (sha256sum -c format) and the per-file manifest;
#    - the own-downloads record (what this repository's workflows downloaded),
#      which the stats collector subtracts from the public download counts;
#    - Write-BuildFailure, the one way a build script reports a failure.
#  Compatible with Windows PowerShell 5.1 and PowerShell 7.
#  Files are written with explicit .NET UTF-8 (no BOM) APIs: never use
#  Set-Content -Encoding UTF8 here (5.1 writes a BOM).
# ============================================================================
Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ----------------------------------------------------------------------------
#  Asset contract (exported variables)
# ----------------------------------------------------------------------------
$ReleaseRepoSlug = 'Zuehlke/teststand-mcp'
$ReleaseArchiveName = 'teststand-mcp.zip'
$ReleaseDigestName = 'teststand-mcp.sha256'
$ReleaseManifestName = 'teststand-mcp.manifest.sha256'

$script:VersionedArchiveFormat = 'teststand-mcp-v{0}.zip'
$script:LatestDownloadUrlFormat = 'https://github.com/{0}/releases/latest/download/{1}'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-VersionedArchiveName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)
    return ($script:VersionedArchiveFormat -f $Version)
}

# Download order: the fixed zip first (every other check needs it), the small digest and
# manifest next, and the second full-size zip last so a cheap fault stops the run before it.
function Get-RequiredAssetNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)
    return @($ReleaseArchiveName, $ReleaseDigestName, $ReleaseManifestName, (Get-VersionedArchiveName -Version $Version))
}

function Get-LatestDownloadUrl {
    [CmdletBinding()]
    param([string]$AssetName = $ReleaseArchiveName)
    return ($script:LatestDownloadUrlFormat -f $ReleaseRepoSlug, $AssetName)
}

# ----------------------------------------------------------------------------
#  Failure reporting
# ----------------------------------------------------------------------------
function Format-BuildFailure {
    param([string]$What, [string]$Why, [string]$Fix)
    $continuationIndent = ' ' * 6   # lines up under the text after "Fix:  "
    $format = {
        param([string]$Label, [string]$Text)
        $lines = @($Text -split '\r?\n')
        $first = ('{0,-6}' -f ($Label + ':')) + $lines[0]
        $rest = @($lines | Select-Object -Skip 1 | ForEach-Object { $continuationIndent + $_ })
        return (@($first) + $rest) -join "`n"
    }
    return ((& $format 'What' $What), (& $format 'Why' $Why), (& $format 'Fix' $Fix)) -join "`n"
}

# Every failure of every build script has three parts: what failed, why it matters
# (including whether a re-run can help), and how to fix it. An empty part is refused,
# so no failure can ship without one. Throws; the calling script prints the message
# and exits non-zero.
function Write-BuildFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$What,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Why,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Fix
    )
    throw (Format-BuildFailure -What $What -Why $Why -Fix $Fix)
}

# What a script prints for a caught error: a Write-BuildFailure message as it is, anything else
# wrapped into the same three parts so even a bug in a script never prints a bare exception.
function Get-ScriptFailureText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)
    $message = $ErrorRecord.Exception.Message
    if ($message -cmatch '\AWhat: ') { return $message }
    return Format-BuildFailure -What "Unexpected error: $message" `
        -Why 'The script hit a problem it does not handle itself, so it reached no verdict. A re-run may help only if the cause is transient.' `
        -Fix ("Re-run it; if it repeats, report it with this output.`n" + $ErrorRecord.ScriptStackTrace)
}

# ----------------------------------------------------------------------------
#  Hashing
# ----------------------------------------------------------------------------
function ConvertTo-HexString {
    param([byte[]]$Bytes)
    return ([BitConverter]::ToString($Bytes)).Replace('-', '').ToLowerInvariant()
}

function Get-StreamSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-HexString $sha.ComputeHash($Stream)) } finally { $sha.Dispose() }
}

function Get-FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try { return (Get-StreamSha256 $stream) } finally { $stream.Dispose() }
}

# ----------------------------------------------------------------------------
#  Release tag: ONE ordered rule map. The first rule whose pattern matches names
#  the problem; a rule with a Candidate script also offers the unambiguous fix.
#  [0-9] and \A..\z on purpose: \d matches non-ASCII digits and $ matches before a final newline.
# ----------------------------------------------------------------------------
$script:ValidTagPattern = '\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z'
$script:TagFormatReason = 'Release tags must be exactly v<major>.<minor>.<patch>: a lower-case v and three numbers without leading zeros. ' +
    'The release workflow, the asset name teststand-mcp-vX.Y.Z.zip and the version stamped into the plugin all derive from the tag.'

$script:TagRules = @(
    @{ Label = 'empty';             Pattern = '\A\s*\z';                           Why = 'The tag name is empty.' }
    @{ Label = 'upper-case V';      Pattern = '\AV[0-9]';                          Why = "The tag starts with an upper-case 'V'. GitHub's v* tag filter is case-sensitive, so only the all-tags trigger sees it.";
                                    Candidate = { param($Tag) 'v' + $Tag.Substring(1) } }
    @{ Label = 'no v';              Pattern = '\A[0-9]';                           Why = "The tag has no leading 'v'.";
                                    Candidate = { param($Tag) 'v' + $Tag } }
    @{ Label = 'two components';    Pattern = '\Av[0-9]+\.[0-9]+\z';               Why = 'The tag has two numeric components; three are required.' }
    @{ Label = 'four components';   Pattern = '\Av[0-9]+(\.[0-9]+){3,}\z';         Why = 'The tag has more than three numeric components; exactly three are required.' }
    @{ Label = 'suffix';            Pattern = '\Av[0-9]+\.[0-9]+\.[0-9]+[^0-9]';   Why = 'The tag has a suffix after the three numbers (for example -rc); none is allowed.' }
    @{ Label = 'leading zero';      Pattern = '\Av[0-9]+\.[0-9]+\.[0-9]+\z';       Why = 'A number in the tag has a leading zero; write 1, not 01.' }
    @{ Label = 'not a version';     Pattern = '(?s)\A.*\z';                        Why = 'The tag does not look like a version at all.' }
)

# Control characters never reach the output (the tag is user input).
function Get-PrintableTag {
    param([string]$Tag)
    return [regex]::Replace($Tag, '[\x00-\x1f\x7f]', '?')
}

# Words made of safe characters stay bare; anything else is single-quoted.
function Format-ShellArgument {
    param([string]$Text)
    if ([regex]::IsMatch($Text, '\A[A-Za-z0-9._/+-]+\z')) { return $Text }
    return "'" + $Text.Replace("'", "''") + "'"
}

function ConvertFrom-ReleaseTag {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Tag)

    if ($null -eq $Tag) { $Tag = '' }
    $match = [regex]::Match($Tag, $script:ValidTagPattern)
    if ($match.Success) {
        $version = $Tag.Substring(1)
        return [pscustomobject]@{
            Tag = $Tag; Valid = $true; Version = $version; Verdict = "valid, version $version"
            Label = $null; Why = $null; SuggestedTag = $null
        }
    }

    $rule = $script:TagRules | Where-Object { [regex]::IsMatch($Tag, $_.Pattern) } | Select-Object -First 1
    $suggested = $null
    if ($rule.ContainsKey('Candidate')) {
        $candidate = & $rule.Candidate $Tag
        if ([regex]::IsMatch($candidate, $script:ValidTagPattern)) { $suggested = $candidate }   # never invent a version
    }
    return [pscustomobject]@{
        Tag = $Tag; Valid = $false; Version = $null; Verdict = "rejected: $($rule.Label)"
        Label = $rule.Label; Why = $rule.Why; SuggestedTag = $suggested
    }
}

function Format-NumberedSteps {
    param([string[]]$Steps)
    return ((1..$Steps.Count | ForEach-Object { "  $_. $($Steps[$_ - 1])" }) -join "`n")
}

# The What/Why/Fix of a rejected tag (splat into Write-BuildFailure).
function Get-TagRejection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result, [string]$Commit)

    $shownTag = Get-PrintableTag $Result.Tag
    $badTag = Format-ShellArgument $shownTag
    $deleteCommands = @("git push --delete origin $badTag", "git tag -d $badTag")

    if ($null -ne $Result.SuggestedTag) {
        $commitNote = ''
        if (-not [regex]::IsMatch([string]$Commit, '\A[0-9a-f]{40}\z')) {
            $Commit = 'HEAD'
            $commitNote = "`nHEAD assumes the bad tag pointed at the commit you have checked out; confirm with 'git rev-list -n 1 $badTag' BEFORE deleting it."
        }
        $good = $Result.SuggestedTag
        $steps = $deleteCommands + @("git tag $good $Commit", "git push origin $good")
        $fix = "Retag in this order (delete the remote tag, delete the local tag, create the new tag, push it):`n" +
            (Format-NumberedSteps $steps) + $commitNote
    } else {
        $fix = "Choose the version you mean and write it as vX.Y.Z; this script does not guess one. First remove the bad tag (remote first):`n" +
            (Format-NumberedSteps $deleteCommands) +
            "`nThen tag the commit with your chosen vX.Y.Z and push that tag."
    }

    return @{
        What = "The tag '$shownTag' cannot be released ($($Result.Verdict))."
        Why  = "$($Result.Why) $script:TagFormatReason No asset was built or published."
        Fix  = $fix
    }
}

# ----------------------------------------------------------------------------
#  Digest and manifest
# ----------------------------------------------------------------------------
$script:HashLinePattern = '\A([0-9a-f]{64})  (\S.*)\z'   # sha256sum text mode: hash, two spaces, name

# "<hash>  <name>" + LF: what `sha256sum -c` reads when run next to the archive.
function New-ArchiveDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchivePath, [string]$Name)
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        Write-BuildFailure -What "Cannot compute the digest: $ArchivePath does not exist." `
            -Why 'The digest is written next to the archive it describes.' -Fix 'Build the archive first, then pass its path.'
    }
    if ([string]::IsNullOrEmpty($Name)) { $Name = Split-Path -Leaf $ArchivePath }
    return ((Get-FileSha256 $ArchivePath) + '  ' + $Name + "`n")
}

# The text of a digest or manifest as an ordered path -> hash table. Throws a plain string on a bad line.
function ConvertFrom-HashLines {
    param([AllowEmptyString()][string]$Text)
    $entries = [ordered]@{}
    $lineNumber = 0
    foreach ($line in ($Text -split "\n")) {
        $lineNumber++
        $line = $line.TrimEnd("`r")
        if ($line.Length -eq 0) { continue }
        $match = [regex]::Match($line, $script:HashLinePattern)
        if (-not $match.Success) { throw "line $lineNumber is not '<64 hex digits>  <path>'" }
        if ($entries.Contains($match.Groups[2].Value)) { throw "line $lineNumber repeats the path '$($match.Groups[2].Value)'" }
        $entries[$match.Groups[2].Value] = $match.Groups[1].Value
    }
    return $entries
}

function ConvertFrom-DigestText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    $entries = ConvertFrom-HashLines $Text
    if ($entries.Count -ne 1) { throw "a digest holds exactly one '<hash>  <name>' line but this one holds $($entries.Count)" }
    $name = @($entries.Keys)[0]
    return [pscustomobject]@{ Name = $name; Hash = $entries[$name] }
}

# One "<hash>  <relative/forward/slash/path>" line per file of the staged tree, ordinal-sorted.
function New-ArchiveManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StagedDir)
    if (-not (Test-Path -LiteralPath $StagedDir -PathType Container)) {
        Write-BuildFailure -What "Cannot build the manifest: $StagedDir is not a directory." `
            -Why 'The manifest lists every file of the staged tree that becomes the archive.' -Fix 'Stage the plugin first, then pass the staging directory.'
    }
    $root = [IO.Path]::GetFullPath($StagedDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in (Get-ChildItem -LiteralPath $StagedDir -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($root.Length).Replace('\', '/')
        $lines.Add((Get-FileSha256 $file.FullName) + '  ' + $relative)
    }
    if ($lines.Count -eq 0) {
        Write-BuildFailure -What "Cannot build the manifest: $StagedDir holds no files." `
            -Why 'An empty manifest would pass any archive.' -Fix 'Check that the staging step copied the plugin files.'
    }
    # Ordinal order of the PATH part, so the manifest is the same on every machine.
    $hashLines = [string[]]$lines.ToArray()
    $paths = [string[]]@($hashLines | ForEach-Object { $_.Substring(66) })
    [Array]::Sort($paths, $hashLines, [StringComparer]::Ordinal)
    return (($hashLines -join "`n") + "`n")
}

# Compares the entries of a zip with a manifest. Returns one problem object per difference
# (Kind, Path, Detail); an empty result means they agree.
function Test-ArchiveManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][AllowEmptyString()][string]$ManifestText)

    $problems = New-Object System.Collections.Generic.List[object]
    try {
        $expected = ConvertFrom-HashLines $ManifestText
    } catch {
        return @([pscustomobject]@{ Kind = 'manifest-malformed'; Path = ''; Detail = $_.Exception.Message })
    }
    if ($expected.Count -eq 0) {
        return @([pscustomobject]@{ Kind = 'manifest-malformed'; Path = ''; Detail = 'the manifest lists no files' })
    }

    $actual = @{}
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }   # directory entry
            $stream = $entry.Open()
            try { $actual[$entry.FullName] = Get-StreamSha256 $stream } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }

    foreach ($path in $expected.Keys) {
        if (-not $actual.ContainsKey($path)) {
            $problems.Add([pscustomobject]@{ Kind = 'entry-missing-from-archive'; Path = $path; Detail = 'the manifest lists it but the archive has no such entry' })
        } elseif ($actual[$path] -cne $expected[$path]) {
            $problems.Add([pscustomobject]@{ Kind = 'hash-mismatch'; Path = $path; Detail = "manifest $($expected[$path]) but archive $($actual[$path])" })
        }
    }
    foreach ($path in $actual.Keys) {
        if (-not $expected.Contains($path)) {
            $detail = 'the archive has the entry but the manifest does not list it'
            if ($path.Contains('\')) { $detail += " (the entry name uses backslashes; zip entry names must use '/')" }
            $problems.Add([pscustomobject]@{ Kind = 'entry-not-in-manifest'; Path = $path; Detail = $detail })
        }
    }
    return @($problems | Sort-Object -Property Path, Kind)
}

# ----------------------------------------------------------------------------
#  Own-downloads record: what THIS repository's workflows downloaded.
#  { "run_id": "...", "date": "YYYY-MM-DD", "assets": { "<asset>": n }, "draft": true|false }
#  "draft" is true as soon as one draft-phase download was recorded: the stats
#  collector decides whether draft downloads count at all (spec AC-18).
# ----------------------------------------------------------------------------
$script:OwnDownloadsDateFormat = 'yyyy-MM-dd'

function Read-OwnDownloads {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $fail = {
        param($Reason)
        Write-BuildFailure -What "The own-downloads record $Path is unusable: $Reason." `
            -Why 'The stats collector subtracts these counts from the public download counts, so a wrong record skews the install numbers.' `
            -Fix 'Delete the file and let the workflow run write a fresh one.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { & $fail 'the file does not exist' }
    try { $json = [IO.File]::ReadAllText($Path, $script:Utf8NoBom) | ConvertFrom-Json } catch { & $fail "it is not valid JSON ($($_.Exception.Message))" }
    foreach ($key in @('run_id', 'date', 'assets', 'draft')) {
        if ($null -eq $json -or $null -eq $json.PSObject.Properties[$key]) { & $fail "the key '$key' is missing" }
    }
    $assets = [ordered]@{}
    foreach ($property in $json.assets.PSObject.Properties) { $assets[$property.Name] = [int]$property.Value }
    return [pscustomobject]@{ RunId = [string]$json.run_id; Date = [string]$json.date; Assets = $assets; Draft = [bool]$json.draft }
}

function Save-OwnDownloads {
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $document = [ordered]@{ run_id = $Record.RunId; date = $Record.Date; assets = $Record.Assets; draft = $Record.Draft }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), ((ConvertTo-Json -InputObject $document -Depth 4) + "`n"), $script:Utf8NoBom)
}

# Counts one download of one asset. Call it for every download a workflow makes, before the request.
function Add-OwnDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AssetName,
        [string]$RunId = $env:GITHUB_RUN_ID,
        [string]$Date = [DateTime]::UtcNow.ToString($script:OwnDownloadsDateFormat),
        [switch]$Draft
    )
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        Write-BuildFailure -What 'Cannot record a download: no run id.' `
            -Why 'Each record belongs to one workflow run so the collector can match it to that run.' `
            -Fix 'Pass -RunId, or run inside GitHub Actions where GITHUB_RUN_ID is set.'
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $record = Read-OwnDownloads -Path $Path
        if ($record.RunId -cne $RunId) {
            Write-BuildFailure -What "Cannot record a download: $Path already belongs to run $($record.RunId), not run $RunId." `
                -Why 'Mixing runs in one record would make the per-run counts wrong.' `
                -Fix 'Use one own-downloads file per workflow run.'
        }
    } else {
        $record = [pscustomobject]@{ RunId = $RunId; Date = $Date; Assets = [ordered]@{}; Draft = $false }
    }
    $count = 0
    if ($record.Assets.Contains($AssetName)) { $count = $record.Assets[$AssetName] }
    $record.Assets[$AssetName] = $count + 1
    $record.Draft = $record.Draft -or [bool]$Draft
    Save-OwnDownloads -Record $record -Path $Path
}

Export-ModuleMember -Variable ReleaseRepoSlug, ReleaseArchiveName, ReleaseDigestName, ReleaseManifestName
Export-ModuleMember -Function Get-VersionedArchiveName, Get-RequiredAssetNames, Get-LatestDownloadUrl,
    Write-BuildFailure, Format-BuildFailure, Get-ScriptFailureText, Get-FileSha256, Get-StreamSha256,
    ConvertFrom-ReleaseTag, Get-TagRejection,
    New-ArchiveDigest, ConvertFrom-DigestText, New-ArchiveManifest, Test-ArchiveManifest,
    Read-OwnDownloads, Add-OwnDownload
