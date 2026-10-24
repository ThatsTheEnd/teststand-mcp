# ============================================================================
#  PluginHooks.Tests.ps1 - plain PowerShell asserts for the plugin hooks:
#    plugin/hooks/allow-readonly.ps1, tool-classes.json, platform-guard.ps1 / .sh,
#    update-notify.ps1, hooks.json and build/New-HooksJson.ps1 +
#    build/ToolClassification.psm1.
#  Runs under Windows PowerShell 5.1 and PowerShell 7 (each hook script is started
#  with the same host that runs this file):
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\tests\PluginHooks.Tests.ps1
#  Prints PASS/FAIL per case and exits non-zero when any case fails.
#  This file is ASCII only on purpose: 5.1 reads a BOM-less script as ANSI, so
#  non-ASCII characters are built from code points below.
#  Every hook runs against a temp state directory (TESTSTAND_MCP_STATE_DIR); the
#  tests never touch the real %LOCALAPPDATA% or ~/.claude.
# ============================================================================
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$HooksDir = Join-Path $RepoRoot 'plugin\hooks'
$ClassificationModulePath = Join-Path $RepoRoot 'build\ToolClassification.psm1'
$IdentityModulePath = Join-Path $RepoRoot 'build\PluginIdentity.psm1'
$RegistryPath = Join-Path $RepoRoot 'src\Tools\TestStandToolRegistry.cs'
$ToolClassesPath = Join-Path $HooksDir 'tool-classes.json'
$AllowHookPath = Join-Path $HooksDir 'allow-readonly.ps1'
$GuardPs1Path = Join-Path $HooksDir 'platform-guard.ps1'
$GuardShPath = Join-Path $HooksDir 'platform-guard.sh'

$HostPath = (Get-Process -Id $PID).Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$AllowReason = 'no TestStand file is modified'
$FixedNow = [DateTimeOffset]::new(2026, 10, 24, 12, 0, 0, [TimeSpan]::Zero)   # the injected clock (TESTSTAND_MCP_NOW)
$PipInstallCommand = 'py -m pip install python-docx pillow'

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

function Assert-Equal {
    param($Expected, $Actual, [string]$What = 'value')
    if ($Expected -cne $Actual) { throw "$What : expected [$Expected] but got [$Actual]" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Contains {
    param([string]$Text, [string]$Part, [string]$What = 'text')
    if ($Text.IndexOf($Part, [StringComparison]::Ordinal) -lt 0) { throw "$What : expected to contain [$Part] but was [$Text]" }
}

function Assert-NotContains {
    param([string]$Text, [string]$Part, [string]$What = 'text')
    if ($Text.IndexOf($Part, [StringComparison]::Ordinal) -ge 0) { throw "$What : expected NOT to contain [$Part] but was [$Text]" }
}

function New-TempDir {
    param([string]$Suffix = '')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('PluginHooksTests_' + [Guid]::NewGuid().ToString('N') + $Suffix)
    [void](New-Item -ItemType Directory -Path $dir)
    $script:TempDirs += $dir
    return $dir
}

# Runs a program with stdin text and a controlled environment; never throws on a non-zero exit.
# $EnvOverrides: name -> value; a $null value REMOVES the variable from the child.
function Invoke-ProcessWithStdin {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Arguments,
        [AllowEmptyString()][string]$StdinText = '',
        [hashtable]$EnvOverrides = @{}
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($name in $EnvOverrides.Keys) {
        if ($null -eq $EnvOverrides[$name]) { [void]$startInfo.EnvironmentVariables.Remove($name) }
        else { $startInfo.EnvironmentVariables[$name] = [string]$EnvOverrides[$name] }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdinBytes = $Utf8NoBom.GetBytes($StdinText)
        try {
            $process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
            $process.StandardInput.Close()
        } catch [System.IO.IOException] {
            # the hook stopped reading (an oversized input) and exited first: not a test failure
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode  = $process.ExitCode
            Stdout    = $stdoutTask.Result
            Stderr    = $stderrTask.Result
            ElapsedMs = $clock.ElapsedMilliseconds
        }
    } finally {
        $process.Dispose()
    }
}

# Runs a PowerShell script under the SAME host that runs this file.
function Invoke-HookScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyString()][string]$StdinText = '',
        [hashtable]$EnvOverrides = @{}
    )
    return Invoke-ProcessWithStdin -FileName $HostPath -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"') `
        -StdinText $StdinText -EnvOverrides $EnvOverrides
}

# ---- Step 4.1 helpers ---------------------------------------------------------
$IdentityPrefix = $null   # set once the identity module is loaded

function ConvertTo-HookInput {
    param([string]$ToolName)
    return (@{ tool_name = $ToolName; hook_event_name = 'PreToolUse'; tool_input = @{} } | ConvertTo-Json -Compress)
}

# A copy of plugin/hooks in a fresh temp folder, minus the named files.
function New-HooksCopy {
    param([string[]]$Without = @(), [string]$Suffix = '')
    $dir = New-TempDir $Suffix
    Get-ChildItem -LiteralPath $HooksDir -File | Where-Object { $Without -notcontains $_.Name } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $dir
    }
    return $dir
}

function Invoke-AllowHookProcess {
    param([AllowEmptyString()][string]$Stdin)
    return Invoke-HookScript -ScriptPath $AllowHookPath -StdinText $Stdin -EnvOverrides @{ TESTSTAND_MCP_STATE_DIR = (New-TempDir) }
}

try {
    Import-Module $IdentityModulePath -Force
    $IdentityPrefix = (Get-PluginIdentity).pluginToolPrefix

    # === Step 4.1: classification check ==========================================
    Import-Module $ClassificationModulePath -Force

    Invoke-Case 'classification: every registered tool is in exactly one list (real registry, real classes)' {
        $registered = Get-RegisteredToolNames -RegistryPath $RegistryPath
        Assert-True ($registered.Count -gt 0) 'no registered tools were read from the registry'
        $classes = Read-ToolClasses -Path $ToolClassesPath
        $violations = @(Test-ToolClassification -Classes $classes -RegisteredTools $registered)
        Assert-Equal 0 $violations.Count ("violations: " + (($violations | ForEach-Object { $_.Message }) -join ' | '))
    }

    # Fixture classification over a tiny registry: tools a, b, c; every fault is a copy with ONE defect.
    $FixtureTools = @('get_a', 'get_b', 'set_c')
    function New-FixtureClasses {
        param([string[]]$Allow = @('get_a', 'get_b'), [string[]]$Prompt = @('set_c'), $NeverAllow = $null, $Audit = $null)
        $classes = [ordered]@{ allow = $Allow; prompt = $Prompt }
        if ($null -ne $NeverAllow) { $classes['neverAllow'] = $NeverAllow }
        if ($null -ne $Audit) { $classes['audit'] = $Audit }
        return ([pscustomobject]$classes)
    }
    function Assert-OneViolation {
        param($Classes, [string]$Rule, [string]$Tool, [string[]]$Registered = $FixtureTools)
        $violations = @(Test-ToolClassification -Classes $Classes -RegisteredTools $Registered)
        Assert-Equal 1 $violations.Count ("expected exactly one violation but got: " + (($violations | ForEach-Object { $_.Message }) -join ' | '))
        Assert-Equal $Rule $violations[0].Rule 'rule'
        Assert-Equal $Tool $violations[0].Tool 'tool'
        Assert-Contains $violations[0].Message $Tool 'message names the tool'
        Assert-Contains $violations[0].Message $Rule 'message names the rule'
    }

    Invoke-Case 'classification: a well-formed fixture has no violations' {
        Assert-Equal 0 @(Test-ToolClassification -Classes (New-FixtureClasses) -RegisteredTools $FixtureTools).Count 'violations'
    }

    Invoke-Case 'classification fault: a registered tool in neither list is named' {
        Assert-OneViolation (New-FixtureClasses -Prompt @()) 'E_UNCLASSIFIED' 'set_c'
    }

    Invoke-Case 'classification fault: a tool in both lists is named' {
        Assert-OneViolation (New-FixtureClasses -Prompt @('set_c', 'get_b')) 'E_IN_BOTH_LISTS' 'get_b'
    }

    Invoke-Case 'classification fault: an allow-list name that is not a registered tool is named' {
        Assert-OneViolation (New-FixtureClasses -Allow @('get_a', 'get_b', 'get_ghost')) 'E_ALLOW_NOT_REGISTERED' 'get_ghost'
    }

    foreach ($wildcard in @('get_*', 'get_?', 'get_[ab]', 'get_(a|b)', 'get_a ')) {
        Invoke-Case "classification fault: allow entry [$wildcard] is refused as a wildcard" {
            $classes = New-FixtureClasses -Allow @('get_a', 'get_b', $wildcard)
            $violations = @(Test-ToolClassification -Classes $classes -RegisteredTools $FixtureTools | Where-Object { $_.Rule -eq 'E_ALLOW_WILDCARD' })
            Assert-Equal 1 $violations.Count 'wildcard violations'
            Assert-Equal $wildcard $violations[0].Tool 'tool'
        }
    }

    foreach ($excluded in @('evaluate_expression', 'evaluate_in_thread_context', 'diff_sequence_files',
                            'compare_sequence_files', 'find_file', 'analyze_sequence_file', 'run_sequence_analyzer')) {
        Invoke-Case "classification fault: $excluded can never be allow-listed" {
            $registered = $FixtureTools + $excluded
            $classes = New-FixtureClasses -Allow @('get_a', 'get_b', $excluded) -NeverAllow ([pscustomobject]@{ $excluded = 'reason text' })
            $violations = @(Test-ToolClassification -Classes $classes -RegisteredTools $registered)
            Assert-Equal 1 $violations.Count ("violations: " + (($violations | ForEach-Object { $_.Message }) -join ' | '))
            Assert-Equal 'E_ALLOW_NEVER' $violations[0].Rule 'rule'
            Assert-Equal $excluded $violations[0].Tool 'tool'
            Assert-Contains $violations[0].Message 'reason text' 'message states the rule it breaks'
        }
    }

    Invoke-Case 'classification fault: the same name twice in one list is named' {
        Assert-OneViolation (New-FixtureClasses -Allow @('get_a', 'get_b', 'get_a')) 'E_DUPLICATE' 'get_a'
    }

    Invoke-Case 'classification fault: an audit verdict that disagrees with the list is named' {
        $audit = [pscustomobject]@{ get_b = [pscustomobject]@{ verdict = 'prompt'; reason = 'r' } }
        Assert-OneViolation (New-FixtureClasses -Audit $audit) 'E_AUDIT_MISMATCH' 'get_b'
    }

    Invoke-Case 'classification: an audit entry without a reason is refused' {
        $audit = [pscustomobject]@{ get_b = [pscustomobject]@{ verdict = 'allow'; reason = ' ' } }
        Assert-OneViolation (New-FixtureClasses -Audit $audit) 'E_AUDIT_NO_REASON' 'get_b'
    }

    Invoke-Case 'classification: an object with no lists classifies nothing (every tool is reported)' {
        $violations = @(Test-ToolClassification -Classes ([pscustomobject]@{}) -RegisteredTools $FixtureTools)
        Assert-Equal 3 $violations.Count 'violations'
    }

    Invoke-Case 'classification: a registry without any Register call is refused, not read as complete' {
        $empty = Join-Path (New-TempDir) 'Empty.cs'
        [IO.File]::WriteAllText($empty, 'class X { }', $Utf8NoBom)
        $thrown = $null
        try { Get-RegisteredToolNames -RegistryPath $empty } catch { $thrown = $_.Exception.Message }
        Assert-True ($null -ne $thrown) 'expected a refusal'
        Assert-Contains $thrown 'Empty.cs' 'names the file'
    }

    Invoke-Case 'classification: the real list keeps the audited verdicts and the named exclusions' {
        $classes = Read-ToolClasses -Path $ToolClassesPath
        Assert-True ($classes.allow -ccontains 'get_step_unique_id') 'get_step_unique_id is audited as read-only'
        Assert-True ($classes.prompt -ccontains 'read_csv_lines') 'read_csv_lines is an arbitrary file read, so it prompts'
        foreach ($name in 'evaluate_expression', 'evaluate_in_thread_context', 'diff_sequence_files', 'compare_sequence_files', 'find_file', 'analyze_sequence_file', 'run_sequence_analyzer') {
            Assert-True ($classes.prompt -ccontains $name) "$name must prompt"
            Assert-True ($null -ne $classes.neverAllow.PSObject.Properties[$name]) "$name must be a named never-allow exclusion"
        }
    }

    Invoke-Case 'classification: both arrays of the real file are sorted (ordinal) without duplicates' {
        $classes = Read-ToolClasses -Path $ToolClassesPath
        foreach ($listName in 'allow', 'prompt') {
            $list = @($classes.$listName)
            $sorted = @($list | Sort-Object { $_ } -Unique)
            $ordinal = [string[]]$list.Clone()
            [Array]::Sort($ordinal, [StringComparer]::Ordinal)
            Assert-Equal ($ordinal -join ',') ($list -join ',') "$listName order"
            Assert-Equal $sorted.Count $list.Count "$listName duplicates"
        }
    }

    # === Step 4.1: the allow hook ===================================================
    function Assert-AsciiOnly {
        param([string]$Text, [string]$What = 'output')
        foreach ($char in $Text.ToCharArray()) {
            if ([int]$char -gt 127) { throw "$What contains the non-ASCII character U+$('{0:X4}' -f [int]$char)" }
        }
    }

    function Assert-AllowDecision {
        param($Result)
        Assert-Equal 0 $Result.ExitCode "exit code (stderr: $($Result.Stderr))"
        Assert-AsciiOnly $Result.Stdout 'stdout'
        $decision = $Result.Stdout | ConvertFrom-Json
        Assert-Equal 'PreToolUse' $decision.hookSpecificOutput.hookEventName 'hookEventName'
        Assert-Equal 'allow' $decision.hookSpecificOutput.permissionDecision 'permissionDecision'
        Assert-Equal $AllowReason $decision.hookSpecificOutput.permissionDecisionReason 'permissionDecisionReason'
    }

    function Assert-NoDecision {
        param($Result)
        Assert-Equal 0 $Result.ExitCode "exit code (stderr: $($Result.Stderr))"
        Assert-Equal '' $Result.Stdout 'stdout'
        Assert-Equal '' $Result.Stderr 'stderr'
    }

    Invoke-Case 'allow hook: a read-only tool runs without a prompt, with the reason' {
        Assert-AllowDecision (Invoke-AllowHookProcess (ConvertTo-HookInput ($IdentityPrefix + 'get_steps')))
    }

    $PromptingTools = @('insert_step', 'evaluate_expression', 'evaluate_in_thread_context', 'diff_sequence_files',
                        'compare_sequence_files', 'find_file', 'analyze_sequence_file', 'read_csv_lines')
    foreach ($tool in $PromptingTools) {
        Invoke-Case "allow hook: $tool still prompts (prints nothing, exits 0)" {
            Assert-NoDecision (Invoke-AllowHookProcess (ConvertTo-HookInput ($IdentityPrefix + $tool)))
        }
    }

    $MalformedInputs = [ordered]@{
        'empty input'                  = ''
        'whitespace only'              = "  `r`n "
        'non-JSON text'                = 'this is not json'
        'truncated JSON'               = '{"tool_name": "mcp__plugin_'
        'a JSON array'                 = '["get_steps"]'
        'JSON null'                    = 'null'
        'an object without tool_name'  = '{"hook_event_name":"PreToolUse"}'
        'a numeric tool_name'          = '{"tool_name": 42}'
        'a null tool_name'             = '{"tool_name": null}'
        'an empty tool_name'           = '{"tool_name": ""}'
        'a bare short name'            = '{"tool_name": "get_steps"}'
        'a direct (non-plugin) prefix' = '{"tool_name": "mcp__teststand__get_steps"}'
        'an upper-case short name'     = ('{"tool_name": "' + $IdentityPrefix + 'GET_STEPS"}')
        'an unregistered short name'   = ('{"tool_name": "' + $IdentityPrefix + 'get_steps_and_more"}')
    }
    foreach ($label in $MalformedInputs.Keys) {
        Invoke-Case "allow hook: $label prints nothing and exits 0" {
            Assert-NoDecision (Invoke-AllowHookProcess $MalformedInputs[$label])
        }
    }

    Invoke-Case 'allow hook: a missing tool-classes.json next to the script prints nothing and exits 0' {
        $dir = New-HooksCopy -Without 'tool-classes.json'
        $result = Invoke-HookScript -ScriptPath (Join-Path $dir 'allow-readonly.ps1') -StdinText (ConvertTo-HookInput ($IdentityPrefix + 'get_steps'))
        Assert-NoDecision $result
    }

    Invoke-Case 'allow hook: a corrupt tool-classes.json prints nothing and exits 0' {
        $dir = New-HooksCopy -Without 'tool-classes.json'
        [IO.File]::WriteAllText((Join-Path $dir 'tool-classes.json'), '{ "allow": [ "get_steps" ', $Utf8NoBom)
        $result = Invoke-HookScript -ScriptPath (Join-Path $dir 'allow-readonly.ps1') -StdinText (ConvertTo-HookInput ($IdentityPrefix + 'get_steps'))
        Assert-NoDecision $result
    }

    Invoke-Case 'allow hook: an input over the 1 MB cap prints nothing and exits 0' {
        $huge = '{"tool_name": "' + $IdentityPrefix + 'get_steps", "tool_input": {"pad": "' + ('x' * 1100000) + '"}}'
        Assert-NoDecision (Invoke-AllowHookProcess $huge)
    }

    Invoke-Case 'allow hook: a missing hook-common.ps1 prints nothing and exits 0' {
        $dir = New-HooksCopy -Without 'hook-common.ps1'
        $result = Invoke-HookScript -ScriptPath (Join-Path $dir 'allow-readonly.ps1') -StdinText (ConvertTo-HookInput ($IdentityPrefix + 'get_steps'))
        Assert-NoDecision $result
    }

    Invoke-Case 'allow hook: the decision matches the classification for every registered tool (in-process, whole list)' {
        . $AllowHookPath    # dot-sourcing loads the functions only; the case body is its own scope
        $classes = Read-ToolClasses -Path $ToolClassesPath
        $allowList = Read-AllowList $ToolClassesPath
        Assert-Equal $classes.allow.Count $allowList.Count 'allow list the hook reads'
        $wrongAllow = @($classes.allow | Where-Object { -not (Test-ToolAllowed ($IdentityPrefix + $_) $allowList) })
        $wrongPrompt = @($classes.prompt | Where-Object { Test-ToolAllowed ($IdentityPrefix + $_) $allowList })
        Assert-Equal '' ($wrongAllow -join ',') 'allow-listed tools that were not allowed'
        Assert-Equal '' ($wrongPrompt -join ',') 'prompt-listed tools that were allowed'
    }

    Invoke-Case 'allow hook: the short name is the text after the last double underscore, and only for plugin tools' {
        . $AllowHookPath
        Assert-Equal 'get_steps' (Get-ShortToolName 'mcp__plugin_teststand-mcp_teststand__get_steps') 'plugin tool'
        Assert-Equal $null (Get-ShortToolName 'mcp__teststand__get_steps') 'direct tool'
        Assert-Equal $null (Get-ShortToolName 'mcp__plugin_nosplit') 'no separator after the prefix'
        Assert-Equal $null (Get-ShortToolName 42) 'non-string'
        Assert-Equal $null (Get-ShortToolName $null) 'null'
    }

    # === Step 4.2: the platform guard (Windows part: platform-guard.ps1) ==============
    # A synthetic station: temp Program Files roots, stub py / python launchers on a private PATH.
    # Each stub prints the text in its *_OUT variable and exits with its *_EXIT variable.
    function New-GuardFixture {
        param(
            [switch]$NoTestStand, [switch]$NoBrowser,
            [AllowNull()][string]$PyOut = '1 1', [int]$PyExit = 0,
            [AllowNull()][string]$PythonOut = $null, [int]$PythonExit = 0,
            [string]$StubBody = ''
        )
        $root = New-TempDir
        $programFiles = Join-Path $root 'pf'
        $programFilesX86 = Join-Path $root 'pf86'
        $bin = Join-Path $root 'bin'
        $state = Join-Path $root 'state'
        foreach ($dir in $programFiles, $programFilesX86, $bin) { [void](New-Item -ItemType Directory -Path $dir) }
        if (-not $NoTestStand) { [void](New-Item -ItemType Directory -Path (Join-Path $programFilesX86 'National Instruments\TestStand 2024')) }
        if (-not $NoBrowser) {
            $edgeDir = Join-Path $programFiles 'Microsoft\Edge\Application'
            [void](New-Item -ItemType Directory -Path $edgeDir)
            [IO.File]::WriteAllText((Join-Path $edgeDir 'msedge.exe'), '', $Utf8NoBom)
        }
        $stubs = @{ py = $PyOut; python = $PythonOut }
        foreach ($name in $stubs.Keys) {
            if ($null -eq $stubs[$name]) { continue }
            $upper = $name.ToUpperInvariant()
            [IO.File]::WriteAllText((Join-Path $bin "$name.cmd"), "@echo off`r`n${StubBody}echo %STUB_${upper}_OUT%`r`nexit /b %STUB_${upper}_EXIT%`r`n", $Utf8NoBom)
        }
        $envMap = @{
            TESTSTAND_MCP_STATE_DIR           = $state
            TESTSTAND_MCP_NOW                 = $FixedNow.ToString('o')
            TESTSTAND_MCP_NO_PLATFORM_WARNING = $null
            TestStand                         = $null
            CLAUDE_PLUGIN_DATA                = $null
            ProgramFiles                      = $programFiles
            ProgramW6432                      = $programFiles
            'ProgramFiles(x86)'               = $programFilesX86
            PATH                              = "$bin;$env:SystemRoot\System32"
            STUB_PY_OUT                       = $PyOut
            STUB_PY_EXIT                      = $PyExit
            STUB_PYTHON_OUT                   = $PythonOut
            STUB_PYTHON_EXIT                  = $PythonExit
        }
        return [pscustomobject]@{ Env = $envMap; State = $state; Root = $root; Bin = $bin; ProgramFiles = $programFiles; ProgramFilesX86 = $programFilesX86 }
    }

    # Runs the guard; .Json is the parsed stdout (or $null), .Message its systemMessage (or $null), .Context its additionalContext.
    function Invoke-Guard {
        param($Fixture, [hashtable]$Extra = @{}, [DateTimeOffset]$Now = $FixedNow, [string]$ScriptPath = $GuardPs1Path)
        $envOverrides = @{}
        foreach ($key in $Fixture.Env.Keys) { $envOverrides[$key] = $Fixture.Env[$key] }
        $envOverrides['TESTSTAND_MCP_NOW'] = $Now.ToString('o')
        foreach ($key in $Extra.Keys) { $envOverrides[$key] = $Extra[$key] }
        $result = Invoke-HookScript -ScriptPath $ScriptPath -StdinText '{"hook_event_name":"SessionStart","source":"startup"}' -EnvOverrides $envOverrides
        $json = $null; $message = $null; $context = $null
        if ($result.Stdout.Trim().Length -gt 0) {
            $json = $result.Stdout | ConvertFrom-Json
            if ($null -ne $json.PSObject.Properties['systemMessage']) { $message = $json.systemMessage }
            if ($null -ne $json.PSObject.Properties['hookSpecificOutput']) { $context = $json.hookSpecificOutput.additionalContext }
        }
        $result | Add-Member -NotePropertyName Json -NotePropertyValue $json
        $result | Add-Member -NotePropertyName Message -NotePropertyValue $message
        $result | Add-Member -NotePropertyName Context -NotePropertyValue $context
        return $result
    }

    function Assert-GuardClean {
        param($Result, [string]$What = 'guard')
        Assert-Equal 0 $Result.ExitCode "$What exit code (stderr: $($Result.Stderr))"
        Assert-Equal '' $Result.Stderr "$What stderr"
        Assert-AsciiOnly $Result.Stdout "$What stdout"
    }

    Invoke-Case 'guard (windows): a healthy station prints no warning and adds the rules pointer' {
        $result = Invoke-Guard (New-GuardFixture)
        Assert-GuardClean $result
        Assert-Equal $null $result.Message 'systemMessage'
        Assert-Equal 'SessionStart' $result.Json.hookSpecificOutput.hookEventName 'hookEventName'
        Assert-Contains $result.Context 'teststand-rules' 'additionalContext'
    }

    $GuardRows = @(
        @{ Name = 'TestStand is not detected';            Fixture = @{ NoTestStand = $true };  Named = @('TestStand');                       Optional = $false }
        @{ Name = 'neither py nor python is on PATH';     Fixture = @{ PyOut = $null };        Named = @('Python');                          Optional = $true }
        @{ Name = 'python-docx is not installed';         Fixture = @{ PyOut = '0 1' };        Named = @('python-docx', $PipInstallCommand); Optional = $true }
        @{ Name = 'Pillow is not installed';              Fixture = @{ PyOut = '1 0' };        Named = @('Pillow', $PipInstallCommand);      Optional = $true }
        @{ Name = 'neither Edge nor Chrome is installed'; Fixture = @{ NoBrowser = $true };    Named = @('Edge or Chrome');                  Optional = $true }
        @{ Name = 'TestStand and Pillow are missing';     Fixture = @{ NoTestStand = $true; PyOut = '1 0' }; Named = @('TestStand', 'Pillow', $PipInstallCommand); Optional = $true }
    )
    foreach ($row in $GuardRows) {
        Invoke-Case "guard (windows): $($row.Name) gives exactly one ASCII warning naming the item and its fix" {
            $fixtureArgs = $row.Fixture
            $result = Invoke-Guard (New-GuardFixture @fixtureArgs)
            Assert-GuardClean $result
            Assert-True ($null -ne $result.Message) 'expected a systemMessage'
            Assert-Equal 1 @($result.Json.PSObject.Properties | Where-Object { $_.Name -eq 'systemMessage' }).Count 'systemMessage fields'
            foreach ($named in $row.Named) { Assert-Contains $result.Message $named 'warning' }
            if ($row.Optional) { Assert-Contains $result.Message 'optional' 'warning states the doc and presentation agents are optional' }
            else { Assert-NotContains $result.Message 'optional' 'a TestStand-only warning' }
            Assert-Contains $result.Context 'teststand-rules' 'the rules pointer stays alongside a warning'
        }
    }

    Invoke-Case 'guard (windows): the TestStand fix reads install 2019 or later, or start Claude Code where TestStand is installed' {
        $result = Invoke-Guard (New-GuardFixture -NoTestStand)
        Assert-Contains $result.Message 'install NI TestStand 2019 or later, or start Claude Code where TestStand is installed' 'fix'
    }

    Invoke-Case 'guard (windows): the TestStand environment variable counts as detected' {
        $fixture = New-GuardFixture -NoTestStand
        $result = Invoke-Guard $fixture @{ TestStand = 'C:\somewhere\TestStand' }
        Assert-Equal $null $result.Message 'systemMessage'
    }

    Invoke-Case 'guard (windows): a TestStand folder under the Program Files (x86) root counts as detected' {
        $result = Invoke-Guard (New-GuardFixture)   # the default fixture installs TestStand under pf86 only
        Assert-Equal $null $result.Message 'systemMessage'
    }

    Invoke-Case 'guard (windows): a National Instruments folder without a TestStand folder is not detected' {
        $fixture = New-GuardFixture -NoTestStand
        [void](New-Item -ItemType Directory -Path (Join-Path $fixture.ProgramFiles 'National Instruments\LabVIEW 2024'))
        $result = Invoke-Guard $fixture
        Assert-Contains $result.Message 'TestStand' 'warning'
    }

    Invoke-Case 'guard (windows): python found through the fallback (py absent) prints no warning' {
        $result = Invoke-Guard (New-GuardFixture -PyOut $null -PythonOut '1 1')
        Assert-GuardClean $result
        Assert-Equal $null $result.Message 'systemMessage'
    }

    Invoke-Case 'guard (windows): a py launcher with no Python 3 falls back to python' {
        $result = Invoke-Guard (New-GuardFixture -PyOut 'No suitable Python runtime found' -PyExit 103 -PythonOut '1 1')
        Assert-Equal $null $result.Message 'systemMessage'
    }

    Invoke-Case 'guard (windows): a python that exits non-zero (Store alias stub) counts as no Python' {
        $result = Invoke-Guard (New-GuardFixture -PyOut $null -PythonOut 'Python was not found' -PythonExit 9009)
        Assert-Contains $result.Message 'Python' 'warning'
    }

    Invoke-Case 'guard (windows): unparsable probe output counts as no Python, not as a crash' {
        $result = Invoke-Guard (New-GuardFixture -PyOut 'banana')
        Assert-GuardClean $result
        Assert-Contains $result.Message 'Python' 'warning'
    }

    Invoke-Case 'guard (windows): a python-only station is told the python command, not the py launcher' {
        $result = Invoke-Guard (New-GuardFixture -PyOut $null -PythonOut '1 0')
        Assert-Contains $result.Message 'python -m pip install python-docx pillow' 'fix'
    }

    Invoke-Case 'guard (windows): a hanging interpreter is cut off and reported as no Python, within the budget' {
        $fixture = New-GuardFixture -PyOut '1 1' -PythonOut '1 1' -StubBody "ping -n 6 127.0.0.1 >nul`r`n"
        $result = Invoke-Guard $fixture
        Assert-GuardClean $result
        Assert-Contains $result.Message 'Python' 'warning'
        Assert-True ($result.ElapsedMs -lt 15000) "the guard took $($result.ElapsedMs) ms against a 6 s hang"
    }

    Invoke-Case 'guard (windows): the optional warning is shown once, then suppressed for 24 hours (boundary: 24 h exactly shows it again)' {
        $fixture = New-GuardFixture -PyOut '1 0'
        Assert-Contains (Invoke-Guard $fixture).Message 'Pillow' 'first run'
        $threeHours = Invoke-Guard $fixture -Now $FixedNow.AddHours(3)
        Assert-Equal $null $threeHours.Message 'after 3 h'
        Assert-Contains $threeHours.Context 'teststand-rules' 'the rules pointer is not throttled'
        $justUnder = Invoke-Guard $fixture -Now $FixedNow.AddHours(24).AddSeconds(-1)
        Assert-Equal $null $justUnder.Message 'after 23 h 59 m 59 s'
        $exactly = Invoke-Guard $fixture -Now $FixedNow.AddHours(24)
        Assert-Contains $exactly.Message 'Pillow' 'after exactly 24 h'
    }

    Invoke-Case 'guard (windows): a different missing set warns again at once' {
        $fixture = New-GuardFixture -PyOut '1 0'
        [void](Invoke-Guard $fixture)
        $fixture.Env['STUB_PY_OUT'] = '0 1'
        $changed = Invoke-Guard $fixture -Now $FixedNow.AddHours(1)
        Assert-Contains $changed.Message 'python-docx' 'a different missing set'
    }

    Invoke-Case 'guard (windows): a missing TestStand is reported every time while the optional part stays throttled' {
        $fixture = New-GuardFixture -NoTestStand -PyOut '1 0'
        $first = Invoke-Guard $fixture
        Assert-Contains $first.Message 'Pillow' 'first run lists the optional item'
        $second = Invoke-Guard $fixture -Now $FixedNow.AddHours(3)
        Assert-Contains $second.Message 'TestStand' 'second run still reports TestStand'
        Assert-NotContains $second.Message 'Pillow' 'second run no longer nags about Pillow'
        Assert-NotContains $second.Message 'optional' 'second run carries no optional note'
    }

    Invoke-Case 'guard (windows): a clock that moved backwards (state in the future) does not suppress the warning' {
        $fixture = New-GuardFixture -PyOut '1 0'
        [void](Invoke-Guard $fixture)
        $earlier = Invoke-Guard $fixture -Now $FixedNow.AddHours(-1)
        Assert-Contains $earlier.Message 'Pillow' 'state from the future'
    }

    Invoke-Case 'guard (windows): a corrupt state file does not suppress the warning or crash' {
        $fixture = New-GuardFixture -PyOut '1 0'
        [void](Invoke-Guard $fixture)
        foreach ($file in Get-ChildItem -LiteralPath $fixture.State -File) { [IO.File]::WriteAllText($file.FullName, '{ not json', $Utf8NoBom) }
        $result = Invoke-Guard $fixture -Now $FixedNow.AddHours(1)
        Assert-GuardClean $result
        Assert-Contains $result.Message 'Pillow' 'corrupt state'
    }

    Invoke-Case 'guard (windows): TESTSTAND_MCP_NO_PLATFORM_WARNING=1 hides the optional warning but not a missing TestStand' {
        $optionalOnly = Invoke-Guard (New-GuardFixture -PyOut '1 0') @{ TESTSTAND_MCP_NO_PLATFORM_WARNING = '1' }
        Assert-Equal $null $optionalOnly.Message 'optional warning with the opt-out'
        $withTestStand = Invoke-Guard (New-GuardFixture -NoTestStand -PyOut '1 0') @{ TESTSTAND_MCP_NO_PLATFORM_WARNING = '1' }
        Assert-Contains $withTestStand.Message 'TestStand' 'TestStand is still reported'
        Assert-NotContains $withTestStand.Message 'Pillow' 'the optional part stays off'
    }

    Invoke-Case 'guard (windows): any other value of the opt-out variable does not switch the warning off' {
        $result = Invoke-Guard (New-GuardFixture -PyOut '1 0') @{ TESTSTAND_MCP_NO_PLATFORM_WARNING = '0' }
        Assert-Contains $result.Message 'Pillow' 'opt-out value 0'
    }

    Invoke-Case 'guard (windows): the opt-out does not consume the throttle (the warning shows once it is lifted)' {
        $fixture = New-GuardFixture -PyOut '1 0'
        [void](Invoke-Guard $fixture @{ TESTSTAND_MCP_NO_PLATFORM_WARNING = '1' })
        Assert-Contains (Invoke-Guard $fixture -Now $FixedNow.AddHours(1)).Message 'Pillow' 'after the opt-out is lifted'
    }

    Invoke-Case 'guard (windows): an unwritable state directory still warns and exits 0' {
        $fixture = New-GuardFixture -PyOut '1 0'
        [IO.File]::WriteAllText($fixture.State, 'a file where the state directory should be', $Utf8NoBom)
        $result = Invoke-Guard $fixture
        Assert-GuardClean $result
        Assert-Contains $result.Message 'Pillow' 'unwritable state'
    }

    Invoke-Case 'guard (windows): the state goes to TESTSTAND_MCP_STATE_DIR, else CLAUDE_PLUGIN_DATA, else LOCALAPPDATA\teststand-mcp' {
        $fixture = New-GuardFixture -PyOut '1 0'
        $pluginData = Join-Path $fixture.Root 'plugin-data'
        $localAppData = Join-Path $fixture.Root 'local-app-data'
        [void](Invoke-Guard $fixture)
        Assert-True (@(Get-ChildItem -LiteralPath $fixture.State -File).Count -gt 0) 'state written to TESTSTAND_MCP_STATE_DIR'
        [void](Invoke-Guard $fixture @{ TESTSTAND_MCP_STATE_DIR = $null; CLAUDE_PLUGIN_DATA = $pluginData; LOCALAPPDATA = $localAppData })
        Assert-True (@(Get-ChildItem -LiteralPath $pluginData -File).Count -gt 0) 'state written to CLAUDE_PLUGIN_DATA'
        Assert-True (-not (Test-Path -LiteralPath $localAppData)) 'LOCALAPPDATA untouched while CLAUDE_PLUGIN_DATA is set'
        [void](Invoke-Guard $fixture @{ TESTSTAND_MCP_STATE_DIR = $null; CLAUDE_PLUGIN_DATA = $null; LOCALAPPDATA = $localAppData })
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $localAppData 'teststand-mcp') -File).Count -gt 0) 'state written to LOCALAPPDATA\teststand-mcp'
    }

    Invoke-Case 'guard (windows): the verdict agrees with the interpreter on this station (real python, no stubs)' {
        $realPython = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $realPython) { Write-Host '      (no python on this PATH: nothing to cross-check)'; return }
        $probe = 'import importlib.util as u; print(int(u.find_spec(''docx'') is not None), int(u.find_spec(''PIL'') is not None))'
        $direct = (& $realPython.Source -c $probe 2>$null | Out-String).Trim()
        $fixture = New-GuardFixture -PyOut $null
        $result = Invoke-Guard $fixture @{ PATH = ((Split-Path -Parent $realPython.Source) + ';' + $fixture.Env['PATH']) }
        Assert-GuardClean $result
        $names = @{ '1 1' = @(); '0 1' = @('python-docx'); '1 0' = @('Pillow'); '0 0' = @('python-docx', 'Pillow') }
        Assert-True $names.ContainsKey($direct) "unexpected real probe output [$direct]"
        if ($names[$direct].Count -eq 0) { Assert-Equal $null $result.Message 'systemMessage' }
        foreach ($name in $names[$direct]) { Assert-Contains $result.Message $name 'warning' }
    }

    # === Step 4.2: the non-Windows twin (platform-guard.sh, POSIX sh) ====================
    # Needs a POSIX sh with tr and sed (Git for Windows ships one); without it the cases report SKIP.
    function Find-PosixShell {
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
        foreach ($root in $roots) {
            foreach ($relative in 'Git\usr\bin\sh.exe', 'Git\bin\sh.exe') {
                $candidate = Join-Path $root $relative
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }
        $found = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $found) { return $found.Source }
        return $null
    }
    $PosixShell = Find-PosixShell

    # Runs platform-guard.sh with a stubbed `uname`; $UnameExit non-zero simulates a uname that fails.
    function Invoke-GuardSh {
        param([AllowEmptyString()][string]$UnameOutput, [int]$UnameExit = 0)
        $stubDir = New-TempDir
        $stub = "#!/bin/sh`necho `"`$STUB_UNAME`"`nexit `$STUB_UNAME_EXIT`n"
        [IO.File]::WriteAllText((Join-Path $stubDir 'uname'), $stub, $Utf8NoBom)
        $shellDir = Split-Path -Parent $PosixShell
        $toolDirs = @($shellDir, (Join-Path (Split-Path -Parent $shellDir) 'usr\bin'), (Join-Path (Split-Path -Parent $shellDir) 'bin')) | Where-Object { Test-Path -LiteralPath $_ }
        $envOverrides = @{ PATH = ((@($stubDir) + $toolDirs) -join ';'); STUB_UNAME = $UnameOutput; STUB_UNAME_EXIT = $UnameExit }
        $result = Invoke-ProcessWithStdin -FileName $PosixShell -Arguments ('"' + $GuardShPath + '"') -StdinText '{"source":"startup"}' -EnvOverrides $envOverrides
        return $result
    }

    function Invoke-ShCase {
        param([string]$Name, [scriptblock]$Body)
        if ($null -eq $PosixShell) { Write-Host "SKIP  $Name (no POSIX sh on this station)"; return }
        Invoke-Case $Name $Body
    }

    foreach ($os in 'Linux', 'Darwin', 'FreeBSD') {
        Invoke-ShCase "guard (sh): a $os host gets one message that the server needs Windows with TestStand" {
            $result = Invoke-GuardSh $os
            Assert-Equal 0 $result.ExitCode "exit code (stderr: $($result.Stderr))"
            Assert-Equal '' $result.Stderr 'stderr'
            Assert-AsciiOnly $result.Stdout 'stdout'
            $json = $result.Stdout | ConvertFrom-Json
            Assert-Equal 1 @($json.PSObject.Properties).Count 'output fields'
            Assert-Contains $json.systemMessage 'Windows' 'message'
            Assert-Contains $json.systemMessage 'TestStand' 'message'
            Assert-Contains $json.systemMessage $os 'message names the host'
        }
    }

    foreach ($os in 'MINGW64_NT-10.0-26200', 'MINGW32_NT-10.0', 'MSYS_NT-10.0-22631', 'CYGWIN_NT-10.0', 'Windows_NT') {
        Invoke-ShCase "guard (sh): a Windows host reporting $os stays silent (the .ps1 speaks there)" {
            $result = Invoke-GuardSh $os
            Assert-Equal 0 $result.ExitCode "exit code (stderr: $($result.Stderr))"
            Assert-Equal '' $result.Stdout 'stdout'
            Assert-Equal '' $result.Stderr 'stderr'
        }
    }

    Invoke-ShCase 'guard (sh): a uname that fails or prints nothing stays silent and exits 0' {
        foreach ($case in @(@('', 0), @('', 1), @('Linux', 1))) {
            $result = Invoke-GuardSh $case[0] $case[1]
            Assert-Equal 0 $result.ExitCode "exit code for [$($case[0])]/$($case[1])"
            Assert-Equal '' $result.Stdout "stdout for [$($case[0])]/$($case[1])"
        }
    }

    Invoke-ShCase 'guard (sh): a hostile uname value is escaped into valid ASCII JSON' {
        $hostile = 'Evil"OS\with' + [char]0x00E9 + ' quotes'
        $result = Invoke-GuardSh $hostile
        Assert-Equal 0 $result.ExitCode 'exit code'
        Assert-AsciiOnly $result.Stdout 'stdout'
        $json = $result.Stdout | ConvertFrom-Json
        Assert-Contains $json.systemMessage 'Windows' 'message'
        Assert-NotContains $json.systemMessage ([string][char]0x00E9) 'message'
    }

    # === Step 4.3: the update-notify hook =============================================
    # A local HttpListener stands in for github.com/<repo>/releases/latest. It runs in its own runspace and
    # answers every request according to $Mode: redirect (302 + Location), status (a plain status code),
    # nolocation (302 without a Location header) or hang (holds the request for 20 s).
    $StubServerSource = {
        param($Prefix, $Mode, $Location, $StatusCode, $Stats)
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        $Stats.Ready = $true
        try {
            while (-not $Stats.Stop) {
                $pending = $listener.GetContextAsync()
                while (-not $pending.Wait(50)) { if ($Stats.Stop) { return } }
                $context = $pending.Result
                $Stats.Count = $Stats.Count + 1
                $Stats.Method = $context.Request.HttpMethod
                $Stats.Path = $context.Request.Url.AbsolutePath
                switch ($Mode) {
                    'redirect'   { $context.Response.StatusCode = 302; $context.Response.RedirectLocation = $Location; $context.Response.Close() }
                    'status'     { $context.Response.StatusCode = $StatusCode; $context.Response.Close() }
                    'nolocation' { $context.Response.StatusCode = 302; $context.Response.Close() }
                    'hang' {
                        $waited = 0
                        while ($waited -lt 20000 -and -not $Stats.Stop) { Start-Sleep -Milliseconds 100; $waited += 100 }
                        $context.Response.Abort()
                    }
                }
            }
        } finally {
            $listener.Abort()
        }
    }

    function Get-FreeLoopbackPort {
        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        try { return $probe.LocalEndpoint.Port } finally { $probe.Stop() }
    }

    $script:StubServers = @()

    function Start-StubReleaseServer {
        param([ValidateSet('redirect', 'status', 'nolocation', 'hang')][string]$Mode, [string]$Location = '', [int]$StatusCode = 500)
        $port = Get-FreeLoopbackPort
        $stats = [hashtable]::Synchronized(@{ Ready = $false; Stop = $false; Count = 0; Method = ''; Path = '' })
        $shell = [powershell]::Create()
        [void]$shell.AddScript($StubServerSource).AddArgument("http://127.0.0.1:$port/").AddArgument($Mode).AddArgument($Location).AddArgument($StatusCode).AddArgument($stats)
        $handle = $shell.BeginInvoke()
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not $stats.Ready -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        if (-not $stats.Ready) { throw 'the stub release server did not start' }
        $server = [pscustomobject]@{ BaseUrl = "http://127.0.0.1:$port/Zuehlke/teststand-mcp"; Stats = $stats; Shell = $shell; Handle = $handle }
        $script:StubServers += $server
        return $server
    }

    function Stop-StubReleaseServer {
        param($Server)
        if ($Server.Stats.Stop) { return }
        $Server.Stats.Stop = $true
        try { [void]$Server.Shell.EndInvoke($Server.Handle) } catch { }
        $Server.Shell.Dispose()
    }

    $NotifyScriptPath = Join-Path $HooksDir 'update-notify.ps1'
    $MarketplaceName = (Get-Content -LiteralPath (Join-Path $RepoRoot '.claude-plugin\marketplace.json') -Raw | ConvertFrom-Json).name
    $PluginName = (Get-PluginIdentity).name
    $NotifyStateFile = 'update-notify.json'
    $Hours = 3600

    # A plugin root holding .claude-plugin/plugin.json with the given version text, a state directory, a stub server.
    function New-NotifyFixture {
        param([string]$Installed = '1.9.0', [string]$Mode = 'redirect', [string]$Location = 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v1.10.0',
              [int]$StatusCode = 500, [switch]$NoServer, [switch]$NoPluginJson)
        $root = New-TempDir
        $pluginRoot = Join-Path $root 'plugin-root'
        [void](New-Item -ItemType Directory -Path (Join-Path $pluginRoot '.claude-plugin'))
        if (-not $NoPluginJson) {
            [IO.File]::WriteAllText((Join-Path $pluginRoot '.claude-plugin\plugin.json'), ('{"name":"' + $PluginName + '","version":"' + $Installed + '"}'), $Utf8NoBom)
        }
        $server = $null
        $baseUrl = 'http://127.0.0.1:' + (Get-FreeLoopbackPort) + '/Zuehlke/teststand-mcp'   # nothing listens there
        if (-not $NoServer) { $server = Start-StubReleaseServer -Mode $Mode -Location $Location -StatusCode $StatusCode; $baseUrl = $server.BaseUrl }
        return [pscustomobject]@{ PluginRoot = $pluginRoot; State = (Join-Path $root 'state'); Server = $server; BaseUrl = $baseUrl }
    }

    function Invoke-Notify {
        param($Fixture, [DateTimeOffset]$Now = $FixedNow, [hashtable]$Extra = @{})
        $envOverrides = @{
            CLAUDE_PLUGIN_ROOT              = $Fixture.PluginRoot
            TESTSTAND_MCP_STATE_DIR         = $Fixture.State
            TESTSTAND_MCP_NOW               = $Now.ToString('o')
            TESTSTAND_MCP_RELEASES_BASE_URL = $Fixture.BaseUrl
            TESTSTAND_MCP_NO_UPDATE_CHECK   = $null
            CLAUDE_PLUGIN_DATA              = $null
        }
        foreach ($key in $Extra.Keys) { $envOverrides[$key] = $Extra[$key] }
        $result = Invoke-HookScript -ScriptPath $NotifyScriptPath -StdinText '{"hook_event_name":"SessionStart","source":"startup"}' -EnvOverrides $envOverrides
        $json = $null; $message = $null
        if ($result.Stdout.Trim().Length -gt 0) {
            $json = $result.Stdout | ConvertFrom-Json
            if ($null -ne $json.PSObject.Properties['systemMessage']) { $message = $json.systemMessage }
        }
        $result | Add-Member -NotePropertyName Json -NotePropertyValue $json
        $result | Add-Member -NotePropertyName Message -NotePropertyValue $message
        return $result
    }

    function Assert-NotifySilent {
        param($Result, [string]$What = 'hook')
        Assert-Equal 0 $Result.ExitCode "$What exit code (stderr: $($Result.Stderr))"
        Assert-Equal '' $Result.Stdout "$What stdout"
        Assert-Equal '' $Result.Stderr "$What stderr"
    }

    # Writes the hook's own state file, to put it into a state no sequence of runs reaches in one step.
    function Set-NotifyState {
        param($Fixture, [Nullable[long]]$LookupAgeSeconds = $null, [bool]$LookupOk = $true, [string]$Latest = '',
              [string]$Announced = '', [Nullable[long]]$AnnouncedAgeSeconds = $null)
        $state = [ordered]@{}
        if ($null -ne $LookupAgeSeconds) { $state['lookupEpoch'] = $FixedNow.ToUnixTimeSeconds() - $LookupAgeSeconds; $state['lookupOk'] = $LookupOk; $state['latestVersion'] = $Latest }
        if ($null -ne $AnnouncedAgeSeconds) { $state['announcedVersion'] = $Announced; $state['announcedEpoch'] = $FixedNow.ToUnixTimeSeconds() - $AnnouncedAgeSeconds }
        [void][IO.Directory]::CreateDirectory($Fixture.State)
        [IO.File]::WriteAllText((Join-Path $Fixture.State $NotifyStateFile), ($state | ConvertTo-Json -Compress), $Utf8NoBom)
    }

    try {
        Invoke-Case 'notify: an installed version behind the latest release prints one ASCII message with the two commands in order' {
            $fixture = New-NotifyFixture
            $result = Invoke-Notify $fixture
            Assert-Equal 0 $result.ExitCode "exit code (stderr: $($result.Stderr))"
            Assert-Equal '' $result.Stderr 'stderr'
            Assert-AsciiOnly $result.Stdout 'stdout'
            Assert-True ($null -ne $result.Message) 'expected a systemMessage'
            Assert-Equal 1 @($result.Json.PSObject.Properties).Count 'output fields'
            foreach ($part in '1.9.0', '1.10.0', 'restart Claude Code', 'auto-update') { Assert-Contains $result.Message $part 'message' }
            $first = "1. claude plugin marketplace update $MarketplaceName"
            $second = "2. claude plugin update $PluginName"
            Assert-Contains $result.Message $first 'step 1'
            Assert-Contains $result.Message $second 'step 2'
            Assert-True ($result.Message.IndexOf($first, [StringComparison]::Ordinal) -lt $result.Message.IndexOf($second, [StringComparison]::Ordinal)) 'step 1 comes before step 2'
            Assert-Equal 1 $fixture.Server.Stats.Count 'requests'
            Assert-Equal 'HEAD' $fixture.Server.Stats.Method 'request method'
            Assert-Equal '/Zuehlke/teststand-mcp/releases/latest' $fixture.Server.Stats.Path 'request path'
        }

        Invoke-Case 'notify: the same version is announced once, then not again 3 hours later (and no second request)' {
            $fixture = New-NotifyFixture
            Assert-True ($null -ne (Invoke-Notify $fixture).Message) 'first run announces'
            $second = Invoke-Notify $fixture -Now $FixedNow.AddHours(3)
            Assert-NotifySilent $second 'second run'
            Assert-Equal 1 $fixture.Server.Stats.Count 'requests (the lookup is cached for 24 h)'
        }

        $SilentRows = @(
            @{ Name = 'the installed version equals the latest';        Installed = '1.10.0'; Mode = 'redirect'; Location = 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v1.10.0'; Requests = 1 }
            @{ Name = 'the latest is lower than the installed version'; Installed = '1.10.0'; Mode = 'redirect'; Location = 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v1.9.0';  Requests = 1 }
            @{ Name = 'the installed version is the 0.0.0 placeholder'; Installed = '0.0.0';  Mode = 'redirect'; Location = 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v9.9.9';  Requests = 0 }
            @{ Name = 'the installed version is not a version';         Installed = 'dev';    Mode = 'redirect'; Location = 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v9.9.9';  Requests = 0 }
            @{ Name = 'the lookup returns a server error';              Installed = '1.9.0';  Mode = 'status';   StatusCode = 500; Requests = 1 }
            @{ Name = 'the lookup returns 404';                         Installed = '1.9.0';  Mode = 'status';   StatusCode = 404; Requests = 1 }
            @{ Name = 'the lookup answers 200 and no redirect';         Installed = '1.9.0';  Mode = 'status';   StatusCode = 200; Requests = 1 }
            @{ Name = 'the redirect has no Location header';            Installed = '1.9.0';  Mode = 'nolocation'; Requests = 1 }
            @{ Name = 'the redirect is an unparsable text';             Installed = '1.9.0';  Mode = 'redirect'; Location = '/banana'; Requests = 1 }
            @{ Name = 'the redirect does not name a tag';               Installed = '1.9.0';  Mode = 'redirect'; Location = 'https://github.com/Zuehlke/teststand-mcp/releases'; Requests = 1 }
            @{ Name = 'the redirect names a malformed tag (v1.x)';      Installed = '1.9.0';  Mode = 'redirect'; Location = 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v1.x'; Requests = 1 }
            @{ Name = 'the redirect names a two-part tag (v2.0)';       Installed = '1.9.0';  Mode = 'redirect'; Location = 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v2.0'; Requests = 1 }
            @{ Name = 'the redirect names a pre-release tag (v2.0.0-rc1)'; Installed = '1.9.0'; Mode = 'redirect'; Location = 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v2.0.0-rc1'; Requests = 1 }
            @{ Name = 'the redirect names an overflowing tag';          Installed = '1.9.0';  Mode = 'redirect'; Location = 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v99999999999.0.0'; Requests = 1 }
        )
        foreach ($row in $SilentRows) {
            Invoke-Case "notify: silent when $($row.Name)" {
                $fixtureArgs = @{ Installed = $row.Installed; Mode = $row.Mode }
                if ($row.ContainsKey('Location')) { $fixtureArgs.Location = $row.Location }
                if ($row.ContainsKey('StatusCode')) { $fixtureArgs.StatusCode = $row.StatusCode }
                $fixture = New-NotifyFixture @fixtureArgs
                $result = Invoke-Notify $fixture
                Assert-NotifySilent $result
                Assert-Equal $row.Requests $fixture.Server.Stats.Count 'requests'
            }
        }

        Invoke-Case 'notify: TESTSTAND_MCP_NO_UPDATE_CHECK=1 prints nothing and makes no request' {
            $fixture = New-NotifyFixture
            $result = Invoke-Notify $fixture -Extra @{ TESTSTAND_MCP_NO_UPDATE_CHECK = '1' }
            Assert-NotifySilent $result
            Assert-Equal 0 $fixture.Server.Stats.Count 'requests'
        }

        Invoke-Case 'notify: any other value of the opt-out variable does not switch the check off' {
            $fixture = New-NotifyFixture
            $result = Invoke-Notify $fixture -Extra @{ TESTSTAND_MCP_NO_UPDATE_CHECK = '0' }
            Assert-True ($null -ne $result.Message) 'expected the announcement'
        }

        Invoke-Case 'notify: a missing plugin.json prints nothing and makes no request' {
            $fixture = New-NotifyFixture -NoPluginJson
            Assert-NotifySilent (Invoke-Notify $fixture)
            Assert-Equal 0 $fixture.Server.Stats.Count 'requests'
        }

        Invoke-Case 'notify: a server that is not listening is silent' {
            $fixture = New-NotifyFixture -NoServer
            Assert-NotifySilent (Invoke-Notify $fixture)
        }

        Invoke-Case 'notify: a lookup that hangs is cut off after the 3 second HTTP timeout and exits 0 silently' {
            $fixture = New-NotifyFixture -Mode hang
            $result = Invoke-Notify $fixture
            Assert-NotifySilent $result
            Assert-True ($result.ElapsedMs -ge 2500) "returned after $($result.ElapsedMs) ms: the hook did not wait for the 3 s timeout"
            Assert-True ($result.ElapsedMs -lt 10000) "returned after $($result.ElapsedMs) ms: the hang was not cut off"
            if (-not $env:CI) { Assert-True ($result.ElapsedMs -lt 5000) "local check: $($result.ElapsedMs) ms exceeds the 5 s hook budget" }
        }

        Invoke-Case 'notify: the HTTP timeout constant is 3 seconds and TLS 1.2 is set explicitly' {
            . $NotifyScriptPath
            Assert-Equal 3000 $script:HttpTimeoutMilliseconds 'timeout (ms)'
            Set-HookTls12
            Assert-True (([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) -ne 0) 'TLS 1.2 flag'
        }

        Invoke-Case 'notify: an upper-case tag in the redirect (V1.8.6) is read as 1.8.6' {
            $fixture = New-NotifyFixture -Installed '1.8.0' -Location 'https://github.com/Zuehlke/teststand-mcp/releases/tag/V1.8.6'
            $result = Invoke-Notify $fixture
            Assert-Contains $result.Message '1.8.6' 'message'
            Assert-NotContains $result.Message 'V1.8.6' 'the V is stripped'
        }

        Invoke-Case 'notify: a relative Location (path only) is understood' {
            $fixture = New-NotifyFixture -Location '/Zuehlke/teststand-mcp/releases/tag/v1.10.0'
            Assert-Contains (Invoke-Notify $fixture).Message '1.10.0' 'message'
        }

        Invoke-Case 'notify: versions compare numerically (1.10.0 is newer than 1.9.0)' {
            $fixture = New-NotifyFixture -Installed '1.9.0' -Location 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v1.10.0'
            Assert-True ($null -ne (Invoke-Notify $fixture).Message) '1.10.0 > 1.9.0'
            $fixture = New-NotifyFixture -Installed '1.10.0' -Location 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v1.9.0'
            Assert-Equal $null (Invoke-Notify $fixture).Message '1.9.0 < 1.10.0'
        }

        # --- cache boundaries (the state is written directly: no run sequence reaches "stale lookup, fresh announcement") ---
        Invoke-Case 'notify cache: a lookup that failed 2 hours ago makes no request and prints nothing' {
            $fixture = New-NotifyFixture
            Set-NotifyState $fixture -LookupAgeSeconds (2 * $Hours) -LookupOk $false
            Assert-NotifySilent (Invoke-Notify $fixture)
            Assert-Equal 0 $fixture.Server.Stats.Count 'requests'
        }

        Invoke-Case 'notify cache: a lookup that failed 25 hours ago looks up again' {
            $fixture = New-NotifyFixture
            Set-NotifyState $fixture -LookupAgeSeconds (25 * $Hours) -LookupOk $false
            $result = Invoke-Notify $fixture
            Assert-Equal 1 $fixture.Server.Stats.Count 'requests'
            Assert-Contains $result.Message '1.10.0' 'message'
        }

        Invoke-Case 'notify cache: a failed lookup is cached too, so an offline station pays the timeout once per 24 hours' {
            $fixture = New-NotifyFixture -Mode status -StatusCode 500
            Assert-NotifySilent (Invoke-Notify $fixture) 'first run'
            Assert-NotifySilent (Invoke-Notify $fixture -Now $FixedNow.AddHours(2)) 'second run'
            Assert-Equal 1 $fixture.Server.Stats.Count 'requests after 2 h'
            Assert-NotifySilent (Invoke-Notify $fixture -Now $FixedNow.AddHours(25)) 'third run'
            Assert-Equal 2 $fixture.Server.Stats.Count 'requests after 25 h'
        }

        Invoke-Case 'notify cache boundary: the lookup is cached up to 23 h 59 m 59 s and repeated at exactly 24 h' {
            $fixture = New-NotifyFixture
            Set-NotifyState $fixture -LookupAgeSeconds (24 * $Hours - 1) -LookupOk $false
            Assert-NotifySilent (Invoke-Notify $fixture) 'just under 24 h'
            Assert-Equal 0 $fixture.Server.Stats.Count 'requests just under 24 h'
            Set-NotifyState $fixture -LookupAgeSeconds (24 * $Hours) -LookupOk $false
            [void](Invoke-Notify $fixture)
            Assert-Equal 1 $fixture.Server.Stats.Count 'requests at exactly 24 h'
        }

        Invoke-Case 'notify cache: 1.10.0 announced 25 hours ago and still the latest is announced again' {
            $fixture = New-NotifyFixture
            Set-NotifyState $fixture -LookupAgeSeconds (25 * $Hours) -Latest '1.10.0' -Announced '1.10.0' -AnnouncedAgeSeconds (25 * $Hours)
            Assert-Contains (Invoke-Notify $fixture).Message '1.10.0' 'message'
        }

        Invoke-Case 'notify cache boundary: an announcement is repeated at exactly 24 h and not at 23 h 59 m 59 s' {
            $fixture = New-NotifyFixture
            Set-NotifyState $fixture -LookupAgeSeconds (25 * $Hours) -Latest '1.10.0' -Announced '1.10.0' -AnnouncedAgeSeconds (24 * $Hours - 1)
            Assert-NotifySilent (Invoke-Notify $fixture) 'just under 24 h'
            $fixture = New-NotifyFixture
            Set-NotifyState $fixture -LookupAgeSeconds (25 * $Hours) -Latest '1.10.0' -Announced '1.10.0' -AnnouncedAgeSeconds (24 * $Hours)
            Assert-Contains (Invoke-Notify $fixture).Message '1.10.0' 'exactly 24 h'
        }

        Invoke-Case 'notify cache: 1.10.0 announced 3 hours ago and 1.11.0 now the latest announces 1.11.0' {
            $fixture = New-NotifyFixture -Location 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v1.11.0'
            Set-NotifyState $fixture -LookupAgeSeconds (25 * $Hours) -Latest '1.10.0' -Announced '1.10.0' -AnnouncedAgeSeconds (3 * $Hours)
            $result = Invoke-Notify $fixture
            Assert-Contains $result.Message '1.11.0' 'message'
            Assert-NotContains $result.Message '1.10.0' 'the older announcement is not repeated'
        }

        Invoke-Case 'notify cache: an announcement stamped in the future (clock moved back) does not suppress the message' {
            $fixture = New-NotifyFixture
            Set-NotifyState $fixture -LookupAgeSeconds (25 * $Hours) -Latest '1.10.0' -Announced '1.10.0' -AnnouncedAgeSeconds (-2 * $Hours)
            Assert-Contains (Invoke-Notify $fixture).Message '1.10.0' 'message'
        }

        Invoke-Case 'notify cache: a corrupt state file is ignored, the lookup runs and the state is repaired' {
            $fixture = New-NotifyFixture
            [void][IO.Directory]::CreateDirectory($fixture.State)
            [IO.File]::WriteAllText((Join-Path $fixture.State $NotifyStateFile), '{ nope', $Utf8NoBom)
            Assert-Contains (Invoke-Notify $fixture).Message '1.10.0' 'message'
            Assert-NotifySilent (Invoke-Notify $fixture -Now $FixedNow.AddHours(1)) 'second run after the repair'
        }

        Invoke-Case 'notify cache: an unwritable state directory still announces and exits 0' {
            $fixture = New-NotifyFixture
            [IO.File]::WriteAllText($fixture.State, 'a file where the state directory should be', $Utf8NoBom)
            $result = Invoke-Notify $fixture
            Assert-Equal 0 $result.ExitCode "exit code (stderr: $($result.Stderr))"
            Assert-Contains $result.Message '1.10.0' 'message'
        }

        Invoke-Case 'notify: the state goes to CLAUDE_PLUGIN_DATA when TESTSTAND_MCP_STATE_DIR is unset' {
            $fixture = New-NotifyFixture
            $pluginData = Join-Path (Split-Path -Parent $fixture.PluginRoot) 'plugin-data'
            [void](Invoke-Notify $fixture -Extra @{ TESTSTAND_MCP_STATE_DIR = $null; CLAUDE_PLUGIN_DATA = $pluginData })
            Assert-True (Test-Path -LiteralPath (Join-Path $pluginData $NotifyStateFile)) 'state file in CLAUDE_PLUGIN_DATA'
        }

        Invoke-Case 'notify: the plugin root falls back to the folder above the script when CLAUDE_PLUGIN_ROOT is unset' {
            $fixture = New-NotifyFixture
            $result = Invoke-Notify $fixture -Extra @{ CLAUDE_PLUGIN_ROOT = $null }   # the repo's plugin.json is the 0.0.0 placeholder
            Assert-NotifySilent $result
            Assert-Equal 0 $fixture.Server.Stats.Count 'requests'
        }

        # --- the pure decision --------------------------------------------------------------------------------
        Invoke-Case 'notify (pure): Convert-TagToVersion accepts X.Y.Z with an optional v or V and refuses everything else' {
            . $NotifyScriptPath
            Assert-Equal '1.10.0' ([string](Convert-TagToVersion 'v1.10.0')) 'v1.10.0'
            Assert-Equal '1.8.6' ([string](Convert-TagToVersion 'V1.8.6')) 'V1.8.6'
            Assert-Equal '1.2.3' ([string](Convert-TagToVersion '1.2.3')) '1.2.3'
            foreach ($bad in 'v1.x', 'v1.2', 'v1.2.3.4', 'v1.2.3-rc1', '', ' ', 'vv1.2.3', 'v-1.2.3', 'v1.2.3 ', 'latest', 'v99999999999.0.0') {
                Assert-Equal $null (Convert-TagToVersion $bad) "tag [$bad]"
            }
            Assert-Equal $null (Convert-TagToVersion $null) 'null tag'
        }

        Invoke-Case 'notify (pure): Get-UpdateMessage decides only on versions and the announcement age' {
            . $NotifyScriptPath
            $now = 1000000000L
            $day = 24 * 3600
            $v = { param($text) [version]$text }
            Assert-Equal $null (Get-UpdateMessage -Installed (& $v '1.9.0') -Latest $null -AnnouncedVersion '' -AnnouncedEpoch 0 -NowEpoch $now) 'no latest'
            Assert-Equal $null (Get-UpdateMessage -Installed (& $v '1.9.0') -Latest (& $v '1.9.0') -AnnouncedVersion '' -AnnouncedEpoch 0 -NowEpoch $now) 'equal'
            Assert-Equal $null (Get-UpdateMessage -Installed (& $v '1.10.0') -Latest (& $v '1.9.9') -AnnouncedVersion '' -AnnouncedEpoch 0 -NowEpoch $now) 'lower'
            Assert-True ($null -ne (Get-UpdateMessage -Installed (& $v '1.9.0') -Latest (& $v '1.10.0') -AnnouncedVersion '' -AnnouncedEpoch 0 -NowEpoch $now)) 'newer'
            Assert-Equal $null (Get-UpdateMessage -Installed (& $v '1.9.0') -Latest (& $v '1.10.0') -AnnouncedVersion '1.10.0' -AnnouncedEpoch ($now - $day + 1) -NowEpoch $now) 'announced just under 24 h ago'
            Assert-True ($null -ne (Get-UpdateMessage -Installed (& $v '1.9.0') -Latest (& $v '1.10.0') -AnnouncedVersion '1.10.0' -AnnouncedEpoch ($now - $day) -NowEpoch $now)) 'announced exactly 24 h ago'
            Assert-True ($null -ne (Get-UpdateMessage -Installed (& $v '1.9.0') -Latest (& $v '1.11.0') -AnnouncedVersion '1.10.0' -AnnouncedEpoch ($now - 60) -NowEpoch $now)) 'a newer version than the announced one'
        }
    } finally { }

    Invoke-Case 'guard (windows): a repeated warning renews the throttle (silent one hour after the 24 h repeat)' {
        $fixture = New-GuardFixture -PyOut '1 0'
        [void](Invoke-Guard $fixture)
        Assert-Contains (Invoke-Guard $fixture -Now $FixedNow.AddHours(24)).Message 'Pillow' 'repeat after 24 h'
        Assert-Equal $null (Invoke-Guard $fixture -Now $FixedNow.AddHours(25)).Message 'one hour after the repeat'
    }

    # === Step 4.4: hooks.json wiring and build/New-HooksJson.ps1 ===================================
    $HooksJsonPath = Join-Path $HooksDir 'hooks.json'
    $NewHooksJsonPath = Join-Path $RepoRoot 'build\New-HooksJson.ps1'
    $PluginRootToken = '${CLAUDE_PLUGIN_ROOT}'
    $ExactMatcherPattern = '\A[A-Za-z0-9_|-]+\z'   # the "list of exact strings" character set of the hooks docs
    $SessionStartTimeoutSeconds = 5

    function Read-HooksJson { return ([IO.File]::ReadAllText($HooksJsonPath, $Utf8NoBom) | ConvertFrom-Json) }

    # Runs New-HooksJson.ps1 in a child host; returns exit code and text.
    function Invoke-NewHooksJson {
        param([string[]]$ScriptArguments = @())
        $quoted = ($ScriptArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        return Invoke-ProcessWithStdin -FileName $HostPath -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $NewHooksJsonPath + '" ' + $quoted) -StdinText ''
    }

    # The `${CLAUDE_PLUGIN_ROOT}/hooks/<name>` path inside a hook command, with the root substituted.
    function Get-CommandScriptPath {
        param([string]$Command, [string]$PluginRoot)
        $match = [regex]::Match($Command, '"(\$\{CLAUDE_PLUGIN_ROOT\}/hooks/[^"]+)"')
        if (-not $match.Success) { throw "no quoted \${CLAUDE_PLUGIN_ROOT} script path in [$Command]" }
        return $match.Groups[1].Value.Replace($PluginRootToken, $PluginRoot).Replace('/', '\')
    }

    # Runs a hooks.json command the way `"shell": "powershell"` does: as PowerShell text, with the
    # placeholder substituted. -EncodedCommand carries the text without any command-line encoding loss.
    function Invoke-HookCommand {
        param([string]$Command, [string]$PluginRoot, [string]$StdinText, [hashtable]$EnvOverrides = @{})
        $text = $Command.Replace($PluginRootToken, $PluginRoot)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text))
        $envMap = @{ CLAUDE_PLUGIN_ROOT = $PluginRoot }
        foreach ($key in $EnvOverrides.Keys) { $envMap[$key] = $EnvOverrides[$key] }
        return Invoke-ProcessWithStdin -FileName $HostPath -Arguments ('-NoProfile -NonInteractive -EncodedCommand ' + $encoded) -StdinText $StdinText -EnvOverrides $envMap
    }

    Invoke-Case 'wiring: hooks.json has a description and exactly the PreToolUse and SessionStart events' {
        $config = Read-HooksJson
        Assert-True (-not [string]::IsNullOrWhiteSpace($config.description)) 'a top-level description'
        Assert-AsciiOnly $config.description 'description'
        Assert-Equal 'PreToolUse,SessionStart' (@($config.hooks.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'events'
    }

    Invoke-Case 'wiring: the PreToolUse matcher is exactly the allow-listed names, each with the plugin tool prefix' {
        $config = Read-HooksJson
        $groups = @($config.hooks.PreToolUse)
        Assert-Equal 1 $groups.Count 'PreToolUse groups'
        $matcher = [string]$groups[0].matcher
        Assert-True ($matcher -cmatch $ExactMatcherPattern) 'the matcher uses only exact-string characters, so it is no regular expression'
        $expected = @((Read-ToolClasses -Path $ToolClassesPath).allow | ForEach-Object { $IdentityPrefix + $_ })
        Assert-Equal 75 $expected.Count 'allow-listed tools'
        Assert-Equal ($expected -join '|') $matcher 'matcher'
    }

    Invoke-Case 'wiring: no prompting tool and no named exclusion is in the PreToolUse matcher' {
        $names = ([string](Read-HooksJson).hooks.PreToolUse[0].matcher).Split('|')
        $classes = Read-ToolClasses -Path $ToolClassesPath
        $leaks = @($classes.prompt | Where-Object { $names -ccontains ($IdentityPrefix + $_) })
        Assert-Equal '' ($leaks -join ',') 'prompting tools that would start the hook'
        Assert-True (@($names | Where-Object { -not $_.StartsWith($IdentityPrefix, [StringComparison]::Ordinal) }).Count -eq 0) 'every name has the prefix'
    }

    Invoke-Case 'wiring: every hook is a PowerShell-pinned command with a quoted script path that exists' {
        $config = Read-HooksJson
        $pluginRoot = Join-Path $RepoRoot 'plugin'
        $hooks = @($config.hooks.PreToolUse.hooks) + @($config.hooks.SessionStart.hooks)
        Assert-Equal 3 $hooks.Count 'hook entries (allow, guard, notify)'
        foreach ($hook in $hooks) {
            Assert-Equal 'command' $hook.type 'type'
            Assert-Equal 'powershell' $hook.shell 'shell'
            Assert-True ($hook.command -cmatch '\Apowershell -NoProfile -ExecutionPolicy Bypass -File "\$\{CLAUDE_PLUGIN_ROOT\}/hooks/[A-Za-z0-9._-]+\.ps1"\z') "command [$($hook.command)]"
            $scriptPath = Get-CommandScriptPath $hook.command $pluginRoot
            Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "script missing: $scriptPath"
        }
        Assert-Equal 'allow-readonly.ps1' (Split-Path -Leaf (Get-CommandScriptPath $config.hooks.PreToolUse[0].hooks[0].command $pluginRoot)) 'PreToolUse script'
    }

    Invoke-Case 'wiring: the SessionStart entries match startup only and each carries a timeout of at most 5 seconds' {
        $groups = @((Read-HooksJson).hooks.SessionStart)
        Assert-True ($groups.Count -ge 1) 'a SessionStart group'
        $scripts = @()
        foreach ($group in $groups) {
            Assert-Equal 'startup' $group.matcher 'matcher'
            foreach ($hook in @($group.hooks)) {
                Assert-True ($hook.timeout -is [int] -or $hook.timeout -is [long]) "timeout is a number in seconds: [$($hook.timeout)]"
                Assert-True ($hook.timeout -gt 0 -and $hook.timeout -le $SessionStartTimeoutSeconds) "timeout [$($hook.timeout)]"
                $scripts += (Split-Path -Leaf (Get-CommandScriptPath $hook.command (Join-Path $RepoRoot 'plugin')))
            }
        }
        Assert-Equal 'platform-guard.ps1,update-notify.ps1' ($scripts -join ',') 'SessionStart scripts'
    }

    Invoke-Case 'wiring: the POSIX guard is not wired (no sh entry, no .sh path anywhere in hooks.json)' {
        $text = [IO.File]::ReadAllText($HooksJsonPath, $Utf8NoBom)
        Assert-NotContains $text '.sh' 'hooks.json'
        Assert-NotContains $text '"bash"' 'hooks.json'
    }

    Invoke-Case 'wiring: New-HooksJson.ps1 reproduces the committed hooks.json byte for byte (line endings aside)' {
        $out = Join-Path (New-TempDir) 'hooks.json'
        $result = Invoke-NewHooksJson @('-OutputPath', $out)
        Assert-Equal 0 $result.ExitCode "exit code (output: $($result.Stdout) $($result.Stderr))"
        $generated = [IO.File]::ReadAllBytes($out)
        Assert-True (-not ($generated.Length -ge 3 -and $generated[0] -eq 0xEF -and $generated[1] -eq 0xBB -and $generated[2] -eq 0xBF)) 'no BOM'
        Assert-True ($generated -notcontains 13) 'LF line endings only'
        Assert-Equal 10 $generated[$generated.Length - 1] 'a final newline'
        $committed = [IO.File]::ReadAllText($HooksJsonPath, $Utf8NoBom).Replace("`r`n", "`n")
        Assert-Equal $committed ($Utf8NoBom.GetString($generated)) 'generated text against committed text'
    }

    Invoke-Case 'wiring: the matcher follows the allow-list of whatever classification it is given' {
        $dir = New-TempDir
        $registry = Join-Path $dir 'Registry.cs'
        [IO.File]::WriteAllText($registry, 'Register("get_a", x); Register("get_b", x); Register("set_c", x);', $Utf8NoBom)
        $classes = Join-Path $dir 'classes.json'
        [IO.File]::WriteAllText($classes, '{"allow":["get_a","get_b"],"prompt":["set_c"]}', $Utf8NoBom)
        $out = Join-Path $dir 'hooks.json'
        $result = Invoke-NewHooksJson @('-OutputPath', $out, '-ClassesPath', $classes, '-RegistryPath', $registry)
        Assert-Equal 0 $result.ExitCode "exit code (output: $($result.Stdout))"
        $config = [IO.File]::ReadAllText($out, $Utf8NoBom) | ConvertFrom-Json
        Assert-Equal ($IdentityPrefix + 'get_a|' + $IdentityPrefix + 'get_b') $config.hooks.PreToolUse[0].matcher 'matcher'
    }

    $GeneratorFaults = @(
        @{ Name = 'a wildcard in the allow-list';            Classes = '{"allow":["get_*"],"prompt":["get_a","get_b","set_c"]}'; Names = @('get_*', 'E_ALLOW_WILDCARD') }
        @{ Name = 'a registered tool in neither list';       Classes = '{"allow":["get_a"],"prompt":["set_c"]}';                 Names = @('get_b', 'E_UNCLASSIFIED') }
        @{ Name = 'an allow-list name that is not registered'; Classes = '{"allow":["get_a","get_b","get_ghost"],"prompt":["set_c"]}'; Names = @('get_ghost', 'E_ALLOW_NOT_REGISTERED') }
        @{ Name = 'a tool in both lists';                    Classes = '{"allow":["get_a","get_b"],"prompt":["get_b","set_c"]}'; Names = @('get_b', 'E_IN_BOTH_LISTS') }
    )
    foreach ($fault in $GeneratorFaults) {
        Invoke-Case "wiring: New-HooksJson.ps1 refuses $($fault.Name), names it, and writes nothing" {
            $dir = New-TempDir
            $registry = Join-Path $dir 'Registry.cs'
            [IO.File]::WriteAllText($registry, 'Register("get_a", x); Register("get_b", x); Register("set_c", x);', $Utf8NoBom)
            $classes = Join-Path $dir 'classes.json'
            [IO.File]::WriteAllText($classes, $fault.Classes, $Utf8NoBom)
            $out = Join-Path $dir 'hooks.json'
            $result = Invoke-NewHooksJson @('-OutputPath', $out, '-ClassesPath', $classes, '-RegistryPath', $registry)
            Assert-Equal 1 $result.ExitCode 'exit code'
            foreach ($name in $fault.Names) { Assert-Contains $result.Stdout $name 'failure text' }
            foreach ($label in 'What:', 'Why:', 'Fix:') { Assert-Contains $result.Stdout $label 'three-part failure' }
            Assert-True (-not (Test-Path -LiteralPath $out)) 'no hooks.json is written for an invalid classification'
        }
    }

    Invoke-Case 'wiring: New-HooksJson.ps1 fails with a three-part message for a missing classification file' {
        $out = Join-Path (New-TempDir) 'hooks.json'
        $result = Invoke-NewHooksJson @('-OutputPath', $out, '-ClassesPath', (Join-Path (New-TempDir) 'absent.json'))
        Assert-Equal 1 $result.ExitCode 'exit code'
        Assert-Contains $result.Stdout 'absent.json' 'names the file'
        Assert-Contains $result.Stdout 'Fix:' 'three-part failure'
    }

    # --- the hook commands, run from a staging copy under a path with a space and a non-ASCII letter ---
    $AwkwardSuffix = ' T' + [char]0x00E9 + 'st'
    function New-StagedPlugin {
        param([string]$Version = '1.9.0')
        $staging = New-TempDir $AwkwardSuffix
        $pluginRoot = Join-Path $staging 'plugin root'
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'plugin') -Destination $pluginRoot -Recurse
        [IO.File]::WriteAllText((Join-Path $pluginRoot '.claude-plugin\plugin.json'), ('{"name":"' + $PluginName + '","version":"' + $Version + '"}'), $Utf8NoBom)
        return $pluginRoot
    }

    Invoke-Case 'wiring: the awkward-path scenario - the PreToolUse command allows a read-only tool from a path with a space and a non-ASCII letter' {
        $pluginRoot = New-StagedPlugin
        Assert-True ($pluginRoot -match ' ') 'the staged path has a space'
        Assert-True ($pluginRoot -match [string][char]0x00E9) 'the staged path has a non-ASCII letter'
        $command = (Read-HooksJson).hooks.PreToolUse[0].hooks[0].command
        $result = Invoke-HookCommand $command $pluginRoot (ConvertTo-HookInput ($IdentityPrefix + 'get_steps'))
        Assert-Equal 0 $result.ExitCode "exit code (stderr: $($result.Stderr))"
        Assert-AllowDecision $result
        $prompting = Invoke-HookCommand $command $pluginRoot (ConvertTo-HookInput ($IdentityPrefix + 'insert_step'))
        Assert-NoDecision $prompting
    }

    Invoke-Case 'wiring: the awkward-path scenario - the platform guard command starts and adds the rules pointer' {
        $pluginRoot = New-StagedPlugin
        $fixture = New-GuardFixture
        $command = (Read-HooksJson).hooks.SessionStart[0].hooks | Where-Object { $_.command -like '*platform-guard.ps1*' } | Select-Object -First 1 -ExpandProperty command
        $guardEnv = $fixture.Env.Clone()
        $guardEnv['PATH'] = $fixture.Env['PATH'] + ';' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')   # the command itself starts `powershell`
        $result = Invoke-HookCommand $command $pluginRoot '{"source":"startup"}' $guardEnv
        Assert-Equal 0 $result.ExitCode "exit code (stderr: $($result.Stderr))"
        Assert-Equal '' $result.Stderr 'stderr'
        Assert-Contains $result.Stdout 'teststand-rules' 'stdout'
    }

    Invoke-Case 'wiring: the awkward-path scenario - the update-notify command announces a newer release' {
        $pluginRoot = New-StagedPlugin
        $server = Start-StubReleaseServer -Mode redirect -Location 'https://github.com/Zuehlke/teststand-mcp/releases/tag/v1.10.0'
        $state = Join-Path (Split-Path -Parent $pluginRoot) 'state'
        $command = (Read-HooksJson).hooks.SessionStart[0].hooks | Where-Object { $_.command -like '*update-notify.ps1*' } | Select-Object -First 1 -ExpandProperty command
        $envMap = @{ TESTSTAND_MCP_RELEASES_BASE_URL = $server.BaseUrl; TESTSTAND_MCP_STATE_DIR = $state; TESTSTAND_MCP_NOW = $FixedNow.ToString('o'); TESTSTAND_MCP_NO_UPDATE_CHECK = $null }
        $result = Invoke-HookCommand $command $pluginRoot '{"source":"startup"}' $envMap
        Assert-Equal 0 $result.ExitCode "exit code (stderr: $($result.Stderr))"
        Assert-Equal '' $result.Stderr 'stderr'
        Assert-Contains $result.Stdout '1.10.0' 'stdout'
        Assert-AsciiOnly $result.Stdout 'stdout'
    }
}
finally {
    foreach ($server in $script:StubServers) { Stop-StubReleaseServer $server }
    Remove-Module PluginIdentity -ErrorAction SilentlyContinue
    Remove-Module ToolClassification -ErrorAction SilentlyContinue
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
