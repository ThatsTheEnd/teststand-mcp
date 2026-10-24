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

# The value of a one-line key of a step ("if", "id", "timeout-minutes", ...), or $null.
function Get-StepField {
    param($Step, [string]$Field)
    $match = [regex]::Match($Step.Text, '(?m)^\s+(?:- )?' + [regex]::Escape($Field) + ':\s*(.+?)\s*$')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
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
$ExpectedWorkflows = @('ci.yml', 'pages.yml', 'release.yml')

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

    # ============================================================================================
    #  release.yml
    # ============================================================================================
    $release = Read-WorkflowText 'release.yml'
    $releaseCode = Remove-CommentLines $release
    $releaseJob = Get-JobText $release 'release'
    $releaseSteps = @(Get-Steps $releaseJob)
    $releaseEnv = Get-TopLevelBlock $releaseCode 'env'

    function Get-ReleaseStep {
        param([string]$Pattern, [string]$What)
        return $releaseSteps[(Get-StepIndex $releaseSteps $Pattern $What)]
    }

    Invoke-Case 'release.yml: a pushed tag of any name starts it (so a malformed tag is answered), and a manual run takes the dry-run inputs' {
        $on = Get-TopLevelBlock $releaseCode 'on'
        Assert-True ($on -cmatch "(?m)^  push:\s*\n    tags:\s*\[\s*'\*\*'\s*\]") "push must trigger on tags: ['**'] (a narrower filter would never answer V1.9.0)"
        Assert-NotContains $on 'branches' 'the push trigger'
        Assert-Equal 2 @($on -split "`n" | Where-Object { $_ -cmatch '\A  [a-z_]+:' }).Count 'the number of triggers'
        Assert-True ($on -cmatch '(?m)^  workflow_dispatch:') 'no workflow_dispatch trigger'
        foreach ($input in @('tag', 'dry_run', 'inject_fault')) { Assert-True ($on -cmatch "(?m)^      ${input}:") "workflow_dispatch has no input $input" }
        Assert-True ($on -cmatch '(?s)dry_run:.*?type: boolean') 'dry_run must be a boolean'
        Assert-True ($on -cmatch '(?s)inject_fault:.*?type: choice') 'inject_fault must be a choice'
        Assert-True ($on -cmatch '(?s)inject_fault:.*?options:\s*\n\s+- none\s*\n\s+- corrupt-zip') 'inject_fault offers none and corrupt-zip'
        Assert-True ($on -cmatch '(?s)      tag:.*?required: true') 'the rehearsal tag is required'
    }

    Invoke-Case 'release.yml: releases are serialised per ref and a running release is never cancelled' {
        $concurrency = Get-TopLevelBlock $releaseCode 'concurrency'
        Assert-True ($concurrency -cmatch 'group:\s*release-\$\{\{ github\.ref \}\}') 'the concurrency group must be release-<ref>'
        Assert-True ($concurrency -cmatch 'cancel-in-progress:\s*false') 'a release in progress must not be cancelled'
    }

    Invoke-Case 'release.yml: nothing by default, and the one job holds contents: write and nothing else' {
        Assert-True ((Get-TopLevelBlock $releaseCode 'permissions') -cmatch '(?m)^permissions:\s*\{\}\s*$') 'top-level permissions must be {}'
        $permissions = [regex]::Match($releaseJob, '(?m)^    permissions:\s*\n((?:      .+\n?)+)').Groups[1].Value
        $granted = @($permissions -split "`n" | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { ($_ -creplace '#.*\z', '').Trim() })
        Assert-Equal 'contents: write' ($granted -join '|') 'the permissions of the release job'
    }

    Invoke-Case 'release.yml: runs on windows-latest, in the designed order, each step exactly once' {
        Assert-True ($releaseJob -cmatch '(?m)^    runs-on: windows-latest\s*$') 'the job must run on windows-latest'
        $order = @(
            @{ Pattern = 'actions/checkout@'; What = 'checkout' }
            @{ Pattern = '::error::A release is cut by pushing a tag'; What = 'refuse a manual real release' }
            @{ Pattern = 'Assert-ReleaseTag\.ps1'; What = 'tag gate' }
            @{ Pattern = 'A dry run needs a rehearsal tag'; What = 'require a rehearsal tag' }
            @{ Pattern = 'actions/setup-dotnet@'; What = 'setup-dotnet' }
            @{ Pattern = 'Build-PluginArchive\.ps1'; What = 'packaging' }
            @{ Pattern = 'gh release create'; What = 'create the draft' }
            @{ Pattern = '--clobber'; What = 'inject the fault' }
            @{ Pattern = '(?m)^\s+id: verify\s*$'; What = 'verify the draft' }
            @{ Pattern = '(?m)^\s+id: publish\s*$'; What = 'publish' }
            @{ Pattern = '(?m)^\s+id: latest\s*$'; What = 'fetch releases/latest' }
            @{ Pattern = '-X DELETE'; What = 'clean up the rehearsal' }
            @{ Pattern = 'actions/upload-artifact@'; What = 'upload own-downloads' }
        )
        for ($index = 1; $index -lt $order.Count; $index++) {
            Assert-Before $releaseSteps $order[$index - 1].Pattern $order[$index].Pattern "$($order[$index - 1].What) before $($order[$index].What)"
        }
        Assert-Equal ($releaseSteps.Count - 1) (Get-StepIndex $releaseSteps 'actions/upload-artifact@' 'upload') 'the upload of own-downloads is the last step'
    }

    Invoke-Case 'release.yml: the tag is user input and reaches the gate only through env, the dry run only through a manual run' {
        Assert-True ($releaseEnv -cmatch "TAG:\s*\$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.tag \|\| github\.ref_name \}\}") 'TAG must be the dispatch input or the pushed ref name'
        Assert-True ($releaseEnv -cmatch "DRY_RUN:\s*\$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.dry_run \}\}") 'DRY_RUN must be true only for a manual run that asked for it'
        Assert-True ($releaseEnv -cmatch "INJECT_FAULT:\s*\$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.inject_fault \|\| 'none' \}\}") 'INJECT_FAULT must be none for a push'
        $gate = (Get-ReleaseStep 'Assert-ReleaseTag\.ps1' 'tag gate').Text
        Assert-Contains $gate '-Tag $env:TAG' 'the gate gets the tag from the environment'
        Assert-Contains $gate '$rehearsal = ($env:DRY_RUN -eq ''true'')' 'a rehearsal is whatever DRY_RUN says, never the shape of the tag'
        Assert-Contains $gate '-Rehearsal:$rehearsal' 'the gate is told about the rehearsal'
    }

    Invoke-Case 'release.yml: a manual run that is not a dry run is refused before anything else, and a dry run needs a rehearsal tag' {
        $refuse = Get-ReleaseStep '::error::A release is cut by pushing a tag' 'refusal'
        Assert-True ((Get-StepField $refuse 'if') -cmatch "env\.EVENT_NAME == 'workflow_dispatch' && env\.DRY_RUN != 'true'") 'the refusal applies to a manual run without dry_run'
        $rehearsal = Get-ReleaseStep 'A dry run needs a rehearsal tag' 'rehearsal tag requirement'
        $condition = Get-StepField $rehearsal 'if'
        Assert-Contains $condition "env.DRY_RUN == 'true'" 'only for a dry run'
        Assert-Contains $condition "steps.gate.outputs.rehearsal != 'true'" 'fails when the gate did not see a rehearsal tag'
        Assert-Contains $releaseEnv 'EVENT_NAME:' 'the event name reaches the steps through env'
    }

    Invoke-Case 'release.yml: the draft is created as a draft, from a verified tag when real, and nothing publishes before the verification' {
        $create = (Get-ReleaseStep 'gh release create' 'create the draft').Text
        $createCalls = @($create -split "`n" | Where-Object { $_ -cmatch 'gh release create' })
        Assert-Equal 2 $createCalls.Count 'the number of gh release create calls (a dry run and a real one)'
        foreach ($call in $createCalls) { Assert-Contains $call ' --draft ' 'every release is created as a draft' }
        Assert-Equal 1 @($createCalls | Where-Object { $_ -cmatch '--target' }).Count 'only the dry run names a target commit (its tag does not exist)'
        Assert-Equal 1 @($createCalls | Where-Object { $_ -cmatch '--verify-tag' }).Count 'only the real release insists on its pushed tag'
        Assert-NotContains $releaseCode 'action-gh-release' 'release.yml (gh is used, no third-party release action)'
        Assert-NotContains $releaseCode 'gh release edit' 'release.yml (publishing is by release id, never by tag name)'
        Assert-NotContains $releaseCode '--draft=false' 'release.yml'
        $publishIndex = Get-StepIndex $releaseSteps '(?m)^\s+id: publish\s*$' 'publish'
        for ($index = 0; $index -lt $publishIndex; $index++) {
            Assert-True ($releaseSteps[$index].Text -cnotmatch 'draft=false|make_latest') "step $($releaseSteps[$index].Name) publishes before the verification"
        }
    }

    Invoke-Case 'release.yml: the draft is verified with the token as a user would download it, and every download is recorded' {
        $verify = (Get-ReleaseStep '(?m)^\s+id: verify\s*$' 'verify').Text
        Assert-Contains $verify 'Assert-PublishedRelease.ps1' 'the verifier script'
        Assert-Contains $verify '-Repo $env:REPO' 'the repository of the run, so a fork verifies itself'
        Assert-Contains $verify '-Tag $env:RELEASE_TAG' 'the tag the gate validated'
        Assert-Contains $verify '-Token $env:GH_TOKEN' 'a draft is readable only with the token'
        Assert-Contains $verify '-OwnDownloadsPath $env:OWN_DOWNLOADS_FILE' 'every verify attempt is recorded'
        Assert-Contains $verify '-Rehearsal:$rehearsal' 'a dry run verifies the rehearsal tag'
        Assert-True ($verify -cmatch 'GH_TOKEN:\s*\$\{\{ github\.token \}\}') 'the token comes from github.token, set on this step only'
        Assert-True ($releaseEnv -cnotmatch 'github\.token|secrets\.') 'no token in workflow-level env'
    }

    Invoke-Case 'release.yml: publishing is by the verifier release id, only after a successful verify, and never in a dry run' {
        $publish = Get-ReleaseStep '(?m)^\s+id: publish\s*$' 'publish'
        $condition = Get-StepField $publish 'if'
        Assert-Contains $condition "steps.verify.outcome == 'success'" 'only after the verify step succeeded'
        Assert-Contains $condition "env.DRY_RUN != 'true'" 'never in a dry run'
        Assert-True ($publish.Text -cmatch 'RELEASE_ID:\s*\$\{\{ steps\.verify\.outputs\.release_id \}\}') 'the id is the verifier output'
        Assert-Contains $publish.Text '-X PATCH' 'the release is edited through the API'
        Assert-Contains $publish.Text 'releases/$env:RELEASE_ID' 'the release is addressed by its id'
        Assert-Contains $publish.Text '-F draft=false' 'draft=false as a JSON boolean (-F), not the string "false" (-f)'
        Assert-Contains $publish.Text '-f make_latest=true' 'the release is marked latest'
        Assert-NotContains $publish.Text 'RELEASE_TAG' 'the publish step (a tag name could select another release)'
        Assert-Contains $publish.Text '-notmatch ''^[0-9]+$''' 'a missing or malformed id stops the step before the API call'
    }

    Invoke-Case 'release.yml: after publishing, releases/latest is fetched the way users fetch it and compared with the verified archive' {
        $latest = Get-ReleaseStep '(?m)^\s+id: latest\s*$' 'latest'
        $condition = Get-StepField $latest 'if'
        Assert-Contains $condition "steps.publish.outcome == 'success'" 'only after the publish step succeeded'
        Assert-Contains $condition "env.DRY_RUN != 'true'" 'never in a dry run'
        Assert-True ($latest.Text -cmatch 'ARCHIVE_SHA256:\s*\$\{\{ steps\.verify\.outputs\.archive_sha256 \}\}') 'the expected hash is the verifier output'
        Assert-Contains $latest.Text '-Latest' 'the public latest download'
        Assert-Contains $latest.Text '-ExpectedArchiveSha256 $env:ARCHIVE_SHA256' 'the verified archive digest is passed'
        Assert-Contains $latest.Text '-Repo $env:REPO' 'the repository of the run'
        Assert-Contains $latest.Text '-OwnDownloadsPath $env:OWN_DOWNLOADS_FILE' 'the public fetch is recorded'
    }

    Invoke-Case 'release.yml: the injected fault corrupts the uploaded zip after the upload, for a dry run only' {
        $inject = Get-ReleaseStep '--clobber' 'inject'
        $condition = Get-StepField $inject 'if'
        Assert-Contains $condition "env.DRY_RUN == 'true'" 'only in a dry run'
        Assert-Contains $condition "env.INJECT_FAULT == 'corrupt-zip'" 'only when asked'
        Assert-Contains $inject.Text 'gh release upload' 'the zip asset is replaced on the draft'
        Assert-Contains $inject.Text '$ReleaseArchiveName' 'the asset name comes from the release contract module'
    }

    Invoke-Case 'release.yml: a dry run deletes its draft and its tag in an always() step that can never touch a real release' {
        $cleanup = Get-ReleaseStep '-X DELETE' 'cleanup'
        $condition = Get-StepField $cleanup 'if'
        Assert-Contains $condition 'always()' 'cleanup runs after a failed verify too'
        Assert-Contains $condition "env.DRY_RUN == 'true'" 'dry runs only'
        Assert-Contains $condition "steps.gate.outputs.rehearsal == 'true'" 'only for a tag the gate accepted as a rehearsal'
        Assert-Contains $cleanup.Text 'releases/$id' 'a draft is deleted by its id'
        Assert-Contains $cleanup.Text '.draft == true' 'only drafts are deleted'
        Assert-Contains $cleanup.Text 'git/refs/tags/' 'the tag is deleted too'
    }

    Invoke-Case 'release.yml: own-downloads is uploaded under the exact name the collector reads, even when the run failed' {
        $upload = $releaseSteps[$releaseSteps.Count - 1]
        Assert-Equal 'always()' (Get-StepField $upload 'if') 'the upload must run on failure too'
        Assert-True ($upload.Text -cmatch '(?m)^\s+name: own-downloads\s*$') 'the artifact must be named own-downloads'
        Assert-True ($upload.Text -cmatch 'path:\s*\$\{\{ env\.OWN_DOWNLOADS_FILE \}\}') 'the artifact holds the record file'
        Assert-True ($releaseEnv -cmatch '(?m)^  OWN_DOWNLOADS_FILE:\s*\S*[/\\]own-downloads\.json\s*$') 'the file is called own-downloads.json and sits outside the release assets folder'
        Assert-True ($releaseEnv -cnotmatch 'OWN_DOWNLOADS_FILE:\s*\$\{\{') 'a literal path, so the verifier and the upload cannot disagree'
        $collector = [IO.File]::ReadAllText((Join-Path $RepoRoot '.github\stats\collect.py'))
        Assert-Contains $collector 'OWN_DOWNLOADS_ARTIFACT = "own-downloads"' 'the collector reads the artifact of this name'
        Assert-Contains $collector 'OWN_DOWNLOADS_FILE = "own-downloads.json"' 'the collector reads the file of this name'
        Assert-Contains $collector 'RELEASE_WORKFLOW_PATH = ".github/workflows/release.yml"' 'the collector accepts runs of this workflow file'
    }

    Invoke-Case 'release.yml: every step that calls GitHub or a build script has its own timeout' {
        foreach ($step in $releaseSteps) {
            if ($step.Text -cmatch 'gh (api|release)|Assert-PublishedRelease|Build-PluginArchive|Assert-ReleaseTag') {
                Assert-True ($null -ne (Get-StepField $step 'timeout-minutes')) "step '$($step.Name)' has no timeout-minutes"
            }
        }
    }

    foreach ($file in @('ci.yml', 'release.yml')) {
        Invoke-Case "$file : every run: block is valid PowerShell (their default shell), because no runner is at hand to find a typo" {
            $text = Read-WorkflowText $file
            Assert-True ((Get-TopLevelBlock $text 'defaults') -cmatch 'shell:\s*powershell') 'the default shell must be powershell'
            $blocks = @(Get-RunValues $text)
            Assert-True ($blocks.Count -gt 0) 'no run: block found'
            foreach ($block in $blocks) {
                $tokens = $null
                $errors = $null
                [void][System.Management.Automation.Language.Parser]::ParseInput($block, [ref]$tokens, [ref]$errors)
                Assert-Equal 0 $errors.Count "parse errors in a run: block of ${file}: $(@($errors | ForEach-Object { $_.Message }) -join '; ')`n$block"
            }
        }
    }

    Invoke-Case 'release.yml and ci.yml: nothing is bound to one repository, so the fork rehearsal runs the same files' {
        foreach ($code in @($releaseCode, $ciCode)) {
            Assert-NotContains $code 'Zuehlke' 'a workflow'
            Assert-NotContains $code 'teststand-mcp/' 'a workflow'
        }
        Assert-True ($releaseEnv -cmatch 'REPO:\s*\$\{\{ github\.repository \}\}') 'the repository is github.repository'
    }
}
finally {
    Remove-TestTempDirs
}

Complete-TestRun
