# ============================================================================
#  PluginStaging.psm1 - the archive's directory tree: how it is staged and how it is checked.
#  ONE table (Get-StagingTable) describes every file and directory of the archive, and that same
#  table drives BOTH the staging (what is copied or generated) and the assertions (what must be
#  there, what may not be, what must equal its source). Generated outputs (the stamped plugin.json,
#  VERSION.txt, the plugin agents, bin/CLAUDE.md) are rows of the table too, with a Generated column
#  naming their generator; each generator has a writer and its own assertion ($script:Generators).
#
#  A row (New-StagingEntry):
#    Path          the file or directory inside the archive ('.' is the archive root);
#    Kind          Dir or File;
#    Source        where its files come from: a repository folder, $PublishSource, or $null;
#    Copy          $CopyAll (every file below Source), $CopyListed (just the names in Exact), $CopyNone;
#    TrackedOnly   copy only files git tracks (and refuse untracked or ignored ones below Source);
#    Exclude / ExcludePattern   top-level names and wildcards that are not copied;
#    Generated     the generator that writes the file or directory;
#    SameContentAs every staged file equals the source file of the same name, byte for byte;
#    Required / Forbidden / Exact   file names that must exist / must not exist (wildcards) / are the whole set;
#    ExactTopLevel the top-level entries are exactly the derived expected set;
#    Why / Fix     what a violation means and the concrete change that repairs it.
#  Compatible with Windows PowerShell 5.1 and PowerShell 7. ASCII only.
# ============================================================================
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'SkillSources.psm1')
Import-Module (Join-Path $PSScriptRoot 'PluginIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot 'ReleaseAssets.psm1')

$script:CopyAll = 'All'
$script:CopyListed = 'Listed'
$script:CopyNone = 'None'
$script:PublishSource = ':publish'
$script:ExeName = 'TestStandMCP.exe'
$script:GitTimeoutSeconds = 60

# ----------------------------------------------------------------------------
#  The ONE path table. Repository paths are relative to the repository root, archive paths to the
#  archive root; both use forward slashes.
# ----------------------------------------------------------------------------
$script:Paths = @{
    PluginDir    = 'plugin'
    SourceAgents = '.claude/agents'
    DocScripts   = 'scripts'
    Root         = '.'
    Manifest     = '.claude-plugin/plugin.json'
    McpJson      = '.mcp.json'
    VersionTxt   = 'VERSION.txt'
    Agents       = 'agents'
    Hooks        = 'hooks'
    Bin          = 'bin'
    BinClaudeMd  = 'bin/CLAUDE.md'
    BinScripts   = 'bin/scripts'
    BinAgents    = 'bin/.claude/agents'
    SkillMd      = "skills/$SkillName/SKILL.md"
}
$script:HookFiles = @('allow-readonly.ps1', 'hook-common.ps1', 'hooks.json', 'platform-guard.ps1', 'tool-classes.json', 'update-notify.ps1')
$script:DocScriptFiles = @('generate_teststand_doc.py', 'generate_teststand_presentation.py', 'presentation_template.html')
# What the csproj copies into every publish output but the archive takes from the repository instead
# (or not at all): the rules file, the README, the maintainer scripts and the agent folder.
$script:BinCopyExclude = @('CLAUDE.md', 'README.md', 'scripts', '.claude')
# Debug symbols stay out: they carry the build machine's source paths, and nothing at run time needs them.
$script:BinExcludePattern = @('*.pdb')
$script:BinForbiddenPaths = @('README.md', 'build/*', '*.pdb')
$script:ClaudeMdHeader = "# TestStand MCP rules (generated from the $SkillName skill; do not edit)"

function Get-PublishedExePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PublishDir)
    return Join-Path $PublishDir $script:ExeName
}

function Get-StagedExePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StageDir)
    return Join-Path (Join-Path $StageDir $script:Paths.Bin) $script:ExeName
}

# ----------------------------------------------------------------------------
#  Git: the plugin folder ships only what is tracked
# ----------------------------------------------------------------------------
function Get-GitPathList {
    param([string]$RepoRoot, [string[]]$GitArguments, [string]$Pathspec)
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-BuildFailure -What 'git was not found on the PATH.' -Why 'The archive stages only files git tracks, so it needs git to list them.' -Fix 'Install Git for Windows and open a new shell.'
    }
    $result = Invoke-ChildProcess -FilePath $git.Source -TimeoutSeconds $script:GitTimeoutSeconds `
        -ArgumentList (@('-c', 'core.quotePath=off', '-C', $RepoRoot) + $GitArguments + @('--', $Pathspec))
    Assert-ChildOutcome -Result $result -Name "git $($GitArguments -join ' ')" -TimeoutSeconds $script:GitTimeoutSeconds `
        -Why 'The archive stages only files git tracks; without the list nothing can be staged.' `
        -Fix "Run it by hand in ${RepoRoot}: git $($GitArguments -join ' ') -- $Pathspec (the folder must be inside a git checkout)."
    return @($result.Stdout -split "`0" | Where-Object { $_ })
}

# The tracked files below $Dir (a repository-relative folder), named relative to it.
function Get-TrackedFileList {
    param([string]$RepoRoot, [string]$Dir)
    $prefix = $Dir.TrimEnd('/') + '/'
    $tracked = @(Get-GitPathList -RepoRoot $RepoRoot -GitArguments @('ls-files', '-z') -Pathspec $Dir)
    return [string[]]@($tracked | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } | ForEach-Object { $_.Substring($prefix.Length) })
}

# Fails when the folder holds a file git does not track or ignores: it would ship unreviewed, or
# (when only the working tree has it) make the archive differ from the commit.
function Assert-FolderTracked {
    param([string]$RepoRoot, [string]$Dir)
    $untracked = @(Get-GitPathList -RepoRoot $RepoRoot -GitArguments @('ls-files', '-z', '--others', '--exclude-standard') -Pathspec $Dir)
    $ignored = @(Get-GitPathList -RepoRoot $RepoRoot -GitArguments @('ls-files', '-z', '--others', '--ignored', '--exclude-standard') -Pathspec $Dir)
    $stray = @($untracked + $ignored)
    if ($stray.Count -eq 0) { return }
    Write-BuildFailure -What "$Dir holds $($stray.Count) file(s) git does not track: $(($stray | Select-Object -First 5) -join ', ')" `
        -Why 'The archive is built from the commit; a file that exists only in this working folder (untracked or ignored) would ship unreviewed and could not be rebuilt by the release workflow.' `
        -Fix "Commit the file (git add $Dir; git commit), or delete it."
}

# ----------------------------------------------------------------------------
#  Selecting files
# ----------------------------------------------------------------------------
# $Names without the excluded top-level names and wildcards; with $Only, just those names.
function Select-StagedFile {
    param([string[]]$Names, [string[]]$Exclude = @(), [string[]]$ExcludePattern = @(), [string[]]$Only = $null)
    return [string[]]@($Names | Where-Object {
        $name = $_
        ($Exclude -notcontains ($name -split '/')[0]) -and
        (@($ExcludePattern | Where-Object { $name -like $_ }).Count -eq 0) -and
        ($null -eq $Only -or $Only -ccontains $name)
    })
}

function Get-FirstSegment {
    param([string]$Name)
    return ($Name -split '/')[0]
}

# ----------------------------------------------------------------------------
#  The staging table
# ----------------------------------------------------------------------------
function New-StagingEntry {
    param(
        [Parameter(Mandatory)][string]$Path, [ValidateSet('Dir', 'File')][string]$Kind = 'Dir', $Source = $null,
        [ValidateSet('All', 'Listed', 'None')][string]$Copy = 'None', [switch]$TrackedOnly,
        [string[]]$Exclude = @(), [string[]]$ExcludePattern = @(), [string]$Generated = '', [switch]$SameContentAs,
        [string[]]$Required = @(), [string[]]$Forbidden = @(), $Exact = $null, [switch]$ExactTopLevel,
        [string]$Why = '', [string]$Fix = ''
    )
    return [pscustomobject]@{
        Path = $Path; Kind = $Kind; Source = $Source; Copy = $Copy; TrackedOnly = [bool]$TrackedOnly
        Exclude = $Exclude; ExcludePattern = $ExcludePattern; Generated = $Generated; SameContentAs = [bool]$SameContentAs
        Required = $Required; Forbidden = $Forbidden; Exact = $Exact; ExactTopLevel = [bool]$ExactTopLevel; Why = $Why; Fix = $Fix
    }
}

# $Layout: the layout settings (BinRequired, BinForbidden) of PluginArchive's layout table.
function Get-StagingTable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$PublishDir)
    $p = $script:Paths
    $agentDir = Join-Path $RepoRoot $p.SourceAgents
    $sourceAgents = [string[]]@(Get-ChildItem -LiteralPath $agentDir -File -Filter '*.md' | ForEach-Object { $_.Name } | Sort-Object { $_ })
    return @(
        (New-StagingEntry -Path $p.Root -Source $p.PluginDir -Copy $script:CopyAll -TrackedOnly -ExactTopLevel -Required @($p.McpJson, $p.SkillMd) `
            -Why 'The archive layout requires it (spec AC-4), and nothing else may sit at the archive root; without the required files Claude Code cannot load the plugin or start its server.' `
            -Fix "Restore the file below plugin/ (git checkout -- plugin), or add a deliberate new top-level folder as a row of Get-StagingTable in build\PluginStaging.psm1."),
        (New-StagingEntry -Path $p.Manifest -Kind File -Generated 'Manifest' `
            -Why 'Claude Code takes the plugin version from plugin.json (docs/validation/claude-code-plugin-facts.md, fact 2).' `
            -Fix 'Fix the "version": "0.0.0" placeholder in plugin/.claude-plugin/plugin.json; the staged copy is written by Write-StampedManifest in build\PluginStaging.psm1.'),
        (New-StagingEntry -Path $p.VersionTxt -Kind File -Generated 'VersionTxt' `
            -Why '--version prints VERSION.txt, and the exe reports "release metadata incomplete" without it.' `
            -Fix 'Never edit VERSION.txt; it is written by Write-VersionTxt in build\PluginStaging.psm1 from the -Version, -Tag and -Commit of Build-PluginArchive.ps1.'),
        (New-StagingEntry -Path $p.Hooks -Exact $script:HookFiles `
            -Why 'hooks/ is what Claude Code runs on the user''s machine on every session start and tool call. It must hold exactly the runtime hook files, never a test, a build script or a leftover.' `
            -Fix 'Remove the unexpected file from plugin/hooks, or add a new runtime hook to $script:HookFiles in build\PluginStaging.psm1; restore a missing one with git checkout -- plugin/hooks.'),
        (New-StagingEntry -Path $p.Agents -Generated 'Agents' -Exact $sourceAgents `
            -Why 'The plugin ships one converted agent per source agent (spec AC-5); a different number means an agent was dropped or one was added without a source.' `
            -Fix 'Fix the source folder .claude/agents (the plugin agents are generated from it by Write-PluginAgents in build\PluginStaging.psm1), never agents/.'),
        (New-StagingEntry -Path $p.Bin -Source $script:PublishSource -Copy $script:CopyAll -Exclude $script:BinCopyExclude -ExcludePattern $script:BinExcludePattern -ExactTopLevel `
            -Required (@($script:ExeName, 'appsettings.json') + @($Layout.BinRequired)) -Forbidden (@($Layout.BinForbidden) + $script:BinForbiddenPaths) `
            -Why 'bin/ is the exe and its runtime files for the chosen layout (spec AC-4): a missing runtime file does not start on the user''s station, and anything that dotnet publish did not produce (a README, a build script, debug symbols) is not part of the release.' `
            -Fix 'Compare the dotnet publish output with the layout table in build\PluginArchive.psm1, and with what TestStandMCP.csproj copies to the output (the drift test in BuildPluginArchive.Tests.ps1 names every top-level name).'),
        (New-StagingEntry -Path $p.BinClaudeMd -Kind File -Generated 'ClaudeMd' `
            -Why 'The direct installation route reads its rules from bin/CLAUDE.md: the user rules of the skill and nothing else (spec AC-4).' `
            -Fix 'Never edit bin/CLAUDE.md; New-ClaudeMdText in build\PluginStaging.psm1 generates it from plugin/skills and the import order of CLAUDE.md.'),
        (New-StagingEntry -Path $p.BinScripts -Source $p.DocScripts -Copy $script:CopyListed -Exact $script:DocScriptFiles `
            -Why 'The archive ships only the documentation and presentation generators and their template. A maintainer script would run from a user''s installation and expose paths nobody should depend on.' `
            -Fix 'Remove the unexpected file from the staged tree, or add a generator deliberately to $script:DocScriptFiles in build\PluginStaging.psm1.'),
        (New-StagingEntry -Path $p.BinAgents -Source $p.SourceAgents -Copy $script:CopyAll -SameContentAs -Required @('link-agents.bat') -Exact (Get-RelativeFileList $agentDir) `
            -Why 'The direct installation route (link-agents.bat) needs the source agents unchanged next to the exe (spec AC-5).' `
            -Fix 'Restore the folder .claude/agents (git checkout -- .claude/agents) and package again; bin/.claude/agents is a plain copy of it.')
    )
}

# The files a table row stages from its Source: { Dir; Names }.
function Get-EntrySourceFile {
    param($Entry, $Context)
    $dir = if ($Entry.Source -ceq $script:PublishSource) { $Context.PublishDir } else { Join-Path $Context.RepoRoot $Entry.Source }
    $names = if ($Entry.TrackedOnly) { Get-TrackedFileList -RepoRoot $Context.RepoRoot -Dir $Entry.Source } else { Get-RelativeFileList $dir }
    $only = if ($Entry.Copy -ceq $script:CopyListed) { [string[]]$Entry.Exact } else { $null }
    return [pscustomobject]@{ Dir = $dir; Names = (Select-StagedFile -Names $names -Exclude $Entry.Exclude -ExcludePattern $Entry.ExcludePattern -Only $only) }
}

# ----------------------------------------------------------------------------
#  Generator: plugin.json (the committed text with ONLY the placeholder's value replaced)
# ----------------------------------------------------------------------------
# A file's bytes read as ISO-8859-1: one char per byte, so a text edit can never change another byte.
$script:ByteTextEncoding = [Text.Encoding]::GetEncoding(28591)
$script:VersionPlaceholderPattern = '"version"\s*:\s*"0\.0\.0"'

# The single placeholder match in the manifest text; fails when there is none or more than one.
function Find-VersionPlaceholder {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Path)
    $found = @([regex]::Matches($Text, $script:VersionPlaceholderPattern))
    if ($found.Count -ne 1) {
        Write-BuildFailure -What "$Path holds $($found.Count) occurrences of `"version`": `"0.0.0`" instead of exactly one." `
            -Why 'The build replaces that placeholder with the release version. Without it the stamped manifest could not be proven identical to the source apart from the version, and a hand-edited version would ship unchanged.' `
            -Fix 'Restore the committed manifest: git checkout -- plugin/.claude-plugin/plugin.json (the version stays "0.0.0" in git).'
    }
    return $found[0]
}

# The text with the part [Index, Index + Length) replaced.
function Edit-TextRange {
    param([string]$Text, [int]$Index, [int]$Length, [string]$Replacement)
    return $Text.Remove($Index, $Length).Insert($Index, $Replacement)
}

function Write-StampedManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$DestPath, [Parameter(Mandatory)][string]$Version)
    $text = $script:ByteTextEncoding.GetString([IO.File]::ReadAllBytes($SourcePath))
    $placeholder = Find-VersionPlaceholder -Text $text -Path $SourcePath
    $stamped = $placeholder.Value -replace '"0\.0\.0"\z', ('"' + $Version + '"')
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $DestPath) -Force)
    [IO.File]::WriteAllBytes($DestPath, $script:ByteTextEncoding.GetBytes((Edit-TextRange $text $placeholder.Index $placeholder.Length $stamped)))
}

# The staged manifest equals the source byte for byte once its version is put back.
function Assert-StampedManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$StagedPath, [Parameter(Mandatory)][string]$Version)
    $source = $script:ByteTextEncoding.GetString([IO.File]::ReadAllBytes($SourcePath))
    $staged = $script:ByteTextEncoding.GetString([IO.File]::ReadAllBytes($StagedPath))
    $sourceToken = (Find-VersionPlaceholder -Text $source -Path $SourcePath).Value
    $stagedTokens = @([regex]::Matches($staged, '"version"\s*:\s*"' + [regex]::Escape($Version) + '"'))
    $restored = $null
    if ($stagedTokens.Count -eq 1) { $restored = Edit-TextRange $staged $stagedTokens[0].Index $stagedTokens[0].Length $sourceToken }
    if ($null -eq $restored -or -not [string]::Equals($restored, $source, [StringComparison]::Ordinal)) {
        Write-BuildFailure -What "The staged plugin.json is not the source with only `"version`": `"$Version`" changed (it holds $($stagedTokens.Count) such version entries)." `
            -Why 'Claude Code takes the plugin version from plugin.json; a manifest that differs from the reviewed source in anything else would ship an unreviewed change.' `
            -Fix 'Package again with build\Build-PluginArchive.ps1; the manifest is stamped from plugin/.claude-plugin/plugin.json and must not be edited in the staged tree.'
    }
}

# ----------------------------------------------------------------------------
#  Generator: VERSION.txt (key: value lines, the format src/VersionInfo.cs reads)
# ----------------------------------------------------------------------------
$script:VersionTxtKeys = @('tag', 'version', 'commit', 'built', 'run')

function Write-VersionTxt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Values)
    $lines = @($script:VersionTxtKeys | ForEach-Object { "${_}: $($Values[$_])" })
    [IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), (Get-Utf8NoBomEncoding))
}

function Assert-VersionTxt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Expected)
    $values = @{}
    foreach ($line in ((Read-Utf8Text $Path) -split '\r?\n')) {
        $separator = $line.IndexOf(':')
        if ($separator -gt 0) { $values[$line.Substring(0, $separator).Trim()] = $line.Substring($separator + 1).Trim() }
    }
    $missing = @($script:VersionTxtKeys | Where-Object { -not $values.ContainsKey($_) -or $values[$_].Length -eq 0 })
    if ($missing.Count -gt 0) {
        Write-BuildFailure -What "VERSION.txt lacks $($missing -join ', ') (it must carry $($script:VersionTxtKeys -join ', '))." `
            -Why '--version prints these lines, and the exe reports "release metadata incomplete" when the tag is missing.' `
            -Fix 'Never edit VERSION.txt; package again with build\Build-PluginArchive.ps1, which writes it with Write-VersionTxt (build\PluginStaging.psm1).'
    }
    foreach ($key in @('tag', 'version', 'commit')) {
        if (-not [string]::Equals($values[$key], $Expected[$key], [StringComparison]::Ordinal)) {
            Write-BuildFailure -What "VERSION.txt says $key '$($values[$key])' but '$($Expected[$key])' was requested." `
                -Why 'The archive would name a different release than the one being built.' `
                -Fix 'Package again with build\Build-PluginArchive.ps1 and the -Version, -Tag and -Commit you mean.'
        }
    }
}

# ----------------------------------------------------------------------------
#  Generator: the plugin flavour of every source agent (spec AC-5)
# ----------------------------------------------------------------------------
function Write-PluginAgents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceDir, [Parameter(Mandatory)][string]$TargetDir, [Parameter(Mandatory)]$Identity)
    [void](New-Item -ItemType Directory -Path $TargetDir -Force)
    foreach ($agent in (Get-ChildItem -LiteralPath $SourceDir -File -Filter '*.md' | Sort-Object Name)) {
        try {
            $text = ConvertTo-PluginAgent -Path $agent.FullName -Identity $Identity
        } catch {
            Write-BuildFailure -What "The agent $($agent.Name) cannot be converted to the plugin flavour: $($_.Exception.Message)" `
                -Why 'The plugin ships the converted agents; one that does not convert would ship tool names a plugin install does not have.' `
                -Fix "Fix .claude/agents/$($agent.Name) (the mapping rules are in build\PluginIdentity.psm1), then package again."
        }
        [IO.File]::WriteAllText((Join-Path $TargetDir $agent.Name), $text, (Get-Utf8NoBomEncoding))
    }
}

# No plugin agent names the direct tool prefix or CLAUDE.md: a plugin install has neither.
function Assert-PluginAgents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetDir, [Parameter(Mandatory)]$Identity)
    foreach ($forbidden in @($Identity.directToolPrefix, 'CLAUDE.md')) {
        foreach ($name in (Get-RelativeFileList $TargetDir)) {
            if ((Read-Utf8Text (Join-Path $TargetDir $name)).IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Write-BuildFailure -What "The plugin agent agents/$name still contains '$forbidden'." `
                    -Why 'A plugin install has no direct MCP server of that name and no CLAUDE.md, so the agent would call tools that do not exist or read rules that are not there.' `
                    -Fix "Map the term in Get-AgentMappingTable (build\PluginIdentity.psm1) or remove it from .claude/agents/$name, then package again."
            }
        }
    }
}

# ----------------------------------------------------------------------------
#  Generator: bin/CLAUDE.md = the user rules of the skill, nothing else
# ----------------------------------------------------------------------------
# A header line, then every skill file the import block of CLAUDE.md names, in that order, with its
# frontmatter removed. The developer sections of CLAUDE.md are NOT part of it.
function New-ClaudeMdText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $parts = @($script:ClaudeMdHeader) + @(Get-SkillImportPlan -RepoRoot $RepoRoot | ForEach-Object { Read-SkillFileText $_.FullPath })
    return (($parts -join "`n`n") + "`n")
}

function Get-FirstDifferenceLine {
    param([string]$Expected, [string]$Actual)
    $expectedLines = $Expected -split "`n"
    $actualLines = $Actual -split "`n"
    for ($index = 0; $index -lt [Math]::Max($expectedLines.Count, $actualLines.Count); $index++) {
        $left = if ($index -lt $expectedLines.Count) { $expectedLines[$index] } else { '(end of text)' }
        $right = if ($index -lt $actualLines.Count) { $actualLines[$index] } else { '(end of text)' }
        if (-not [string]::Equals($left, $right, [StringComparison]::Ordinal)) { return "line $($index + 1): expected '$left' but found '$right'" }
    }
    return 'no difference found'
}

# No @ import is left, and the text equals a fresh generation from the skill files.
function Assert-ClaudeMdGenerated {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RepoRoot)
    $text = Read-Utf8Text $Path
    $left = @(Get-ImportLine @($text -split '\r?\n'))
    if ($left.Count -gt 0) {
        $shown = ($left | Select-Object -First 3 | ForEach-Object { "line $($_.Number) @$($_.Path)" }) -join '; '
        Write-BuildFailure -What "bin/CLAUDE.md still contains $($left.Count) unresolved import(s): $shown" `
            -Why 'An installed copy has no such file next to it, so the rules would silently not load.' `
            -Fix 'Never edit bin/CLAUDE.md; package again with build\Build-PluginArchive.ps1 (New-ClaudeMdText inlines every import).'
    }
    $expected = New-ClaudeMdText -RepoRoot $RepoRoot
    if (-not [string]::Equals($text, $expected, [StringComparison]::Ordinal)) {
        Write-BuildFailure -What "bin/CLAUDE.md is not what the skill files generate: $(Get-FirstDifferenceLine $expected $text)" `
            -Why 'bin/CLAUDE.md must hold the user rules of the skill and nothing else; any other line (a developer section, an edit) would ship text nobody reviewed as rules.' `
            -Fix 'Never edit bin/CLAUDE.md; change plugin/skills/teststand-rules or the import order in CLAUDE.md, then package again.'
    }
}

# ----------------------------------------------------------------------------
#  Generators: writer and assertion per generated row
# ----------------------------------------------------------------------------
$script:Generators = @{
    Manifest = @{
        Write  = { param($Entry, $Context) Write-StampedManifest -SourcePath $Context.Sources.PluginJson -DestPath (Join-Path $Context.StageDir $Entry.Path) -Version $Context.Release.version }
        Assert = { param($Entry, $Context) Assert-StampedManifest -SourcePath $Context.Sources.PluginJson -StagedPath (Join-Path $Context.StageDir $Entry.Path) -Version $Context.Release.version }
    }
    VersionTxt = @{
        Write  = { param($Entry, $Context) Write-VersionTxt -Path (Join-Path $Context.StageDir $Entry.Path) -Values $Context.Release }
        Assert = { param($Entry, $Context) Assert-VersionTxt -Path (Join-Path $Context.StageDir $Entry.Path) -Expected $Context.Release }
    }
    Agents = @{
        Write  = { param($Entry, $Context) Write-PluginAgents -SourceDir (Join-Path $Context.RepoRoot $script:Paths.SourceAgents) -TargetDir (Join-Path $Context.StageDir $Entry.Path) -Identity $Context.Identity }
        Assert = { param($Entry, $Context) Assert-PluginAgents -TargetDir (Join-Path $Context.StageDir $Entry.Path) -Identity $Context.Identity }
    }
    ClaudeMd = @{
        Write  = { param($Entry, $Context) [IO.File]::WriteAllText((Join-Path $Context.StageDir $Entry.Path), (New-ClaudeMdText -RepoRoot $Context.RepoRoot), (Get-Utf8NoBomEncoding)) }
        Assert = { param($Entry, $Context) Assert-ClaudeMdGenerated -Path (Join-Path $Context.StageDir $Entry.Path) -RepoRoot $Context.RepoRoot }
    }
}

function New-StagingContext {
    param($RepoRoot, $PublishDir, $StageDir, $Layout, $Release)
    $sources = Get-PluginSourcePath -RepoRoot $RepoRoot
    return [pscustomobject]@{
        RepoRoot = $RepoRoot; PublishDir = $PublishDir; StageDir = $StageDir; Layout = $Layout; Release = $Release
        Sources = $sources
        Identity = (Get-PluginIdentity -PluginJsonPath $sources.PluginJson -McpJsonPath $sources.McpJson)
    }
}

# ----------------------------------------------------------------------------
#  Stage
# ----------------------------------------------------------------------------
# Builds the archive's directory tree from the publish output and the repository.
# $Release: the VERSION.txt values (tag, version, commit, built, run).
function New-StagedPlugin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$PublishDir, [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][hashtable]$Release
    )
    $context = New-StagingContext $RepoRoot $PublishDir $StageDir $Layout $Release
    Assert-FolderTracked -RepoRoot $RepoRoot -Dir $script:Paths.PluginDir
    Remove-BuildTempTree -Path $StageDir
    [void](New-Item -ItemType Directory -Path $StageDir -Force)
    foreach ($entry in (Get-StagingTable -RepoRoot $RepoRoot -Layout $Layout -PublishDir $PublishDir)) {
        if ($null -ne $entry.Source -and $entry.Copy -cne $script:CopyNone) {
            $source = Get-EntrySourceFile $entry $context
            foreach ($name in $source.Names) {
                $destination = Join-Path (Join-Path $StageDir $entry.Path) $name
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
                Copy-Item -LiteralPath (Join-Path $source.Dir $name) -Destination $destination -Force
            }
        }
        if ($entry.Generated) { & $script:Generators[$entry.Generated].Write $entry $context }
    }
}

# ----------------------------------------------------------------------------
#  Assert
# ----------------------------------------------------------------------------
function Assert-EntryRequiredAndForbidden {
    param($Entry, [string[]]$Present, [string]$Label)
    foreach ($name in $Entry.Required) {
        if ($Present -cnotcontains $name) { Write-BuildFailure -What "The staged tree is missing $name in $Label" -Why $Entry.Why -Fix $Entry.Fix }
    }
    foreach ($pattern in $Entry.Forbidden) {
        $hit = @($Present | Where-Object { $_ -like $pattern } | Select-Object -First 3)
        if ($hit.Count -gt 0) {
            Write-BuildFailure -What "The staged tree holds $($hit -join ', ') in $Label, which must not ship (forbidden: $pattern)." -Why $Entry.Why -Fix $Entry.Fix
        }
    }
}

function Assert-EntryExact {
    param($Entry, [string[]]$Present, [string]$Label)
    if ($null -eq $Entry.Exact) { return }
    $unexpected = @($Present | Where-Object { $Entry.Exact -cnotcontains $_ })
    $missing = @($Entry.Exact | Where-Object { $Present -cnotcontains $_ })
    if ($unexpected.Count -eq 0 -and $missing.Count -eq 0) { return }
    $detail = @()
    if ($unexpected.Count -gt 0) { $detail += "unexpected: $($unexpected -join ', ')" }
    if ($missing.Count -gt 0) { $detail += "missing: $($missing -join ', ')" }
    Write-BuildFailure -What "$Label holds $($Present.Count) file(s) but exactly $(@($Entry.Exact).Count) are expected ($($detail -join '; '))." -Why $Entry.Why -Fix $Entry.Fix
}

# The top-level names a row may hold: those of the files it stages itself, and those of the other
# rows nested below it.
function Assert-EntryTopLevel {
    param($Entry, $Table, $Context, [string[]]$Present, [string]$Label)
    if (-not $Entry.ExactTopLevel) { return }
    $prefix = if ($Entry.Path -ceq $script:Paths.Root) { '' } else { $Entry.Path + '/' }
    $allowed = @((Get-EntrySourceFile $Entry $Context).Names | ForEach-Object { Get-FirstSegment $_ })
    foreach ($other in $Table) {
        if ($other.Path -cne $Entry.Path -and $other.Path.StartsWith($prefix, [StringComparison]::Ordinal)) { $allowed += Get-FirstSegment $other.Path.Substring($prefix.Length) }
    }
    $unexpected = @($Present | ForEach-Object { Get-FirstSegment $_ } | Sort-Object -Unique | Where-Object { $allowed -cnotcontains $_ })
    if ($unexpected.Count -gt 0) {
        Write-BuildFailure -What "$Label holds top-level entries that nothing stages: $($unexpected -join ', ')." -Why $Entry.Why -Fix $Entry.Fix
    }
}

function Assert-EntrySameContent {
    param($Entry, $Context, [string[]]$Present, [string]$StagedDir, [string]$Label)
    if (-not $Entry.SameContentAs) { return }
    $sourceDir = Join-Path $Context.RepoRoot $Entry.Source
    foreach ($name in $Present) {
        $sourcePath = Join-Path $sourceDir $name
        if (-not (Test-Path -LiteralPath $sourcePath) -or (Get-FileSha256 $sourcePath) -cne (Get-FileSha256 (Join-Path $StagedDir $name))) {
            Write-BuildFailure -What "$Label$name differs from its source $($Entry.Source)/$name." -Why $Entry.Why -Fix $Entry.Fix
        }
    }
}

function Assert-StagingEntry {
    param($Entry, $Table, $Context)
    $path = Join-Path $Context.StageDir $Entry.Path
    if ($Entry.Kind -ceq 'File') {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-BuildFailure -What "The staged tree is missing $($Entry.Path)." -Why $Entry.Why -Fix $Entry.Fix }
    } else {
        $present = Get-RelativeFileList $path
        $label = if ($Entry.Path -ceq $script:Paths.Root) { 'the archive root' } else { "$($Entry.Path)/" }
        Assert-EntryRequiredAndForbidden $Entry $present $label
        Assert-EntryExact $Entry $present $label
        Assert-EntryTopLevel $Entry $Table $Context $present $label
        Assert-EntrySameContent $Entry $Context $present $path "$($Entry.Path)/"
    }
    if ($Entry.Generated) { & $script:Generators[$Entry.Generated].Assert $Entry $Context }
}

# Every table row against a staged tree. $PublishDir must still exist: the expected top-level set of
# bin/ is derived from it.
function Assert-StagedPlugin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$StageDir, [Parameter(Mandatory)][string]$PublishDir,
        [Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][hashtable]$Release
    )
    $context = New-StagingContext $RepoRoot $PublishDir $StageDir $Layout $Release
    $table = @(Get-StagingTable -RepoRoot $RepoRoot -Layout $Layout -PublishDir $PublishDir)
    foreach ($entry in $table) { Assert-StagingEntry $entry $table $context }
}

# ----------------------------------------------------------------------------
#  Snapshot: nothing may change the staged tree between its assertion and the zip
# ----------------------------------------------------------------------------
# The per-file hash list of the staged tree (the text of the archive manifest).
function Get-StageSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StageDir)
    return New-ArchiveManifest -StagedDir $StageDir
}

function Assert-StageUnchanged {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StageDir, [Parameter(Mandatory)][string]$Snapshot)
    $now = Get-StageSnapshot -StageDir $StageDir
    if ([string]::Equals($now, $Snapshot, [StringComparison]::Ordinal)) { return }
    $before = @($Snapshot -split "`n" | Where-Object { $_ })
    $after = @($now -split "`n" | Where-Object { $_ })
    $changed = @(($before | Where-Object { $after -cnotcontains $_ }) + ($after | Where-Object { $before -cnotcontains $_ }) | ForEach-Object { ($_ -split '  ', 2)[1] } | Sort-Object -Unique | Select-Object -First 5)
    Write-BuildFailure -What "The staged tree changed after it was asserted: $($changed -join ', ')" `
        -Why 'Only the asserted tree may be zipped; a file added or changed since (by the smoke run, or anything else writing into the stage folder) was never checked.' `
        -Fix 'Find what writes into the stage folder (the staged exe run by PluginSmoke.psm1 writes nothing next to itself by design), then package again.'
}

Export-ModuleMember -Function Get-PublishedExePath, Get-StagedExePath, Select-StagedFile, Get-StagingTable, New-StagedPlugin, Assert-StagedPlugin,
    Find-VersionPlaceholder, Write-StampedManifest, Assert-StampedManifest, Assert-VersionTxt, New-ClaudeMdText, Assert-ClaudeMdGenerated,
    Get-StageSnapshot, Assert-StageUnchanged
