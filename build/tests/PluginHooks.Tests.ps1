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

$HostPath = (Get-Process -Id $PID).Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$AllowReason = 'no TestStand file is modified'

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

# Runs a script under the SAME host that runs this file, with a controlled environment.
# $EnvOverrides: name -> value; a $null value REMOVES the variable from the child.
function Invoke-HookScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyString()][string]$StdinText = '',
        [hashtable]$EnvOverrides = @{}
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $HostPath
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
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
