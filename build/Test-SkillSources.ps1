# ============================================================================
#  Test-SkillSources.ps1 - source check for the teststand-rules skill.
#  Four groups of checks, each printed as PASS/FAIL; exit code 1 on any FAIL:
#    A  required rules are present across the skill, and SKILL.md's first
#       section holds exactly the four never-do rules plus the pointers
#    B  the developer-only deny-list matches nothing in the skill files
#    C  no rule is kept twice: moved CLAUDE.md headings stay out of CLAUDE.md
#       and the other tracked markdown (outside plugin/skills, docs/specs, plans)
#    D  every @path import line in CLAUDE.md resolves, and the skill files are imported
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\Test-SkillSources.ps1
#  -RepoRoot / -SkillRoot let the tests point it at fixtures.
#  Windows PowerShell 5.1 compatible. ASCII only on purpose: 5.1 reads a BOM-less
#  script as ANSI, so the one non-ASCII character (the em dash in headings) is a
#  <EM> token replaced from its code point.
# ============================================================================
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$SkillRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $SkillRoot) { $SkillRoot = Join-Path $RepoRoot 'plugin\skills\teststand-rules' }
$ClaudeMdPath = Join-Path $RepoRoot 'CLAUDE.md'
$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$EmDash = [string][char]0x2014

# --- Group A data: required rules (all patterns of a rule must match somewhere in the skill) ---
$RequiredRules = @(
    @{ Name = 'export/import first'; Patterns = @('export_sequence_file', 'import_sequence_file') }
    @{ Name = '.lvlibp clone-not-load'; Patterns = @('\.lvlibp', 'copy_step_module', 'cloned, never loaded') }
    @{ Name = 'diff plus audit_type_consistency'; Patterns = @('diff_sequence_files', 'audit_type_consistency') }
    @{ Name = 'NI_Flow_* mandate'; Patterns = @('NI_Flow_\*', 'Goto') }
    @{ Name = 'Select/Case: one End per Case'; Patterns = @('NI_Flow_Select', 'own\s+`NI_Flow_End`') }
    @{ Name = 'SequenceCall as default step type'; Patterns = @('default to\s+`SequenceCall`') }
    @{ Name = 'headless limitations'; Patterns = @('Headless limitations', 'Paused', 'step_results') }
    @{ Name = 'builder runs in the main thread'; Patterns = @('teststand-sequence-builder', 'AskUserQuestion', 'main thread') }
    @{ Name = 'doc generator asks the language first'; Patterns = @('teststand-doc-generator', 'ask the document language first') }
    @{ Name = 'presentation generator asks the language first'; Patterns = @('teststand-presentation-generator', 'ask the presentation language first') }
)

# The first section of SKILL.md: exactly these four, in this order.
$NeverDoRules = @(
    @{ Name = 'builder in the main thread'; Patterns = @('teststand-sequence-builder', 'main thread', 'subagent') }
    @{ Name = 'NI_Flow_* instead of Goto/Label'; Patterns = @('NI_Flow_\*', 'Goto', 'Label') }
    @{ Name = '.lvlibp clone, never load'; Patterns = @('\.lvlibp', 'clone', 'in-process') }
    @{ Name = 'diff plus audit_type_consistency'; Patterns = @('diff_sequence_files', 'audit_type_consistency') }
)
$ExpectedReferenceFiles = @('rebuild.md', 'sequence-design.md', 'agents.md', 'headless-and-tools.md')

# --- Group B data: developer-only deny-list (AC-16) ---
$DenyList = @(
    @{ Name = 'date'; Pattern = '\b20\d\d-\d\d-\d\d\b'; CaseSensitive = $true }
    @{ Name = 'test id'; Pattern = '\bT\d{2}\b'; CaseSensitive = $true }
    @{ Name = 'memory'; Pattern = 'memory'; CaseSensitive = $false }
    @{ Name = 'wiki link'; Pattern = '\[\['; CaseSensitive = $true }
    @{ Name = '.Demo_jcm'; Pattern = '\.Demo_jcm'; CaseSensitive = $false }
    @{ Name = 'this file'; Pattern = 'this file'; CaseSensitive = $false }
    @{ Name = 'Marshal'; Pattern = 'Marshal'; CaseSensitive = $false }
    @{ Name = 'dynamic'; Pattern = 'dynamic'; CaseSensitive = $false }
    @{ Name = 'taskkill'; Pattern = 'taskkill'; CaseSensitive = $false }
    @{ Name = 'dotnet build'; Pattern = 'dotnet build'; CaseSensitive = $false }
)

# --- Group C data: the CLAUDE.md headings that moved into the skill (exact heading text) ---
$MovedHeadings = @(
    'Rebuilding a .seq 1:1 <EM> `export_sequence_file` + `import_sequence_file` FIRST'
    'The on-disk FORMAT is reproduced too <EM> and the diff is blind to it (2026-07-31)'
    'A `.lvlibp` pane is CLONED, never loaded <EM> and the server now ENFORCES that (2026-07-30)'
    'The two prototype-load kinds are MUTUALLY EXCLUSIVE per process (measured 2026-07-29)'
    'Residuals after export/import: NONE (2026-07-29)'
    'NEVER replace a TYPED PropertyObject with a clone <EM> write its scalars BY VALUE (2026-07-29)'
    'Cloning ONE sequence <EM> `duplicate_sequence`'
    'CRITICAL: How to build sequences from a flowchart/description'
    'Documenting sequence files (teststand-doc-generator)'
    'Presenting sequence files (teststand-presentation-generator)'
    'Sequence Design Rules'
    'Flow Control: If/Else always with NI_Flow_* Step Types'
    'Default Step Type When Unclear'
    'Correct Structure for an If/Else Block:'
    'Correct Structure for a Select/Case Block:'
    'All Available Step Types (from get_step_types):'
    'Expressions'
    'Properties & variables'
    'Headless limitations = EXPECTED outcomes (not bugs)'
    'Live thread-context inspection (runtime debugging)'
    'Step-type / enum specifics'
    'User management'
    'Pre-build validation'
    'Sequence Analyzer: duration, a REAL timeout, and never trust a zero (2026-07-29)'
    'Sequence Analyzer is ASYNC-capable (cold `.lvlibp` timeout fix; 2026-07-09)'
    'Post-build validation (reference audit)'
    'TestStand ENVIRONMENTS (`.tsenv`) <EM> chosen once per PROCESS (2026-08-14, issue #35)'
) | ForEach-Object { $_.Replace('<EM>', $EmDash) }

# The .tsenv section is split: its user half moved, its developer half stays in CLAUDE.md.
$TsenvUserHalfMarkers = @(
    '**Sources, in precedence order:**'
    '**`get_engine_paths` now reports**'
    '**`open_sequence_file` warns on a MISMATCH**'
)
$TsenvDeveloperHeadingPrefix = '## TestStand ENVIRONMENTS'
$TsenvDeveloperMarker = 'SetEnvironmentPath'

# Markdown outside these roots (relative, forward slashes) is searched for moved headings.
$UniquenessExcludedRoots = @('plugin/skills/', 'docs/specs/', 'plans/')
$WalkExcludedDirs = @('.git', 'bin', 'obj', 'node_modules', 'worktrees')

# ----------------------------------------------------------------------------
$script:Failures = 0

function Write-Result {
    param([string]$Name, [bool]$Ok, [string[]]$Detail = @())
    if ($Ok) {
        Write-Host "PASS  $Name"
    } else {
        $script:Failures++
        Write-Host "FAIL  $Name"
        foreach ($line in $Detail) { Write-Host "      $line" }
    }
}

function Read-Text {
    param([string]$Path)
    return $StrictUtf8.GetString([IO.File]::ReadAllBytes($Path))
}

function Split-Lines {
    param([string]$Text)
    return , ($Text -split "\r?\n")
}

function Test-AllPatterns {
    param([string]$Text, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if (-not [regex]::IsMatch($Text, $pattern, 'IgnoreCase')) { return $false }
    }
    return $true
}

function Get-SkillMarkdown {
    if (-not (Test-Path -LiteralPath $SkillRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $SkillRoot -Recurse -File -Filter '*.md' | Sort-Object FullName)
}

function Get-RelativePath {
    param([string]$Root, [string]$Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    return $full.Substring($rootFull.Length).Replace('\', '/')
}

function Get-HeadingText {
    param([string]$Line)
    $match = [regex]::Match($Line, '^#{1,6}\s+(.*?)\s*$')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

# The markdown files of the repository: tracked ones when it is a git checkout, else a directory walk.
function Get-RepositoryMarkdown {
    $paths = @()
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ((Test-Path -LiteralPath (Join-Path $RepoRoot '.git')) -and $git) {
        $listed = & git -C $RepoRoot ls-files -- '*.md'
        if ($LASTEXITCODE -eq 0 -and $listed) { $paths = @($listed | ForEach-Object { $_.Replace('\', '/') }) }
    } else {
        $pending = New-Object System.Collections.Generic.Stack[string]
        $pending.Push((Resolve-Path -LiteralPath $RepoRoot).ProviderPath)
        while ($pending.Count -gt 0) {
            $dir = $pending.Pop()
            foreach ($child in Get-ChildItem -LiteralPath $dir -Force) {
                if ($child.PSIsContainer) {
                    if ($WalkExcludedDirs -notcontains $child.Name) { $pending.Push($child.FullName) }
                } elseif ($child.Extension -eq '.md') {
                    $paths += (Get-RelativePath $RepoRoot $child.FullName)
                }
            }
        }
    }
    return $paths
}

# ============================================================================
#  Group A - required rules
# ============================================================================
$skillFiles = Get-SkillMarkdown
$skillText = ($skillFiles | ForEach-Object { Read-Text $_.FullName }) -join "`n"

Write-Result 'skill: SKILL.md and the four reference files exist' (
    (Test-Path -LiteralPath (Join-Path $SkillRoot 'SKILL.md')) -and
    -not ($ExpectedReferenceFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SkillRoot "references\$_")) })
) @("expected SKILL.md and references\{$($ExpectedReferenceFiles -join ',')} under $SkillRoot")

foreach ($rule in $RequiredRules) {
    $ok = Test-AllPatterns $skillText $rule.Patterns
    Write-Result "required rule present: $($rule.Name)" $ok @("no skill file contains all of: $($rule.Patterns -join ' | ')")
}

$skillMdPath = Join-Path $SkillRoot 'SKILL.md'
if (Test-Path -LiteralPath $skillMdPath) {
    $skillMd = Read-Text $skillMdPath
    $skillLines = Split-Lines $skillMd

    $bomPattern = '(?:' + [regex]::Escape([string][char]0xFEFF) + ')?'
    $frontmatter = [regex]::Match($skillMd, '^' + $bomPattern + '---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
    $frontOk = $frontmatter.Success -and
        ($frontmatter.Groups[1].Value -match '(?m)^name:\s*teststand-rules\s*$') -and
        ($frontmatter.Groups[1].Value -match '(?m)^description:\s*\S')
    Write-Result 'SKILL.md: frontmatter has name teststand-rules and a description' $frontOk @('expected a leading --- block with "name: teststand-rules" and a non-empty "description:"')

    # The first section: from the first "## " heading to the next one.
    $sectionStart = -1; $sectionEnd = $skillLines.Count
    for ($i = 0; $i -lt $skillLines.Count; $i++) {
        if ($skillLines[$i] -match '^##\s') {
            if ($sectionStart -lt 0) { $sectionStart = $i } else { $sectionEnd = $i; break }
        }
    }
    $items = @()
    if ($sectionStart -ge 0) {
        $current = $null
        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            if ($skillLines[$i] -match '^[-*]\s+(.*)$') {
                if ($null -ne $current) { $items += $current }
                $current = $Matches[1]
            } elseif ($null -ne $current -and $skillLines[$i] -match '^\s+\S') {
                $current += ' ' + $skillLines[$i].Trim()
            }
        }
        if ($null -ne $current) { $items += $current }
    }
    $neverDoOk = ($sectionStart -ge 0) -and ($items.Count -eq $NeverDoRules.Count)
    $neverDoDetail = @("first section of SKILL.md must list exactly $($NeverDoRules.Count) rules, found $($items.Count)")
    if ($neverDoOk) {
        for ($r = 0; $r -lt $NeverDoRules.Count; $r++) {
            if (-not (Test-AllPatterns $items[$r] $NeverDoRules[$r].Patterns)) {
                $neverDoOk = $false
                $neverDoDetail = @("never-do item $($r + 1) is not the rule '$($NeverDoRules[$r].Name)' (needs: $($NeverDoRules[$r].Patterns -join ' | '))")
                break
            }
        }
    }
    Write-Result 'SKILL.md: the first section holds exactly the four never-do rules' $neverDoOk $neverDoDetail

    $missingPointers = @($ExpectedReferenceFiles | Where-Object { $skillMd -notmatch [regex]::Escape("references/$_") })
    Write-Result 'SKILL.md: points to every reference file' ($missingPointers.Count -eq 0) @("no pointer to: $($missingPointers -join ', ')")
}

# ============================================================================
#  Group B - deny-list
# ============================================================================
foreach ($entry in $DenyList) {
    $options = if ($entry.CaseSensitive) { 'None' } else { 'IgnoreCase' }
    $hits = @()
    foreach ($file in $skillFiles) {
        $lines = Split-Lines (Read-Text $file.FullName)
        for ($n = 0; $n -lt $lines.Count; $n++) {
            if ([regex]::IsMatch($lines[$n], $entry.Pattern, $options)) {
                $hits += "$(Get-RelativePath $SkillRoot $file.FullName):$($n + 1): $($lines[$n].Trim())"
            }
        }
    }
    Write-Result "deny-list: no '$($entry.Name)' ($($entry.Pattern)) in the skill files" ($hits.Count -eq 0) @($hits | Select-Object -First 5)
}

# ============================================================================
#  Group C - uniqueness
# ============================================================================
$claudeMdExists = Test-Path -LiteralPath $ClaudeMdPath
$claudeLines = @()
if ($claudeMdExists) { $claudeLines = Split-Lines (Read-Text $ClaudeMdPath) }

$leftovers = @()
foreach ($relative in (Get-RepositoryMarkdown)) {
    $excluded = $false
    foreach ($root in $UniquenessExcludedRoots) { if ($relative.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $excluded = $true } }
    if ($excluded) { continue }
    $full = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $lines = Split-Lines (Read-Text $full)
    $inFence = $false
    for ($n = 0; $n -lt $lines.Count; $n++) {
        if ($lines[$n] -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        $heading = Get-HeadingText $lines[$n]
        if ($null -ne $heading -and ($MovedHeadings -ccontains $heading)) {
            $leftovers += "${relative}:$($n + 1): moved heading still present: $heading"
        }
    }
}
Write-Result 'uniqueness: no moved heading remains in CLAUDE.md or other tracked markdown' ($leftovers.Count -eq 0) @($leftovers | Select-Object -First 8)

$claudeText = $claudeLines -join "`n"
$userHalfLeft = @($TsenvUserHalfMarkers | Where-Object { $claudeText.Contains($_) })
Write-Result 'uniqueness: CLAUDE.md keeps no user half of the .tsenv section' ($userHalfLeft.Count -eq 0) @($userHalfLeft | ForEach-Object { "still in CLAUDE.md: $_" })

$devHeading = @($claudeLines | Where-Object { $_.StartsWith($TsenvDeveloperHeadingPrefix) })
$devOk = $claudeMdExists -and ($devHeading.Count -eq 1) -and $claudeText.Contains($TsenvDeveloperMarker)
Write-Result 'uniqueness: CLAUDE.md keeps the developer half of the .tsenv section' $devOk @("expected one '$TsenvDeveloperHeadingPrefix...' heading and the text '$TsenvDeveloperMarker' in CLAUDE.md")

# ============================================================================
#  Group D - imports
# ============================================================================
$dangling = @()
$imported = @()
$inFence = $false
for ($n = 0; $n -lt $claudeLines.Count; $n++) {
    $line = $claudeLines[$n]
    if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
    if ($inFence) { continue }
    if ($line -match '^@(\S+)\s*$') {
        $importPath = $Matches[1]
        $resolved = [IO.Path]::GetFullPath((Join-Path $RepoRoot $importPath))
        $imported += $resolved
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { $dangling += "CLAUDE.md:$($n + 1): import @$importPath does not exist" }
    }
}
Write-Result 'imports: every @path import in CLAUDE.md resolves' ($dangling.Count -eq 0) $dangling

$notImported = @()
foreach ($file in $skillFiles) {
    if ($imported -notcontains [IO.Path]::GetFullPath($file.FullName)) { $notImported += (Get-RelativePath $RepoRoot $file.FullName) }
}
Write-Result 'imports: CLAUDE.md imports SKILL.md and every reference file' ($notImported.Count -eq 0) @($notImported | ForEach-Object { "not imported: $_" })

# ============================================================================
Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) FAILED"
    exit 1
}
Write-Host 'All checks passed'
exit 0
