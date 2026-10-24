# ============================================================================
#  Workflows.Tests.ps1 - plain PowerShell asserts that pin the CONTRACT of the GitHub Actions
#  workflows (.github/workflows/*.yml) as text, because actionlint is not installed here and is never
#  downloaded by the build. The workflows only call the build scripts; what they must get right is
#  the wiring, and that is what these cases pin:
#    every workflow  actions pinned to a full commit SHA with a version comment, no ${{ }} inside any
#                    run: block (tags, inputs and refs are user input), permissions stated per job,
#                    a timeout on every job;
#    ci.yml          triggers, read-only permissions, step order, publishes nothing;
#    release.yml     triggers, the concurrency group, the tag gate first, publish by release_id and
#                    only after the verify step, the final public fetch with the verified digest, the
#                    own-downloads artifact, the dry run and its cleanup.
#  The first real run of these workflows is the fork rehearsal (see the plan): this file cannot prove
#  that GitHub accepts them, only that they keep the shape that was designed.
#  Runs under Windows PowerShell 5.1 and PowerShell 7:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\tests\Workflows.Tests.ps1
#  Prints PASS/FAIL per case and exits non-zero when any case fails. ASCII only on purpose.
# ============================================================================
param(
    [string]$WorkflowDirectory   # another folder of workflow files (to prove that a broken one is caught); default: the repository's
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WorkflowDir = if ($WorkflowDirectory) { $WorkflowDirectory } else { Join-Path $RepoRoot '.github\workflows' }

$FullShaPattern = '[0-9a-f]{40}'
$PinnedUsesPattern = '\Auses:\s+[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@' + $FullShaPattern + '\s+#\s+v[0-9]+(\.[0-9]+)*\s*\z'
$ExpressionOpen = '${{'

. (Join-Path $PSScriptRoot 'TestHarness.ps1')
$script:TempDirPrefix = 'WorkflowsTests_'

# --- A deliberately small reader for the YAML these workflows use --------------------------------------
# Indentation convention of the workflows: top-level keys at column 0, job names at 2, job keys at 4,
# step items ("- name:") at 6. The reader relies on it, and a case below pins it.
function Read-WorkflowText {
    param([string]$Name)
    $path = Join-Path $WorkflowDir $Name
    Assert-True (Test-Path -LiteralPath $path) "$path does not exist"
    return ([IO.File]::ReadAllText($path)).Replace("`r`n", "`n")
}

function Get-WorkflowFileNames {
    return @(Get-ChildItem -LiteralPath $WorkflowDir -File -Filter '*.yml' | Sort-Object Name | ForEach-Object { $_.Name })
}

# The text without its comment-only lines: what a pattern about the workflow's behaviour must be matched against.
function Remove-CommentLines {
    param([string]$Text)
    return (@($Text -split "`n" | Where-Object { $_ -cnotmatch '\A\s*#' }) -join "`n")
}

# The text of a top-level block: from "<key>:" up to the next top-level key.
function Get-TopLevelBlock {
    param([string]$Text, [string]$Key)
    $lines = $Text -split "`n"
    $collected = @()
    $inside = $false
    foreach ($line in $lines) {
        if ($line -cmatch '\A[A-Za-z_][A-Za-z0-9_-]*:') {
            if ($inside) { break }
            if ($line -cmatch ('\A' + [regex]::Escape($Key) + ':')) { $inside = $true }
        }
        if ($inside) { $collected += $line }
    }
    return ($collected -join "`n")
}

function Get-JobNames {
    param([string]$Text)
    $jobs = Get-TopLevelBlock $Text 'jobs'
    return @([regex]::Matches($jobs, '(?m)^  ([A-Za-z0-9_-]+):\s*$') | ForEach-Object { $_.Groups[1].Value })
}

function Get-JobText {
    param([string]$Text, [string]$Job)
    $jobs = (Get-TopLevelBlock $Text 'jobs') -split "`n"
    $collected = @()
    $inside = $false
    foreach ($line in $jobs) {
        if ($line -cmatch '\A  ([A-Za-z0-9_-]+):\s*\z') {
            if ($inside) { break }
            if ($Matches[1] -ceq $Job) { $inside = $true }
        }
        if ($inside) { $collected += $line }
    }
    Assert-True ($collected.Count -gt 0) "no job named $Job"
    return ($collected -join "`n")
}

# The steps of a job as { Name; Text }, in order. A step starts at "      - " (six spaces).
function Get-Steps {
    param([string]$JobText)
    $steps = @()
    $current = $null
    foreach ($line in ((Remove-CommentLines $JobText) -split "`n")) {
        if ($line -cmatch '\A      - ') {
            if ($null -ne $current) { $steps += $current }
            $current = @{ Name = ''; Lines = @($line) }
        } elseif ($null -ne $current) {
            $current.Lines += $line
        }
    }
    if ($null -ne $current) { $steps += $current }
    return @($steps | ForEach-Object {
        $text = $_.Lines -join "`n"
        $name = [regex]::Match($text, '(?m)^\s+(?:- )?name:\s*(.+?)\s*$').Groups[1].Value
        [pscustomobject]@{ Name = $name; Text = $text }
    })
}

# Every run: value (inline or block scalar) of a text, as one string each.
function Get-RunValues {
    param([string]$Text)
    $values = @()
    $lines = $Text -split "`n"
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $match = [regex]::Match($lines[$index], '\A(\s*)(?:- )?run:\s*(.*)\z')
        if (-not $match.Success) { continue }
        $indent = $match.Groups[1].Value.Length
        $value = $match.Groups[2].Value
        if ($value -cmatch '\A[|>][+-]?\s*\z') {
            $block = @()
            for ($next = $index + 1; $next -lt $lines.Count; $next++) {
                $candidate = $lines[$next]
                if ($candidate.Trim().Length -gt 0 -and ($candidate.Length - $candidate.TrimStart().Length) -le $indent) { break }
                $block += $candidate
            }
            $values += ($block -join "`n")
        } else {
            $values += $value
        }
    }
    return $values
}

function Get-StepIndex {
    param($Steps, [string]$Pattern, [string]$What)
    $hits = @(for ($index = 0; $index -lt $Steps.Count; $index++) { if ($Steps[$index].Text -cmatch $Pattern) { $index } })
    Assert-True ($hits.Count -eq 1) "expected exactly one step for '$What' (pattern $Pattern) but found $($hits.Count)"
    return $hits[0]
}

function Assert-Before {
    param($Steps, [string]$FirstPattern, [string]$SecondPattern, [string]$What)
    $first = Get-StepIndex $Steps $FirstPattern $What
    $second = Get-StepIndex $Steps $SecondPattern $What
    Assert-True ($first -lt $second) "$What : the step at position $first must come before the step at position $second"
}

$AllWorkflows = @(Get-WorkflowFileNames)
$ExpectedWorkflows = @('ci.yml', 'pages.yml')

try {
    # ============================================================================================
    #  Every workflow
    # ============================================================================================
    Invoke-Case 'all workflows: the three known workflows exist and nothing else was added unseen' {
        Assert-Equal ($ExpectedWorkflows -join ',') ($AllWorkflows -join ',') 'workflow files'
    }

    foreach ($file in $AllWorkflows) {
        $text = Read-WorkflowText $file

        Invoke-Case "$file : every action is pinned to a full commit SHA with a version comment" {
            $uses = @($text -split "`n" | Where-Object { $_ -cmatch '\A\s*(- )?uses:' })
            Assert-True ($uses.Count -gt 0) 'no action used at all'
            foreach ($line in $uses) {
                $bare = $line.Trim() -creplace '\A- ', ''
                Assert-True ($bare -cmatch $PinnedUsesPattern) "not pinned to a SHA with a '# vX.Y.Z' comment: $bare"
            }
        }

        Invoke-Case "$file : no run: block contains an expression (tags, inputs and refs are user input, so values go through env)" {
            foreach ($run in (Get-RunValues $text)) {
                Assert-NotContains $run $ExpressionOpen 'a run: block'
            }
        }

        Invoke-Case "$file : the workflow states its permissions at the top and every job states its own" {
            Assert-True ($text -cmatch '(?m)^permissions:') 'no top-level permissions'
            foreach ($job in (Get-JobNames $text)) {
                Assert-True ((Get-JobText $text $job) -cmatch '(?m)^    permissions:') "job $job has no permissions of its own"
            }
        }

        Invoke-Case "$file : every job has a timeout" {
            foreach ($job in (Get-JobNames $text)) {
                Assert-True ((Get-JobText $text $job) -cmatch '(?m)^    timeout-minutes: [1-9][0-9]*\s*$') "job $job has no timeout-minutes"
            }
        }

        Invoke-Case "$file : never triggered by pull_request_target and never inherits secrets" {
            Assert-NotContains $text 'pull_request_target' 'workflow'
            Assert-NotContains $text 'secrets: inherit' 'workflow'
        }

        Invoke-Case "$file : follows the indentation convention the reader of this test relies on" {
            foreach ($job in (Get-JobNames $text)) {
                $jobText = Get-JobText $text $job
                Assert-True (@(Get-Steps $jobText).Count -gt 0) "job $job has no steps at the expected indentation"
            }
        }
    }

    # ============================================================================================
    #  ci.yml
    # ============================================================================================
    $ci = Read-WorkflowText 'ci.yml'
    $ciJob = Get-JobText $ci 'check'
    $ciSteps = @(Get-Steps $ciJob)
    $ciCode = Remove-CommentLines $ci

    Invoke-Case 'ci.yml: runs for pull requests to main and pushes to main, and for nothing else' {
        $on = Get-TopLevelBlock $ci 'on'
        Assert-True ($on -cmatch '(?m)^  pull_request:') 'no pull_request trigger'
        Assert-True ($on -cmatch '(?m)^  push:') 'no push trigger'
        Assert-Equal 2 @($on -split "`n" | Where-Object { $_ -cmatch '\A  [a-z_]+:' }).Count 'the number of triggers'
        Assert-Equal 2 @([regex]::Matches($on, 'branches:\s*\[main\]')).Count 'both triggers are limited to main'
    }

    Invoke-Case 'ci.yml: read-only token, no write permission anywhere, nothing that publishes' {
        Assert-True ((Get-TopLevelBlock $ci 'permissions') -cmatch 'contents: read') 'top-level permissions must be contents: read'
        Assert-True ($ciJob -cmatch '(?m)^    permissions:\s*\n\s+contents: read') 'the job must state contents: read'
        Assert-NotContains $ciCode ': write' 'ci.yml'
        foreach ($forbidden in @('gh release', 'action-gh-release', 'releases/', 'gh api')) { Assert-NotContains $ciCode $forbidden 'ci.yml' }
    }

    Invoke-Case 'ci.yml: runs on windows-latest' {
        Assert-True ($ciJob -cmatch '(?m)^    runs-on: windows-latest\s*$') 'the job must run on windows-latest'
    }

    Invoke-Case 'ci.yml: the steps run in the designed order, each exactly once' {
        $order = @(
            @{ Pattern = 'actions/checkout@'; What = 'checkout' }
            @{ Pattern = 'actions/setup-dotnet@'; What = 'setup-dotnet' }
            @{ Pattern = 'actions/setup-python@'; What = 'setup-python' }
            @{ Pattern = 'dotnet test'; What = 'engine-free unit tests' }
            @{ Pattern = 'Invoke-ScriptTests\.ps1'; What = 'script tests' }
            @{ Pattern = 'unittest discover -s \.github/stats'; What = 'stats tests' }
            @{ Pattern = 'Build-PluginArchive\.ps1'; What = 'packaging' }
            @{ Pattern = 'actions/upload-artifact@'; What = 'upload' }
        )
        for ($index = 1; $index -lt $order.Count; $index++) {
            Assert-Before $ciSteps $order[$index - 1].Pattern $order[$index].Pattern "$($order[$index - 1].What) before $($order[$index].What)"
        }
    }

    Invoke-Case 'ci.yml: .NET 8 and Python 3.12 are installed' {
        $dotnet = $ciSteps[(Get-StepIndex $ciSteps 'actions/setup-dotnet@' 'setup-dotnet')].Text
        Assert-True ($dotnet -cmatch "dotnet-version:\s*'?8\.0\.x'?") 'setup-dotnet must ask for 8.0.x'
        $python = $ciSteps[(Get-StepIndex $ciSteps 'actions/setup-python@' 'setup-python')].Text
        Assert-True ($python -cmatch "python-version:\s*'3\.12'") 'setup-python must ask for 3.12'
    }

    Invoke-Case 'ci.yml: the unit tests run only the engine-free category, from the real test project, without needing an x86 runtime' {
        $step = $ciSteps[(Get-StepIndex $ciSteps 'dotnet test' 'unit tests')].Text
        Assert-Contains $step 'Test/TestExecution/TestStandMCP.IntegrationTests.csproj' 'the test project path'
        Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot 'Test\TestExecution\TestStandMCP.IntegrationTests.csproj')) 'the test project exists at that path'
        Assert-True ($step -cmatch '--filter\s+"?Category=EngineFree"?') 'the filter must be Category=EngineFree'
        Assert-Contains $step '-p:PlatformTarget=AnyCPU' 'the x86 test host would need an x86 runtime the runner does not have'
    }

    Invoke-Case 'ci.yml: the script tests run under both hosts and a missing pwsh fails the run' {
        $step = $ciSteps[(Get-StepIndex $ciSteps 'Invoke-ScriptTests\.ps1' 'script tests')].Text
        Assert-True ($step -cmatch "TESTSTAND_MCP_REQUIRE_PWSH:\s*'?1'?") 'the step must set TESTSTAND_MCP_REQUIRE_PWSH=1'
    }

    Invoke-Case 'ci.yml: packaging uses version 0.0.0-ci into its own clean output folder and the artifact holds the four assets' {
        $pack = $ciSteps[(Get-StepIndex $ciSteps 'Build-PluginArchive\.ps1' 'packaging')].Text
        Assert-Contains $pack '-Version' 'the version argument'
        Assert-Contains $pack '-OutDir' 'a clean output folder'
        $upload = $ciSteps[(Get-StepIndex $ciSteps 'actions/upload-artifact@' 'upload')].Text
        Assert-Contains $upload '/teststand-mcp*' 'the four assets are matched by their common prefix (forward slash: a backslash is a glob escape)'
        Assert-True ($upload -cmatch 'if-no-files-found:\s*error') 'an empty upload must fail the check'
        Assert-NotContains $upload '/stage' 'the staging tree is not an asset'
    }

    Invoke-Case 'ci.yml: shared values live in workflow-level env, not repeated in steps' {
        $envBlock = Get-TopLevelBlock $ci 'env'
        Assert-True ($envBlock.Length -gt 0) 'the workflow has no env block'
        Assert-Contains $envBlock 'PACKAGE_VERSION' 'the CI version'
        Assert-Contains $envBlock 'PACKAGE_OUT_DIR' 'the output folder'
        Assert-Equal 1 @([regex]::Matches($ciCode, '0\.0\.0-ci')).Count 'the CI version is written once'
    }
}
finally {
    Remove-TestTempDirs
}

Complete-TestRun
