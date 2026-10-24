# ============================================================================
#  BuildPluginArchive.Tests.ps1 - plain PowerShell asserts for build/Build-PluginArchive.ps1 and
#  build/PluginArchive.psm1 (plus the child-process helpers of build/BuildCommon.psm1).
#  Runs under Windows PowerShell 5.1 and PowerShell 7:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\tests\BuildPluginArchive.Tests.ps1
#  Prints PASS/FAIL per case and exits non-zero when any case fails.
#  Every row of the Gherkin "The script stops with a fix" outline has its own case: the fault is
#  planted, and the failure text must name the fault (What), say why it matters (Why) and give the
#  command that fixes it (Fix). Faults that need no publish run on a tiny fake tree, so they are fast.
#  The ONE real end-to-end run per layout is opt-in (TESTSTAND_MCP_PACKAGE_E2E=1): it publishes the
#  real exe (about 180 MB for the folder layout).
#  ASCII only on purpose: 5.1 reads a BOM-less script as ANSI.
# ============================================================================
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$BuildDir = Join-Path $RepoRoot 'build'
$ScriptPath = Join-Path $BuildDir 'Build-PluginArchive.ps1'
$HostPath = (Get-Process -Id $PID).Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$SampleCommit = ('0123456789abcdef' * 2) + '01234567'   # 40 hex characters
$SampleVersion = '1.9.0'
$ForeignExe = Join-Path $env:SystemRoot 'System32\cmd.exe'   # an exe whose ProductVersion is not ours

. (Join-Path $PSScriptRoot 'TestHarness.ps1')
$script:TempDirPrefix = 'BuildPluginArchiveTests_'

# --- Asserts ---------------------------------------------------------------------------------------
# The message a body throws, or $null when it does not throw.
function Get-ThrownMessage {
    param([scriptblock]$Body)
    try { & $Body } catch { return $_.Exception.Message }
    return $null
}

# Passes only when the body fails with the three labelled parts and every needle appears in the text.
function Assert-FailsWith {
    param([scriptblock]$Body, [string[]]$Needles)
    $text = Get-ThrownMessage $Body
    if ($null -eq $text) { throw 'expected a failure but none was thrown' }
    foreach ($label in @('What', 'Why', 'Fix')) {
        Assert-True ($text -cmatch "(?m)^${label}: +\S") "failure has no '${label}:' line with content. Failure was:`n$text"
    }
    foreach ($needle in $Needles) { Assert-Contains $text $needle 'failure text' }
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

try {
    Import-Module (Join-Path $BuildDir 'BuildCommon.psm1') -Force
    Import-Module (Join-Path $BuildDir 'PluginArchive.psm1') -Force

    # ======================================================================
    #  Child-process helpers (BuildCommon)
    # ======================================================================
    Invoke-Case 'child process: arguments with spaces and quotes arrive as single elements' {
        $echo = Join-Path (New-TempDir) 'echo-args.ps1'
        Write-TextFile $echo 'param($a, $b); [Console]::Out.Write("[$a][$b]")'
        $result = Invoke-ChildProcess -FilePath $HostPath -TimeoutSeconds 60 -ArgumentList @('-NoProfile', '-File', $echo, 'one two', 'say "hi"')
        Assert-Equal 0 $result.ExitCode 'exit code'
        Assert-Equal '[one two][say "hi"]' $result.Stdout 'both arguments arrive whole'
        $quoted = ConvertTo-ArgumentElement 'C:\Program Files\x y\'
        Assert-Equal '"C:\Program Files\x y\\"' $quoted 'a trailing backslash is doubled inside the quotes'
        Assert-Equal 'plain' (ConvertTo-ArgumentElement 'plain') 'plain text stays unquoted'
        Assert-Equal '""' (ConvertTo-ArgumentElement '') 'the empty argument is an empty pair of quotes'
    }

    Invoke-Case 'child process: a program that outlives its timeout is stopped and reported' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-ChildProcess -FilePath $HostPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -TimeoutSeconds 2
        Assert-True $result.TimedOut 'the program was not reported as timed out'
        Assert-True ($null -eq $result.ExitCode) 'a timed-out program has no exit code'
        Assert-True ($clock.Elapsed.TotalSeconds -lt 60) "the timeout took $($clock.Elapsed.TotalSeconds) s"
    }

    Invoke-Case 'child process: a non-zero exit is reported, not thrown, and stdout and stderr are captured separately' {
        $result = Invoke-ChildProcess -FilePath $HostPath -TimeoutSeconds 60 `
            -ArgumentList @('-NoProfile', '-Command', '[Console]::Out.Write("to-out"); [Console]::Error.Write("to-err"); exit 3')
        Assert-Equal 3 $result.ExitCode 'exit code'
        Assert-Equal 'to-out' $result.Stdout 'stdout'
        Assert-Equal 'to-err' $result.Stderr 'stderr'
    }

    # ======================================================================
    #  Inputs and the layout table
    # ======================================================================
    Invoke-Case 'layout: folder is the default and every layout names its publish arguments and bin files' {
        Assert-Equal 'folder' (Get-DefaultArchiveLayout) 'default layout (docs/validation/self-contained-x86.md)'
        foreach ($name in (Get-ArchiveLayoutName)) {
            $layout = Get-ArchiveLayout $name
            foreach ($key in @('PublishArguments', 'BinRequired', 'BinForbidden')) { Assert-True ($layout.ContainsKey($key)) "layout $name has no $key" }
            Assert-True ($layout.PublishArguments -contains '--self-contained') "layout $name must decide --self-contained"
        }
        Assert-True ((Get-ArchiveLayoutName) -contains 'single-file') 'single-file is an explicit option'
        Assert-True ((Get-ArchiveLayoutName) -contains 'framework-dependent') 'framework-dependent is an explicit option'
    }

    Invoke-Case 'layout: an unknown layout fails and lists the valid ones' {
        Assert-FailsWith { Get-ArchiveLayout 'zip-of-doom' } @("Unknown exe layout 'zip-of-doom'", 'folder', 'single-file', 'framework-dependent', '-Layout')
    }

    Invoke-Case 'version: X.Y.Z and X.Y.Z-suffix are accepted, anything else is refused with the fix' {
        foreach ($good in @('1.9.0', '0.0.0-ci', '10.20.30', '1.9.0-rc.1')) { Assert-BuildVersion $good }
        foreach ($bad in @('', 'v1.9.0', '1.9', '1.9.0.1', '01.9.0', '1.9.0-', '1.9.0 ', '1.9.0-ci/x')) {
            $text = Get-ThrownMessage { Assert-BuildVersion $bad }
            Assert-True ($null -ne $text) "version [$bad] was accepted"
            Assert-Contains $text 'Fix:' "failure for [$bad]"
        }
    }

    Invoke-Case 'version: the numeric core drops the pre-release suffix' {
        Assert-Equal '0.0.0' (Get-VersionCore '0.0.0-ci') 'core of 0.0.0-ci'
        Assert-Equal '1.9.0' (Get-VersionCore '1.9.0') 'core of 1.9.0'
    }

    Invoke-Case 'commit: only a full lower-case 40-character SHA is accepted' {
        Assert-BuildCommit $SampleCommit
        foreach ($bad in @('', $SampleCommit.Substring(1), ($SampleCommit + '0'), $SampleCommit.ToUpperInvariant(), ('g' * 40))) {
            Assert-FailsWith { Assert-BuildCommit $bad } @('40-character', 'git rev-parse HEAD')
        }
    }

    Invoke-Case 'tag: v<version> and its rehearsal are accepted, another version is refused' {
        Assert-BuildTag -Tag 'v1.9.0' -Version '1.9.0'
        Assert-BuildTag -Tag 'v1.9.0-rehearsal' -Version '1.9.0'
        Assert-BuildTag -Tag 'v0.0.0-ci' -Version '0.0.0-ci'
        Assert-FailsWith { Assert-BuildTag -Tag 'v1.8.0' -Version '1.9.0' } @("'v1.8.0'", '1.9.0', '-Tag v1.9.0')
        Assert-FailsWith { Assert-BuildTag -Tag '' -Version '1.9.0' } @('Fix:')
    }

    # ======================================================================
    #  Outline row: plugin.json lacks the "version": "0.0.0" placeholder
    # ======================================================================
    Invoke-Case 'fault: plugin.json without the version placeholder' {
        $dir = New-TempDir
        $path = Join-Path $dir 'plugin.json'
        Write-TextFile $path "{ `"name`": `"x`", `"version`": `"1.2.3`" }"
        Assert-FailsWith { Assert-ManifestPlaceholder -ManifestPath $path } @($path, '0 occurrences', '0.0.0', 'git checkout')
    }

    Invoke-Case 'fault: plugin.json with the placeholder twice is just as wrong' {
        $dir = New-TempDir
        $path = Join-Path $dir 'plugin.json'
        Write-TextFile $path "{ `"version`": `"0.0.0`", `"nested`": { `"version`": `"0.0.0`" } }"
        Assert-FailsWith { Assert-ManifestPlaceholder -ManifestPath $path } @('2 occurrences')
    }

    Invoke-Case 'placeholder: the committed manifest carries exactly one, wherever whitespace puts it' {
        Assert-ManifestPlaceholder -ManifestPath (Join-Path $RepoRoot 'plugin\.claude-plugin\plugin.json')
        $match = Find-VersionPlaceholder -Text '{"version":"0.0.0"}' -Path 'inline'
        Assert-Equal '"version":"0.0.0"' $match.Value 'compact JSON is found too'
    }

    # ======================================================================
    #  Outline row: the skill source check fails
    # ======================================================================
    Invoke-Case 'fault: the skill source check fails' {
        $emptyRepo = New-TempDir
        Assert-FailsWith { Assert-SkillSources -RepoRoot $emptyRepo } @('Test-SkillSources.ps1', 'FAIL', 'teststand-rules skill')
    }

    Invoke-Case 'skill sources: the real repository passes the check' {
        Assert-SkillSources -RepoRoot $RepoRoot
    }

    # ======================================================================
    #  Outline row: a registered tool is not classified
    # ======================================================================
    Invoke-Case 'fault: a registered tool is not classified' {
        $dir = New-TempDir
        $registry = Join-Path $dir 'Registry.cs'
        $classes = Join-Path $dir 'tool-classes.json'
        Write-TextFile $registry "Register(`"get_a`", `"a`")`nRegister(`"set_new_tool`", `"b`")`n"
        Write-TextFile $classes '{ "allow": ["get_a"], "prompt": [] }'
        Assert-FailsWith { Assert-AllToolsClassified -ClassesPath $classes -RegistryPath $registry } @('E_UNCLASSIFIED', 'set_new_tool', $classes)
    }

    Invoke-Case 'classification: the real registry and the committed classification agree' {
        Assert-AllToolsClassified -ClassesPath (Join-Path $RepoRoot 'plugin\hooks\tool-classes.json') -RegistryPath (Join-Path $RepoRoot 'src\Tools\TestStandToolRegistry.cs')
    }

    # ======================================================================
    #  Outline row: the published exe does not report the requested version
    # ======================================================================
    Invoke-Case 'fault: the published exe does not report the requested version' {
        Assert-FailsWith { Assert-PublishedVersion -ExePath $ForeignExe -Version $SampleVersion -Commit $SampleCommit } `
            @('ProductVersion', $SampleVersion, $SampleCommit, 'Directory.Build.props')
    }

    # ======================================================================
    #  Publish
    # ======================================================================
    Invoke-Case 'publish: a failing dotnet publish is reported with its output and the command to reproduce it' {
        $emptyRepo = New-TempDir
        $publishDir = Join-Path (New-TempDir) 'publish'
        Assert-FailsWith { Publish-PluginExe -RepoRoot $emptyRepo -Layout 'folder' -Version $SampleVersion -Commit $SampleCommit -PublishDir $publishDir } `
            @('dotnet publish failed', 'exit code', 'dotnet publish TestStandMCP.csproj')
    }

    # ======================================================================
    #  The script itself
    # ======================================================================
    Invoke-Case 'script: a malformed version stops it with exit code 1 and the three parts, before anything is built' {
        $outDir = Join-Path (New-TempDir) 'out'
        $result = Invoke-ChildProcess -FilePath $HostPath -TimeoutSeconds 120 `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-Version', 'one.nine', '-OutDir', $outDir)
        Assert-Equal 1 $result.ExitCode 'exit code'
        foreach ($label in @('What', 'Why', 'Fix')) { Assert-True ($result.Stdout -cmatch "(?m)^${label}: +\S") "no '${label}:' line in:`n$($result.Stdout)" }
        Assert-Contains $result.Stdout "'one.nine'" 'output'
        Assert-True (-not (Test-Path -LiteralPath $outDir)) 'nothing may be created for a refused input'
    }

    Invoke-Case 'script: an unknown layout is refused before the source checks run' {
        $result = Invoke-ChildProcess -FilePath $HostPath -TimeoutSeconds 120 `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-Version', '0.0.0-ci', '-Commit', $SampleCommit, '-Layout', 'nope', '-OutDir', (Join-Path (New-TempDir) 'out'))
        Assert-Equal 1 $result.ExitCode 'exit code'
        Assert-Contains $result.Stdout "Unknown exe layout 'nope'" 'output'
        Assert-NotContains $result.Stdout '[1/' 'no step may have started'
    }
} finally {
    Remove-TestTempDirs
}

Complete-TestRun
