# ============================================================================
#  SkillSources.Tests.ps1 - plain PowerShell asserts for build/Test-SkillSources.ps1
#  Every case builds a temp fixture repository (a copy of the real skill plus a
#  small CLAUDE.md), plants ONE defect and runs the checker against it with
#  -RepoRoot. Runs under Windows PowerShell 5.1 and PowerShell 7:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\tests\SkillSources.Tests.ps1
#  Prints PASS/FAIL per case and exits non-zero when any case fails.
#  ASCII only on purpose (5.1 reads a BOM-less script as ANSI).
# ============================================================================
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CheckerPath = Join-Path $RepoRoot 'build\Test-SkillSources.ps1'
$RealSkillRoot = Join-Path $RepoRoot 'plugin\skills\teststand-rules'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$EmDash = [string][char]0x2014

$SkillFiles = @('SKILL.md', 'references\rebuild.md', 'references\sequence-design.md', 'references\agents.md', 'references\headless-and-tools.md')

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

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TempDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('SkillSourcesTests_' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $script:TempDirs += $dir
    return $dir
}

function Write-Text {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Read-Text {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, $Utf8NoBom)
}

function New-ClaudeMdText {
    $imports = $SkillFiles | ForEach-Object { '@plugin/skills/teststand-rules/' + $_.Replace('\', '/') }
    return (@('# Fixture rules', '', '## User-facing rules', '') + $imports + @(
            '', "## TestStand ENVIRONMENTS (``.tsenv``) $EmDash engine internals", '',
            'The environment is applied through SetEnvironmentPath on the engine thread.', '')) -join "`n"
}

# A fixture repository that passes every check; each case then plants one defect.
function New-Fixture {
    $root = New-TempDir
    foreach ($file in $SkillFiles) {
        $target = Join-Path $root ('plugin\skills\teststand-rules\' + $file)
        Write-Text $target (Read-Text (Join-Path $RealSkillRoot $file))
    }
    Write-Text (Join-Path $root 'CLAUDE.md') (New-ClaudeMdText)
    Write-Text (Join-Path $root 'README.md') "# Fixture readme`n`nNothing moved here.`n"
    return $root
}

function Add-Line {
    param([string]$Path, [string]$Line)
    Write-Text $Path ((Read-Text $Path).TrimEnd() + "`n" + $Line + "`n")
}

# Runs the checker against a fixture; returns exit code and the combined output.
function Invoke-Checker {
    param([string]$Root)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CheckerPath -RepoRoot $Root 2>&1 | Out-String
    return @{ ExitCode = $LASTEXITCODE; Output = $output }
}

# The run must fail, the named check must be a FAIL line, and the output must carry the reason.
function Assert-CheckerFails {
    param([hashtable]$Run, [string]$FailingCheck, [string[]]$MustMention)
    Assert-True ($Run.ExitCode -ne 0) "expected a non-zero exit code but got $($Run.ExitCode)"
    Assert-True ($Run.Output -match [regex]::Escape("FAIL  $FailingCheck")) "expected a FAIL line for [$FailingCheck] in:`n$($Run.Output)"
    foreach ($text in $MustMention) {
        Assert-True ($Run.Output.Contains($text)) "expected the output to mention [$text] in:`n$($Run.Output)"
    }
}

try {
    Invoke-Case 'control: the unmodified fixture passes every check' {
        $run = Invoke-Checker (New-Fixture)
        Assert-True ($run.ExitCode -eq 0) "expected exit 0 but got $($run.ExitCode):`n$($run.Output)"
        Assert-True ($run.Output -notmatch 'FAIL  ') "unexpected FAIL line in:`n$($run.Output)"
    }

    Invoke-Case 'deny-list: a planted date fails and names file and line' {
        $root = New-Fixture
        Add-Line (Join-Path $root 'plugin\skills\teststand-rules\references\rebuild.md') 'Measured 2026-07-29 on a real file.'
        $run = Invoke-Checker $root
        Assert-CheckerFails $run "deny-list: no 'date'" @('references/rebuild.md', '2026-07-29')
    }

    Invoke-Case 'deny-list: a planted test id fails' {
        $root = New-Fixture
        Add-Line (Join-Path $root 'plugin\skills\teststand-rules\SKILL.md') 'Pinned by T35.'
        Assert-CheckerFails (Invoke-Checker $root) "deny-list: no 'test id'" @('SKILL.md', 'T35')
    }

    Invoke-Case 'deny-list: the case-insensitive words fail whatever their case' {
        $root = New-Fixture
        Add-Line (Join-Path $root 'plugin\skills\teststand-rules\references\agents.md') 'See Memory notes and the DYNAMIC binder.'
        $run = Invoke-Checker $root
        Assert-CheckerFails $run "deny-list: no 'memory'" @('agents.md')
        Assert-CheckerFails $run "deny-list: no 'dynamic'" @('agents.md')
    }

    Invoke-Case 'imports: a dangling import fails and names the import' {
        $root = New-Fixture
        Add-Line (Join-Path $root 'CLAUDE.md') '@plugin/skills/teststand-rules/references/missing.md'
        Assert-CheckerFails (Invoke-Checker $root) 'imports: every @path import in CLAUDE.md resolves' @('@plugin/skills/teststand-rules/references/missing.md')
    }

    Invoke-Case 'imports: a skill file CLAUDE.md does not import fails and names the file' {
        $root = New-Fixture
        $path = Join-Path $root 'CLAUDE.md'
        Write-Text $path ((Read-Text $path).Replace("@plugin/skills/teststand-rules/references/agents.md`n", ''))
        Assert-CheckerFails (Invoke-Checker $root) 'imports: CLAUDE.md imports SKILL.md and every reference file' @('references/agents.md')
    }

    Invoke-Case 'required rule: a removed rule fails and names the rule' {
        $root = New-Fixture
        $path = Join-Path $root 'plugin\skills\teststand-rules\references\sequence-design.md'
        Write-Text $path ((Read-Text $path).Replace('default to `SequenceCall`', 'prefer SequenceCall'))
        Assert-CheckerFails (Invoke-Checker $root) 'required rule present: SequenceCall as default step type' @('default to')
    }

    Invoke-Case 'required rule: a missing reference file fails' {
        $root = New-Fixture
        Remove-Item -LiteralPath (Join-Path $root 'plugin\skills\teststand-rules\references\headless-and-tools.md')
        Assert-CheckerFails (Invoke-Checker $root) 'skill: SKILL.md and the four reference files exist' @('headless-and-tools.md')
    }

    Invoke-Case 'SKILL.md: a fifth item in the first section fails' {
        $root = New-Fixture
        $path = Join-Path $root 'plugin\skills\teststand-rules\SKILL.md'
        Write-Text $path ((Read-Text $path).Replace("`n## Details", "- Never do a fifth thing.`n`n## Details"))
        Assert-CheckerFails (Invoke-Checker $root) 'SKILL.md: the first section holds exactly the four never-do rules' @('found 5')
    }

    Invoke-Case 'SKILL.md: a missing pointer fails and names the reference' {
        $root = New-Fixture
        $path = Join-Path $root 'plugin\skills\teststand-rules\SKILL.md'
        Write-Text $path ((Read-Text $path).Replace('references/agents.md', 'references/other.md'))
        Assert-CheckerFails (Invoke-Checker $root) 'SKILL.md: points to every reference file' @('agents.md')
    }

    Invoke-Case 'uniqueness: a moved heading left in CLAUDE.md fails and names heading and line' {
        $root = New-Fixture
        Add-Line (Join-Path $root 'CLAUDE.md') "`n## Sequence Design Rules"
        Assert-CheckerFails (Invoke-Checker $root) 'uniqueness: no moved heading remains in CLAUDE.md or other tracked markdown' @('CLAUDE.md:', 'Sequence Design Rules')
    }

    Invoke-Case 'uniqueness: a moved heading with an em dash left in CLAUDE.md fails' {
        $root = New-Fixture
        Add-Line (Join-Path $root 'CLAUDE.md') "`n## Cloning ONE sequence $EmDash ``duplicate_sequence``"
        Assert-CheckerFails (Invoke-Checker $root) 'uniqueness: no moved heading remains in CLAUDE.md or other tracked markdown' @('Cloning ONE sequence')
    }

    Invoke-Case 'uniqueness: a moved heading in other markdown fails and names that file' {
        $root = New-Fixture
        Add-Line (Join-Path $root 'README.md') "`n### Default Step Type When Unclear"
        Assert-CheckerFails (Invoke-Checker $root) 'uniqueness: no moved heading remains in CLAUDE.md or other tracked markdown' @('README.md:', 'Default Step Type When Unclear')
    }

    Invoke-Case 'uniqueness: a moved heading quoted in docs/specs or plans is allowed' {
        $root = New-Fixture
        Write-Text (Join-Path $root 'docs\specs\quote.md') "# Spec`n`n## Sequence Design Rules`n"
        Write-Text (Join-Path $root 'plans\quote.md') "# Plan`n`n### Default Step Type When Unclear`n"
        $run = Invoke-Checker $root
        Assert-True ($run.ExitCode -eq 0) "expected exit 0 but got $($run.ExitCode):`n$($run.Output)"
    }

    Invoke-Case 'uniqueness: the user half of the .tsenv section left in CLAUDE.md fails' {
        $root = New-Fixture
        Add-Line (Join-Path $root 'CLAUDE.md') '- **Sources, in precedence order:** connect_engine first.'
        Assert-CheckerFails (Invoke-Checker $root) 'uniqueness: CLAUDE.md keeps no user half of the .tsenv section' @('Sources, in precedence order')
    }

    Invoke-Case 'uniqueness: dropping the developer half of the .tsenv section fails' {
        $root = New-Fixture
        $path = Join-Path $root 'CLAUDE.md'
        Write-Text $path ((Read-Text $path).Replace('SetEnvironmentPath', 'something else'))
        Assert-CheckerFails (Invoke-Checker $root) 'uniqueness: CLAUDE.md keeps the developer half of the .tsenv section' @('SetEnvironmentPath')
    }
}
finally {
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
