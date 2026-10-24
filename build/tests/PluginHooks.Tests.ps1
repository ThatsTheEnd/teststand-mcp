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
}
finally {
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
