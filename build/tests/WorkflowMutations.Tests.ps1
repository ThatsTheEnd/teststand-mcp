# ============================================================================
#  WorkflowMutations.Tests.ps1 - proves that the workflow contract tests (Workflows.Tests.ps1) can FAIL.
#  A passing test that cannot fail protects nothing, and no actionlint or runner is at hand, so every rule
#  of that file gets a mutation here: a copy of the workflows in a temp folder with ONE deliberate defect
#  (an unpinned action, a write token on the build job, publishing by tag name, a cleanup that ends on a
#  failed probe, ...). Workflows.Tests.ps1 runs against the copy through its -WorkflowDirectory seam, in a
#  child process, and must exit 1 with a FAIL line naming the rule that the defect breaks. The unmutated
#  copy must pass, so a broken table or a broken copy cannot make every row look "caught".
#  Runs under Windows PowerShell 5.1 and PowerShell 7:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\tests\WorkflowMutations.Tests.ps1
#  ASCII only on purpose: 5.1 reads a BOM-less script as ANSI.
# ============================================================================
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WorkflowDir = Join-Path $RepoRoot '.github\workflows'
$ContractTests = Join-Path $PSScriptRoot 'Workflows.Tests.ps1'
$ChildTimeoutSeconds = 120
$MinimumMutations = 20
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

. (Join-Path $PSScriptRoot 'TestHarness.ps1')
$script:TempDirPrefix = 'WorkflowMutationsTests_'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'BuildCommon.psm1') -Force

$script:Mutations = @()

# One row of the table: Old must occur in the file (the FIRST occurrence is replaced) and New replaces it.
# Expect is a piece of the name of the Workflows.Tests case that the defect must break.
function Add-Mutation {
    param([string]$Name, [string]$File, [string]$Expect, [string]$Old, [string]$New)
    $script:Mutations += [pscustomobject]@{ Name = $Name; File = $File; Expect = $Expect; Old = $Old.Replace("`r`n", "`n"); New = $New.Replace("`r`n", "`n") }
}

# A temp folder with LF copies of every workflow, one of them edited.
function New-WorkflowCopy {
    param($Mutation)
    $dir = New-TempDir
    foreach ($file in (Get-ChildItem -LiteralPath $WorkflowDir -File -Filter '*.yml')) {
        $text = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
        if ($null -ne $Mutation -and $file.Name -ceq $Mutation.File) {
            $at = $text.IndexOf($Mutation.Old, [StringComparison]::Ordinal)
            if ($at -lt 0) { throw "the mutation '$($Mutation.Name)' does not apply: its text is not in $($Mutation.File):`n$($Mutation.Old)" }
            $text = $text.Substring(0, $at) + $Mutation.New + $text.Substring($at + $Mutation.Old.Length)
        }
        [IO.File]::WriteAllText((Join-Path $dir $file.Name), $text, $Utf8NoBom)
    }
    return $dir
}

# Runs the contract tests against a folder, in a child of the current host.
function Invoke-ContractTests {
    param([string]$Directory)
    $hostPath = (Get-Process -Id $PID).Path
    $result = Invoke-ChildProcess -FilePath $hostPath -TimeoutSeconds $ChildTimeoutSeconds `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ContractTests, '-WorkflowDirectory', $Directory)
    if ($result.TimedOut) { throw "the contract tests did not finish within $ChildTimeoutSeconds s" }
    return @{ ExitCode = $result.ExitCode; Output = ($result.Stdout + $result.Stderr) }
}

$CheckoutPin = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
$DownloadPin = 'actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2'
$SetupDotnetPin = 'actions/setup-dotnet@a98b56852c35b8e3190ac28c8c2271da59106c68 # v6.0.0'

# --- release.yml ---------------------------------------------------------------------------------------
Add-Mutation 'an action pinned by a movable tag' 'release.yml' 'every action is pinned' $DownloadPin 'actions/download-artifact@v8'
Add-Mutation 'a pin without its version comment' 'release.yml' 'every action is pinned' $SetupDotnetPin 'actions/setup-dotnet@a98b56852c35b8e3190ac28c8c2271da59106c68'
Add-Mutation 'an expression inside a run: block' 'release.yml' 'no run: block contains an expression' "Write-Host '::error::A release is cut by pushing a tag vX.Y.Z." "Write-Host '`${{ github.ref_name }}'; Write-Host '::error::A release is cut by pushing a tag vX.Y.Z."
Add-Mutation 'the release job loses its write permission' 'release.yml' 'only the release job may write' 'contents: write   # create' 'contents: read   # create'
Add-Mutation 'the package job gets a write token' 'release.yml' 'only the release job may write' "    permissions:`n      contents: read`n    outputs:" "    permissions:`n      contents: write`n    outputs:"
Add-Mutation 'an extra permission on the release job' 'release.yml' 'only the release job may write' 'contents: write   # create' "contents: write`n      id-token: write   # create"
Add-Mutation 'the release job no longer needs the package job' 'release.yml' 'the two jobs are split' "    needs: package`n" ''
Add-Mutation 'a dotnet step in the job that holds the write token' 'release.yml' 'the two jobs are split' "      - name: Download the four assets built by the package job" "      - uses: $SetupDotnetPin`n      - name: Download the four assets built by the package job"
Add-Mutation 'the tag filter narrowed to v*' 'release.yml' 'a pushed tag of any name starts it' "    tags: ['**']" "    tags: ['v*']"
Add-Mutation 'tag pushes queue per ref again' 'release.yml' 'ONE queue' "group: release-`${{ github.event_name == 'push' && 'publish' || github.ref }}" 'group: release-${{ github.ref }}'
Add-Mutation 'a running release may be cancelled' 'release.yml' 'ONE queue' 'cancel-in-progress: false' 'cancel-in-progress: true'
Add-Mutation 'publishing by tag name' 'release.yml' 'publishing is by the verifier release id' '"repos/$env:REPO/releases/$env:RELEASE_ID" -F draft=false' '"repos/$env:REPO/releases/tags/$env:RELEASE_TAG" -F draft=false'
Add-Mutation 'draft=false sent as a string' 'release.yml' 'publishing is by the verifier release id' '-F draft=false' '-f draft=false'
Add-Mutation 'publishing without the asset recheck' 'release.yml' 'publishing is by the verifier release id' " && steps.verify.outcome == 'success' && steps.recheck.outcome == 'success'" " && steps.verify.outcome == 'success'"
Add-Mutation 'publishing in a dry run' 'release.yml' 'publishing is by the verifier release id' "if: env.DRY_RUN != 'true' && steps.verify.outcome == 'success' && steps.recheck.outcome == 'success'" "if: steps.verify.outcome == 'success' && steps.recheck.outcome == 'success'"
Add-Mutation 'the first asset check asks for the wrong stage' 'release.yml' 'checked again just before and just after' '-Stage BeforePublish' '-Stage AfterPublish'
Add-Mutation 'the second asset check forgets the verified ids' 'release.yml' 'checked again just before and just after' '-ExpectedAssetIds $env:ASSET_IDS -ReleaseId $env:RELEASE_ID -Stage AfterPublish' '-ReleaseId $env:RELEASE_ID -Stage AfterPublish'
Add-Mutation 'the final fetch without the verified digest' 'release.yml' 'after publishing, releases/latest is fetched' ' -ExpectedArchiveSha256 $env:ARCHIVE_SHA256' ''
Add-Mutation 'the cleanup is not always()' 'release.yml' 'always() step' "if: always() && env.DRY_RUN == 'true' && needs.package.outputs.rehearsal == 'true'" "if: env.DRY_RUN == 'true' && needs.package.outputs.rehearsal == 'true'"
Add-Mutation 'the cleanup may run for a real release' 'release.yml' 'always() step' "if: always() && env.DRY_RUN == 'true' && needs.package.outputs.rehearsal == 'true'" "if: always() && needs.package.outputs.rehearsal == 'true'"
Add-Mutation 'the cleanup ends on its tolerated probe' 'release.yml' 'ends with an explicit exit' "          if (`$failed) { exit 1 }`n          exit 0`n" "          if (`$failed) { exit 1 }`n"
Add-Mutation 'the cleanup treats every probe failure as an absent tag' 'release.yml' 'always() step' "elseif (`$probe -match 'HTTP 404')" 'elseif ($true)'
Add-Mutation 'own-downloads not uploaded after a failure' 'release.yml' 'own-downloads is uploaded' "        if: always()`n        uses: actions/upload-artifact" '        uses: actions/upload-artifact'
Add-Mutation 'own-downloads uploaded under another name' 'release.yml' 'own-downloads is uploaded' '          name: own-downloads' '          name: downloads'
Add-Mutation 'the asset artifact kept for 90 days' 'release.yml' 'short-lived artifact' "          retention-days: 1`n" "          retention-days: 90`n"
Add-Mutation 'the release job checks out something else than the tagged commit' 'release.yml' 'short-lived artifact' "          ref: `${{ github.sha }}`n" ''
Add-Mutation 'the fault injection runs outside a dry run' 'release.yml' 'injected fault' "if: env.DRY_RUN == 'true' && env.INJECT_FAULT == 'corrupt-zip'" "if: env.INJECT_FAULT == 'corrupt-zip'"
Add-Mutation 'the verify step without a timeout' 'release.yml' 'has its own timeout' "        timeout-minutes: 30`n        run: |`n          `$rehearsal = (`$env:DRY_RUN -eq 'true')`n          & .\build\Assert-PublishedRelease.ps1 -Repo" "        run: |`n          `$rehearsal = (`$env:DRY_RUN -eq 'true')`n          & .\build\Assert-PublishedRelease.ps1 -Repo"
Add-Mutation 'a typo in a run: block' 'release.yml' 'valid PowerShell' "if (`$env:RELEASE_ID -notmatch '^[0-9]+`$') {" "if (`$env:RELEASE_ID -notmatch '^[0-9]+`$' {"
Add-Mutation 'the workflow bound to one repository' 'release.yml' 'nothing is bound to one repository' 'REPO: ${{ github.repository }}' 'REPO: ThatsTheEnd/teststand-mcp'
Add-Mutation 'releases created as non-drafts' 'release.yml' 'the draft is created as a draft' 'gh release create $env:RELEASE_TAG @assets --repo $env:REPO --draft --verify-tag' 'gh release create $env:RELEASE_TAG @assets --repo $env:REPO --verify-tag'
Add-Mutation 'a rehearsal decided by the shape of the tag' 'release.yml' 'the tag is user input' "`$rehearsal = (`$env:DRY_RUN -eq 'true')`n          & .\build\Assert-ReleaseTag.ps1" "`$rehearsal = (`$env:TAG -like '*-rehearsal')`n          & .\build\Assert-ReleaseTag.ps1"
Add-Mutation 'the token in workflow-level env' 'release.yml' 'verified with the token' "  DOTNET_NOLOGO: 'true'`n  DOTNET_CLI_TELEMETRY_OPTOUT: 'true'`n  OUT_DIR" "  DOTNET_NOLOGO: 'true'`n  GH_TOKEN: `${{ github.token }}`n  DOTNET_CLI_TELEMETRY_OPTOUT: 'true'`n  OUT_DIR"
Add-Mutation 'the provenance limit no longer stated' 'release.yml' 'header says what the verification does not prove' 'What the verification does NOT prove' 'What the verification proves'

# --- ci.yml --------------------------------------------------------------------------------------------
Add-Mutation 'ci: an action pinned by a movable tag' 'ci.yml' 'ci.yml : every action is pinned' $CheckoutPin 'actions/checkout@v7'
Add-Mutation 'ci: a write token' 'ci.yml' 'ci.yml: read-only token' "    permissions:`n      contents: read`n    steps:" "    permissions:`n      contents: write`n    steps:"
Add-Mutation 'ci: a job timeout too short for two hangs' 'ci.yml' 'a hanging script is stopped' 'timeout-minutes: 60' 'timeout-minutes: 30'
Add-Mutation 'ci: no per-script timeout' 'ci.yml' 'a hanging script is stopped' ' -TimeoutSeconds 600' ''
Add-Mutation 'ci: a missing pwsh no longer fails the run' 'ci.yml' 'the script tests run under both hosts' "TESTSTAND_MCP_REQUIRE_PWSH: '1'" "TESTSTAND_MCP_REQUIRE_PWSH: '0'"
Add-Mutation 'ci: triggered by pull_request_target' 'ci.yml' 'pull_request_target' "  pull_request:`n    branches: [main]" "  pull_request_target:`n    branches: [main]"
Add-Mutation 'ci: the wrong test category' 'ci.yml' 'the unit tests run only' 'Category=EngineFree' 'Category=Integration'
Add-Mutation 'ci: an x86 test host' 'ci.yml' 'the unit tests run only' ' -p:PlatformTarget=AnyCPU' ''

try {
    Invoke-Case 'mutations: the table has at least 20 named defects and every one names the rule it breaks' {
        Assert-True ($script:Mutations.Count -ge $MinimumMutations) "only $($script:Mutations.Count) mutations; at least $MinimumMutations are required"
        foreach ($mutation in $script:Mutations) {
            Assert-True ($mutation.Expect.Length -gt 0 -and $mutation.Name.Length -gt 0) 'every mutation has a name and an expected rule'
            Assert-True ($mutation.Old -cne $mutation.New) "the mutation '$($mutation.Name)' changes nothing"
        }
        Assert-Equal $script:Mutations.Count @($script:Mutations | ForEach-Object { $_.Name } | Select-Object -Unique).Count 'mutation names are unique'
    }

    Invoke-Case 'control: an unmutated copy of the workflows passes the contract tests (a broken copy cannot make every row look caught)' {
        $run = Invoke-ContractTests (New-WorkflowCopy $null)
        Assert-Equal 0 $run.ExitCode "exit code. Output was:`n$($run.Output)"
        Assert-Contains $run.Output 'All cases passed' 'the verdict'
    }

    foreach ($mutation in $script:Mutations) {
        $current = $mutation
        Invoke-Case "mutation: $($current.Name) -> fails '$($current.Expect)'" {
            $run = Invoke-ContractTests (New-WorkflowCopy $current)
            Assert-Equal 1 $run.ExitCode "exit code (the defect was not caught). Output was:`n$($run.Output)"
            $caught = [regex]::IsMatch($run.Output, '(?m)^FAIL  [^\r\n]*' + [regex]::Escape($current.Expect))
            Assert-True $caught "the contract tests failed, but no FAIL line names '$($current.Expect)'. Failing lines:`n$(@($run.Output -split '\r?\n' | Where-Object { $_ -cmatch '^FAIL' }) -join "`n")"
        }
    }
}
finally {
    Remove-TestTempDirs
}

Complete-TestRun
