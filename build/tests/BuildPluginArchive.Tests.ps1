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
    Import-Module (Join-Path $BuildDir 'ReleaseAssets.psm1') -Force
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
    #  Staging: a tiny fake publish output, the real repository sources
    # ======================================================================
    $Release = @{ tag = "v$SampleVersion"; version = $SampleVersion; commit = $SampleCommit; built = '2026-10-24T12:00:00Z'; run = 'local' }

    # What dotnet publish leaves: the exe and runtime files, plus the files the csproj copies into every
    # output (CLAUDE.md, README.md, scripts, .claude) that the archive must take from the repository instead.
    function New-FakePublishDir {
        param([string[]]$Without = @(), [string[]]$Extra = @())
        $dir = New-TempDir
        $files = @('TestStandMCP.exe', 'appsettings.json', 'TestStandMCP.runtimeconfig.json', 'coreclr.dll', 'Other.dll',
            'CLAUDE.md', 'README.md', 'scripts/Test-LoadPrototype.ps1', '.claude/agents/stale-publish-agent.md') + $Extra
        foreach ($name in $files) {
            if ($Without -contains $name) { continue }
            Write-TextFile (Join-Path $dir $name) "fake $name"
        }
        return $dir
    }

    function New-StageFrom {
        param([string]$PublishDir, [string]$Layout = 'folder', [hashtable]$ReleaseRecord = $Release)
        $stage = Join-Path (New-TempDir) 'stage'
        New-StagedPlugin -RepoRoot $RepoRoot -PublishDir $PublishDir -StageDir $stage -Layout $Layout -Release $ReleaseRecord
        return $stage
    }

    # One staged tree is built once; every fault case works on its own copy.
    $script:StagedTemplate = $null
    function New-StagedCopy {
        if ($null -eq $script:StagedTemplate) { $script:StagedTemplate = New-StageFrom -PublishDir (New-FakePublishDir) }
        $copy = Join-Path (New-TempDir) 'stage'
        Copy-Item -LiteralPath $script:StagedTemplate -Destination $copy -Recurse
        return $copy
    }

    function Assert-StageFault {
        param([scriptblock]$Plant, [string[]]$Needles, [string]$Layout = 'folder')
        $stage = New-StagedCopy
        & $Plant $stage
        Assert-FailsWith { Assert-StagedPlugin -RepoRoot $RepoRoot -StageDir $stage -Layout $Layout -Release $Release } $Needles
    }

    Invoke-Case 'staging: the staged tree matches the layout of spec AC-4 and passes every assertion' {
        $stage = New-StagedCopy
        Assert-StagedPlugin -RepoRoot $RepoRoot -StageDir $stage -Layout 'folder' -Release $Release
        $files = Get-FileSet $stage
        foreach ($required in @('.claude-plugin/plugin.json', '.mcp.json', 'VERSION.txt', 'skills/teststand-rules/SKILL.md', 'hooks/hooks.json',
                'bin/TestStandMCP.exe', 'bin/appsettings.json', 'bin/TestStandMCP.runtimeconfig.json', 'bin/CLAUDE.md')) {
            Assert-True ($files -ccontains $required) "the staged tree has no $required"
        }
        Assert-Equal 0 @($files | Where-Object { $_ -like 'build/*' -or $_ -like '*/build/*' }).Count 'files from build/'
        Assert-True ($files -cnotcontains 'bin/README.md') 'the publish output''s README.md must not be staged'
        Assert-True ($files -cnotcontains 'bin/.claude/agents/stale-publish-agent.md') 'bin/.claude/agents comes from the repository, not the publish output'
    }

    Invoke-Case 'staging: bin/scripts holds exactly the two generators and the template, hooks exactly the runtime hook files' {
        $files = Get-FileSet (New-StagedCopy)
        Assert-Equal 'generate_teststand_doc.py,generate_teststand_presentation.py,presentation_template.html' ((@($files | Where-Object { $_ -like 'bin/scripts/*' } | ForEach-Object { $_.Substring('bin/scripts/'.Length) })) -join ',') 'bin/scripts'
        Assert-Equal 'allow-readonly.ps1,hook-common.ps1,hooks.json,platform-guard.ps1,tool-classes.json,update-notify.ps1' ((@($files | Where-Object { $_ -like 'hooks/*' } | ForEach-Object { $_.Substring('hooks/'.Length) })) -join ',') 'hooks'
    }

    Invoke-Case 'staging: the plugin agents are the converted source agents, the direct agents are unchanged and ship link-agents.bat' {
        $stage = New-StagedCopy
        $sources = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot '.claude\agents') -File -Filter '*.md')
        Assert-True ($sources.Count -ge 3) 'the repository should have its agents'
        Assert-Equal $sources.Count (Get-FileSet (Join-Path $stage 'agents')).Count 'plugin agent count'
        foreach ($source in $sources) {
            $plugin = [IO.File]::ReadAllText((Join-Path $stage "agents\$($source.Name)"))
            Assert-NotContains $plugin 'mcp__teststand__' "plugin agent $($source.Name)"
            Assert-True ($plugin.IndexOf('CLAUDE.md', [StringComparison]::OrdinalIgnoreCase) -lt 0) "plugin agent $($source.Name) mentions CLAUDE.md"
            Assert-Equal (Get-FileSha256 $source.FullName) (Get-FileSha256 (Join-Path $stage "bin\.claude\agents\$($source.Name)")) "direct agent $($source.Name) byte for byte"
        }
        Assert-Contains ([IO.File]::ReadAllText((Join-Path $stage 'agents\teststand-doc-generator.md'))) 'mcp__plugin_teststand-mcp_teststand__' 'the plugin tool prefix'
        Assert-True (Test-Path -LiteralPath (Join-Path $stage 'bin\.claude\agents\link-agents.bat')) 'link-agents.bat'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage 'agents\link-agents.bat'))) 'link-agents.bat is not a plugin agent'
    }

    Invoke-Case 'staging: plugin.json is the source with only the version replaced, byte for byte' {
        $stage = New-StagedCopy
        $source = [IO.File]::ReadAllBytes((Join-Path $RepoRoot 'plugin\.claude-plugin\plugin.json'))
        $staged = [IO.File]::ReadAllBytes((Join-Path $stage '.claude-plugin\plugin.json'))
        $latin1 = [Text.Encoding]::GetEncoding(28591)
        $expected = $latin1.GetString($source) -replace '"version"(\s*):(\s*)"0\.0\.0"', ('"version"$1:$2"' + $SampleVersion + '"')
        Assert-Equal $expected $latin1.GetString($staged) 'staged manifest text'
        Assert-Equal $SampleVersion (([Text.Encoding]::UTF8.GetString($staged) | ConvertFrom-Json).version) 'staged version'
    }

    Invoke-Case 'staging: a CRLF manifest keeps its line ends and its non-ASCII bytes' {
        $dir = New-TempDir
        $sourcePath = Join-Path $dir 'plugin.json'
        $text = "{`r`n  `"name`": `"Z$([char]0x00FC)hlke`",`r`n  `"version`":`"0.0.0`"`r`n}`r`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        [IO.File]::WriteAllBytes($sourcePath, $bytes)
        $stagedPath = Join-Path $dir 'staged.json'
        Write-StampedManifest -SourcePath $sourcePath -DestPath $stagedPath -Version '1.9.0-rc.1'
        $staged = [IO.File]::ReadAllBytes($stagedPath)
        Assert-Equal ($bytes.Length + 5) $staged.Length 'only "0.0.0" becomes "1.9.0-rc.1": five characters longer'
        $umlautAt = [Array]::IndexOf($bytes, [byte]0xC3)
        Assert-True ($umlautAt -gt 0 -and $staged[$umlautAt] -eq 0xC3 -and $staged[$umlautAt + 1] -eq 0xBC) 'the two UTF-8 bytes of the u-umlaut are untouched'
        Assert-Equal 4 ([regex]::Matches([Text.Encoding]::UTF8.GetString($staged), "`r`n")).Count 'every CRLF is kept'
        Assert-StampedManifest -SourcePath $sourcePath -StagedPath $stagedPath -Version '1.9.0-rc.1'
    }

    Invoke-Case 'staging: VERSION.txt carries tag, version, commit, built and run, one per line, in the format the exe reads' {
        $text = [IO.File]::ReadAllText((Join-Path (New-StagedCopy) 'VERSION.txt'))
        Assert-Equal "tag: v1.9.0`nversion: 1.9.0`ncommit: $SampleCommit`nbuilt: 2026-10-24T12:00:00Z`nrun: local`n" $text 'VERSION.txt'
    }

    Invoke-Case 'staging: bin/CLAUDE.md inlines the skill without its frontmatter and keeps the developer sections' {
        $text = [IO.File]::ReadAllText((Join-Path (New-StagedCopy) 'bin\CLAUDE.md'))
        Assert-Contains $text '# TestStand rules' 'the skill heading'
        Assert-Contains $text '## Never do' 'the skill body'
        Assert-Contains $text '# Rebuilding, migrating and cloning sequence files' 'a references file'
        Assert-Contains $text '## Developer notes behind the imported rules' 'the developer sections stay'
        Assert-NotContains $text 'skill-imports' 'the swapped markers'
        Assert-NotContains $text 'name: teststand-rules' 'the skill frontmatter'
        Assert-True ($text -cnotmatch '(?m)^@plugin/') 'an import is left'
    }

    Invoke-Case 'staging: another exe layout is built and asserted with its own table row' {
        $stage = New-StageFrom -PublishDir (New-FakePublishDir -Without @('coreclr.dll')) -Layout 'framework-dependent'
        Assert-StagedPlugin -RepoRoot $RepoRoot -StageDir $stage -Layout 'framework-dependent' -Release $Release
        $single = New-StageFrom -PublishDir (New-FakePublishDir -Without @('coreclr.dll', 'TestStandMCP.runtimeconfig.json')) -Layout 'single-file'
        Assert-StagedPlugin -RepoRoot $RepoRoot -StageDir $single -Layout 'single-file' -Release $Release
    }

    # ---- the Outline rows of slice 5.2, one fixture each ------------------
    Invoke-Case 'fault: a required staged file is missing' {
        Assert-StageFault { param($stage) Remove-Item -LiteralPath (Join-Path $stage '.mcp.json') } @('missing .mcp.json', 'archive root', 'Fix:')
    }

    Invoke-Case 'fault: the exe layout needs a runtime file the publish did not produce' {
        $stage = New-StageFrom -PublishDir (New-FakePublishDir -Without @('coreclr.dll'))
        Assert-FailsWith { Assert-StagedPlugin -RepoRoot $RepoRoot -StageDir $stage -Layout 'folder' -Release $Release } @('missing coreclr.dll', 'bin/', "'folder'")
    }

    Invoke-Case 'fault: a file of another exe layout is staged' {
        $stage = New-StageFrom -PublishDir (New-FakePublishDir) -Layout 'framework-dependent'
        Assert-FailsWith { Assert-StagedPlugin -RepoRoot $RepoRoot -StageDir $stage -Layout 'framework-dependent' -Release $Release } @('coreclr.dll', 'another exe layout')
    }

    Invoke-Case 'fault: a converted agent still contains mcp__teststand__' {
        Assert-StageFault {
            param($stage)
            $path = Join-Path $stage 'agents\teststand-doc-generator.md'
            [IO.File]::AppendAllText($path, "`ncall mcp__teststand__connect_engine`n")
        } @('agents/teststand-doc-generator.md', "'mcp__teststand__'", 'Get-AgentMappingTable')
    }

    Invoke-Case 'fault: a converted agent names CLAUDE.md in any case' {
        Assert-StageFault {
            param($stage)
            [IO.File]::AppendAllText((Join-Path $stage 'agents\teststand-doc-generator.md'), "`nSee claude.MD for the rules`n")
        } @("'CLAUDE.md'", 'agents/teststand-doc-generator.md')
    }

    Invoke-Case 'fault: the number of plugin agents differs from .claude/agents' {
        Assert-StageFault {
            param($stage)
            Remove-Item -LiteralPath (Join-Path $stage 'agents\teststand-doc-generator.md')
        } @('agents/ holds 2 file(s) but exactly 3 are expected', 'missing: teststand-doc-generator.md', 'one converted agent per source agent')
    }

    Invoke-Case 'fault: bin/scripts holds a file outside its expected set' {
        Assert-StageFault {
            param($stage)
            Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\Test-LoadPrototype.ps1') -Destination (Join-Path $stage 'bin\scripts')
        } @('bin/scripts/ holds 4 file(s) but exactly 3 are expected', 'unexpected: Test-LoadPrototype.ps1', 'maintainer script')
    }

    Invoke-Case 'fault: hooks/ holds a file that is not a runtime hook' {
        Assert-StageFault {
            param($stage)
            Write-TextFile (Join-Path $stage 'hooks\AllowHook.Tests.ps1') 'test'
        } @('hooks/ holds 7 file(s)', 'unexpected: AllowHook.Tests.ps1')
    }

    Invoke-Case 'fault: bin/CLAUDE.md still contains an unresolved import' {
        Assert-StageFault {
            param($stage)
            [IO.File]::AppendAllText((Join-Path $stage 'bin\CLAUDE.md'), "`n@plugin/skills/teststand-rules/references/gone.md`n")
        } @('unresolved import', '@plugin/skills/teststand-rules/references/gone.md')
    }

    Invoke-Case 'fault: VERSION.txt lacks one of tag, version, commit, built, run' {
        foreach ($key in @('tag', 'version', 'commit', 'built', 'run')) {
            Assert-StageFault {
                param($stage)
                $path = Join-Path $stage 'VERSION.txt'
                $kept = @([IO.File]::ReadAllLines($path) | Where-Object { -not $_.StartsWith("${key}:") })
                [IO.File]::WriteAllText($path, (($kept -join "`n") + "`n"))
            } @("VERSION.txt lacks $key")
        }
    }

    Invoke-Case 'fault: VERSION.txt names another version than the one built' {
        Assert-StageFault { param($stage) Write-TextFile (Join-Path $stage 'VERSION.txt') "tag: v1.9.0`nversion: 1.8.0`ncommit: $SampleCommit`nbuilt: x`nrun: local`n" } @("version '1.8.0'", "'1.9.0' was requested")
    }

    Invoke-Case 'fault: the staged plugin.json differs from the source in more than the version' {
        Assert-StageFault {
            param($stage)
            $path = Join-Path $stage '.claude-plugin\plugin.json'
            [IO.File]::WriteAllText($path, ([IO.File]::ReadAllText($path).Replace('"license": "MIT"', '"license": "GPL"')))
        } @('not the source with only', 'unreviewed change')
    }

    Invoke-Case 'fault: a direct agent was changed after copying' {
        Assert-StageFault {
            param($stage)
            [IO.File]::AppendAllText((Join-Path $stage 'bin\.claude\agents\teststand-doc-generator.md'), 'x')
        } @('bin/.claude/agents/teststand-doc-generator.md', 'differs from')
    }

    Invoke-Case 'fault: CLAUDE.md without its import markers cannot be resolved' {
        $fixtureRepo = New-TempDir
        Write-TextFile (Join-Path $fixtureRepo 'CLAUDE.md') "# rules`n@plugin/skills/teststand-rules/SKILL.md`n"
        Assert-FailsWith { ConvertTo-ResolvedClaudeMd -RepoRoot $fixtureRepo } @('skill-imports:begin', 'Test-SkillSources.ps1')
    }

    Invoke-Case 'fault: CLAUDE.md imports a file that does not exist' {
        $fixtureRepo = New-TempDir
        Write-TextFile (Join-Path $fixtureRepo 'CLAUDE.md') "# rules`n<!-- skill-imports:begin -->`n@plugin/missing.md`n<!-- skill-imports:end -->`n"
        Assert-FailsWith { ConvertTo-ResolvedClaudeMd -RepoRoot $fixtureRepo } @('@plugin/missing.md', 'does not exist')
    }

    Invoke-Case 'staging: an agent that does not convert is reported with its file name' {
        $fixtureRepo = New-TempDir
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'plugin') -Destination (Join-Path $fixtureRepo 'plugin') -Recurse
        Write-TextFile (Join-Path $fixtureRepo '.claude\agents\broken.md') "---`nname: broken`n---`nno tools line`n"
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'CLAUDE.md') -Destination $fixtureRepo
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts') -Destination (Join-Path $fixtureRepo 'scripts') -Recurse
        Assert-FailsWith { New-StagedPlugin -RepoRoot $fixtureRepo -PublishDir (New-FakePublishDir) -StageDir (Join-Path (New-TempDir) 'stage') -Layout 'folder' -Release $Release } `
            @('broken.md', "no 'tools:' line", 'build/PluginIdentity.psm1')
    }

    # ======================================================================
    #  Smoke tests of the staged exe (PluginSmoke): fake exes are .cmd files
    # ======================================================================
    Import-Module (Join-Path $BuildDir 'PluginSmoke.psm1') -Force

    # A .cmd standing in for the exe; $Lines are its batch lines.
    function New-FakeExe {
        param([string[]]$Lines)
        $path = Join-Path (New-TempDir) 'TestStandMCP.cmd'
        [IO.File]::WriteAllText($path, ((@('@echo off') + $Lines) -join "`r`n") + "`r`n", $Utf8NoBom)
        return $path
    }

    $VersionLines = @('echo TestStand MCP Server 1.9.0', 'echo   tag:     v1.9.0', "echo   commit:  $SampleCommit", 'echo   built:   2026-10-24T12:00:00Z', 'echo   run:     local')

    Invoke-Case 'smoke --version: the version, the tag and the commit on stdout with exit 0 pass' {
        Assert-VersionOutput -ExePath (New-FakeExe $VersionLines) -Version $SampleVersion -Tag "v$SampleVersion" -Commit $SampleCommit
    }

    Invoke-Case 'fault: --version names another version' {
        $exe = New-FakeExe (@('echo TestStand MCP Server 1.8.0') + $VersionLines[1..4])
        Assert-FailsWith { Assert-VersionOutput -ExePath $exe -Version $SampleVersion -Tag "v$SampleVersion" -Commit $SampleCommit } @("its first line ends with '1.8.0', not '1.9.0'", '--version output is wrong', 'VERSION.txt')
    }

    Invoke-Case 'fault: --version lacks the tag (an untagged or unreadable VERSION.txt)' {
        $exe = New-FakeExe @('echo TestStand MCP Server 1.9.0', "echo   commit:  $SampleCommit", 'echo   note:    release metadata incomplete: no tag')
        Assert-FailsWith { Assert-VersionOutput -ExePath $exe -Version $SampleVersion -Tag "v$SampleVersion" -Commit $SampleCommit } @("does not name 'v1.9.0'", 'release-metadata note')
    }

    Invoke-Case 'fault: --version reports an untagged -dev build' {
        $exe = New-FakeExe @('echo TestStand MCP Server 1.9.0-dev', 'echo   tag:     v1.9.0', "echo   commit:  $SampleCommit")
        Assert-FailsWith { Assert-VersionOutput -ExePath $exe -Version $SampleVersion -Tag "v$SampleVersion" -Commit $SampleCommit } @("untagged build ('-dev')")
    }

    Invoke-Case 'fault: --version exits non-zero' {
        $exe = New-FakeExe @('echo broken', 'exit /b 3')
        Assert-FailsWith { Assert-VersionOutput -ExePath $exe -Version $SampleVersion -Tag "v$SampleVersion" -Commit $SampleCommit } @('exited with code 3', 'broken', 'Run it by hand')
    }

    # tool list: a classification of get_a, get_b (allow) and set_c (prompt) over a three-tool registry
    function New-ToolListFixture {
        $dir = New-TempDir
        Write-TextFile (Join-Path $dir 'Registry.cs') "Register(`"get_a`", `"a`")`nRegister(`"get_b`", `"b`")`nRegister(`"set_c`", `"c`")`n"
        Write-TextFile (Join-Path $dir 'tool-classes.json') '{ "allow": ["get_a", "get_b"], "prompt": ["set_c"] }'
        return @{ Classes = (Join-Path $dir 'tool-classes.json'); Registry = (Join-Path $dir 'Registry.cs') }
    }

    Invoke-Case 'smoke --list-tools: exactly the classified tools, in any order, pass' {
        $fixture = New-ToolListFixture
        $exe = New-FakeExe @('echo ["set_c","get_a","get_b"]')
        Assert-ToolList -ExePath $exe -ClassesPath $fixture.Classes -RegistryPath $fixture.Registry
    }

    Invoke-Case 'fault: the exe lists a tool that is not classified, and a classified one is missing' {
        $fixture = New-ToolListFixture
        $exe = New-FakeExe @('echo ["get_a","get_b","rogue_tool"]')
        Assert-FailsWith { Assert-ToolList -ExePath $exe -ClassesPath $fixture.Classes -RegistryPath $fixture.Registry } `
            @('listed by the exe but not classified: rogue_tool', 'classified but not listed by the exe: set_c', 'tool-classes.json')
    }

    Invoke-Case 'fault: --list-tools --json prints text that is not JSON' {
        $fixture = New-ToolListFixture
        $exe = New-FakeExe @('echo Available Tools:')
        Assert-FailsWith { Assert-ToolList -ExePath $exe -ClassesPath $fixture.Classes -RegistryPath $fixture.Registry } @('did not print a JSON array', 'Available Tools:')
    }

    # initialize: the fake reads one line from stdin, then answers like the server would
    function New-InitializeFake {
        param([string]$Version)
        return New-FakeExe @('set /p line=', "echo {`"jsonrpc`":`"2.0`",`"id`":1,`"result`":{`"serverInfo`":{`"name`":`"x`",`"version`":`"$Version`"}}}")
    }
    $RealProgramPath = Join-Path $RepoRoot 'Program.cs'

    Invoke-Case 'smoke initialize: serverInfo.version is the version built' {
        Assert-InitializeRoundTrip -ExePath (New-InitializeFake $SampleVersion) -Version $SampleVersion -ProgramSourcePath $RealProgramPath
    }

    Invoke-Case 'fault: initialize answers another version' {
        Assert-FailsWith { Assert-InitializeRoundTrip -ExePath (New-InitializeFake '1.8.0') -Version $SampleVersion -ProgramSourcePath $RealProgramPath } `
            @("serverInfo.version '1.8.0'", 'version 1.9.0 was built')
    }

    Invoke-Case 'fault: initialize is never answered, and the stuck process is stopped' {
        $exe = New-FakeExe @('set /p line=', 'ping -n 15 127.0.0.1 >nul')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Assert-FailsWith { Assert-InitializeRoundTrip -ExePath $exe -Version $SampleVersion -ProgramSourcePath $RealProgramPath -TimeoutSeconds 2 } @('did not answer an MCP initialize request within 2 s')
        Assert-True ($clock.Elapsed.TotalSeconds -lt 40) "the check took $($clock.Elapsed.TotalSeconds) s"
    }

    Invoke-Case 'startup log: a version on stderr passes; a stderr without it fails' {
        Assert-StartupLogVersion -StderrText "info: TestStand MCP Server v1.9.0 starting..." -Version $SampleVersion -ProgramSourcePath $RealProgramPath
        Assert-FailsWith { Assert-StartupLogVersion -StderrText 'info: TestStand MCP Server v1.8.0 starting...' -Version $SampleVersion -ProgramSourcePath $RealProgramPath } `
            @('does not name version 1.9.0', 'v1.8.0')
    }

    Invoke-Case 'startup log: with nothing on stderr the source must log VersionInfo.Current.Version' {
        Assert-StartupLogVersion -StderrText '' -Version $SampleVersion -ProgramSourcePath $RealProgramPath
        $dir = New-TempDir
        $program = Join-Path $dir 'Program.cs'
        Write-TextFile $program 'logger.LogInformation("{Product} v{Version} starting...", VersionInfo.ProductName, "1.0.0");'
        Assert-FailsWith { Assert-StartupLogVersion -StderrText '' -Version $SampleVersion -ProgramSourcePath $program } @('Nothing reached stderr', 'VersionInfo.Current.Version')
    }

    # ======================================================================
    #  Zip, release assets, local verification
    # ======================================================================
    function New-SmallStage {
        $dir = Join-Path (New-TempDir) 'stage'
        Write-TextFile (Join-Path $dir 'VERSION.txt') 'tag: v1.9.0'
        Write-TextFile (Join-Path $dir '.claude-plugin\plugin.json') '{}'
        Write-TextFile (Join-Path $dir 'bin\scripts\a.py') 'print(1)'
        return $dir
    }

    Invoke-Case 'zip: every file is an entry with forward slashes, hidden folders included, no directory entries' {
        $stage = New-SmallStage
        $zipPath = Join-Path (New-TempDir) 'a.zip'
        New-PluginZip -StageDir $stage -ZipPath $zipPath
        Assert-PluginZip -ZipPath $zipPath -StageDir $stage
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try { $names = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
        Assert-Equal '.claude-plugin/plugin.json,VERSION.txt,bin/scripts/a.py' ($names -join ',') 'entry names'
    }

    Invoke-Case 'fault: a zip entry contains a backslash' {
        $stage = New-SmallStage
        $zipPath = Join-Path (New-TempDir) 'bad.zip'
        $stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
        $zip = New-Object System.IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($name in @('VERSION.txt', '.claude-plugin\plugin.json', 'bin/scripts/a.py')) { $zip.CreateEntry($name).Open().Dispose() }
        $zip.Dispose(); $stream.Dispose()
        Assert-FailsWith { Assert-PluginZip -ZipPath $zipPath -StageDir $stage } @("backslash, for example '.claude-plugin\plugin.json'", 'New-PluginZip', 'ZipFile.CreateFromDirectory')
    }

    Invoke-Case 'fault: the zip holds a file the staged tree does not, or lacks one it has' {
        $stage = New-SmallStage
        $zipPath = Join-Path (New-TempDir) 'a.zip'
        New-PluginZip -StageDir $stage -ZipPath $zipPath
        Write-TextFile (Join-Path $stage 'bin\scripts\late.py') 'x'
        Assert-FailsWith { Assert-PluginZip -ZipPath $zipPath -StageDir $stage } @('3 entries but the staged tree has 4 files', 'missing: bin/scripts/late.py')
    }

    Invoke-Case 'assets: the versioned copy, digest and manifest are written under the ReleaseAssets names; sha256sum -c accepts them' {
        $stage = New-SmallStage
        $outDir = New-TempDir
        New-PluginZip -StageDir $stage -ZipPath (Join-Path $outDir $ReleaseArchiveName)
        Write-ReleaseAssets -StageDir $stage -OutDir $outDir -Version '0.0.0-ci'
        foreach ($name in @($ReleaseArchiveName, $ReleaseDigestName, $ReleaseManifestName, (Get-VersionedArchiveName -Version '0.0.0'))) {
            Assert-True (Test-Path -LiteralPath (Join-Path $outDir $name)) "$name was not written"
        }
        Assert-Equal (Get-FileSha256 (Join-Path $outDir $ReleaseArchiveName)) (Get-FileSha256 (Join-Path $outDir (Get-VersionedArchiveName -Version '0.0.0'))) 'versioned copy'
        $manifest = [IO.File]::ReadAllText((Join-Path $outDir $ReleaseManifestName))
        Assert-Equal 3 @($manifest.TrimEnd("`n") -split "`n").Count 'manifest lines'
        Assert-Contains $manifest '  bin/scripts/a.py' 'manifest'
        $sha256sum = Get-Command sha256sum -ErrorAction SilentlyContinue
        if ($null -ne $sha256sum) {
            $check = Invoke-ChildProcess -FilePath $sha256sum.Source -ArgumentList @('-c', $ReleaseDigestName) -WorkingDirectory $outDir -TimeoutSeconds 60
            Assert-Equal 0 $check.ExitCode "sha256sum -c said: $($check.Stdout) $($check.Stderr)"
            Assert-Contains $check.Stdout 'OK' 'sha256sum output'
        }
    }

    Invoke-Case 'verify: the release verifier accepts the assets in local mode' {
        $stage = New-SmallStage
        $outDir = New-TempDir
        New-PluginZip -StageDir $stage -ZipPath (Join-Path $outDir $ReleaseArchiveName)
        Write-ReleaseAssets -StageDir $stage -OutDir $outDir -Version '1.9.0'
        Assert-LocalRelease -OutDir $outDir -Version '1.9.0'
    }

    Invoke-Case 'fault: the verifier rejects a digest that does not match the archive' {
        $stage = New-SmallStage
        $outDir = New-TempDir
        New-PluginZip -StageDir $stage -ZipPath (Join-Path $outDir $ReleaseArchiveName)
        Write-ReleaseAssets -StageDir $stage -OutDir $outDir -Version '1.9.0'
        Write-TextFile (Join-Path $outDir $ReleaseDigestName) (('0' * 64) + "  $ReleaseArchiveName`n")
        Assert-FailsWith { Assert-LocalRelease -OutDir $outDir -Version '1.9.0' } @('release verifier', $ReleaseDigestName, 'Fix what the verifier reports')
    }

    # ======================================================================
    #  The real end-to-end run, once per layout. Opt-in: it publishes the real exe.
    # ======================================================================
    foreach ($layoutName in (Get-ArchiveLayoutName)) {
        if ($env:TESTSTAND_MCP_PACKAGE_E2E -ne '1') {
            Write-Host "SKIP  e2e ($layoutName): set TESTSTAND_MCP_PACKAGE_E2E=1 to publish and package the real exe"
            continue
        }
        Invoke-Case "e2e ($layoutName): the script packages the real exe and the verifier accepts the output" {
            $outDir = Join-Path (New-TempDir) 'out'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-ChildProcess -FilePath $HostPath -TimeoutSeconds 1200 `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-Version', '0.0.0-ci', '-Layout', $layoutName, '-OutDir', $outDir)
            Assert-Equal 0 $result.ExitCode "the script failed:`n$($result.Stdout)"
            Assert-Contains $result.Stdout '[8/8]' 'the last step ran'
            $zipPath = Join-Path $outDir $ReleaseArchiveName
            $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
            try { $names = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
            Assert-Equal 0 @($names | Where-Object { $_.Contains('\') }).Count 'entry names with a backslash'
            Assert-Equal (Get-FileSet (Join-Path $outDir 'stage')).Count $names.Count 'entries against staged files'
            $version = Invoke-ChildProcess -FilePath (Join-Path $outDir 'stage\bin\TestStandMCP.exe') -ArgumentList @('--version') -TimeoutSeconds 60
            Assert-Contains $version.Stdout '0.0.0-ci' 'staged --version'
            $sha256sum = Get-Command sha256sum -ErrorAction SilentlyContinue
            if ($null -ne $sha256sum) {
                $check = Invoke-ChildProcess -FilePath $sha256sum.Source -ArgumentList @('-c', $ReleaseDigestName) -WorkingDirectory $outDir -TimeoutSeconds 120
                Assert-Equal 0 $check.ExitCode "sha256sum -c said: $($check.Stdout) $($check.Stderr)"
            }
            Write-Host ("      e2e {0}: {1:N1} MB, {2} entries, {3:N1} s" -f $layoutName, ((Get-Item -LiteralPath $zipPath).Length / 1MB), $names.Count, $clock.Elapsed.TotalSeconds)
            Write-Host ($result.Stdout -split "`n" | Where-Object { $_ -match '^\[\d/8\]' } | ForEach-Object { "      $_" }) -Separator "`n"
        }
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
