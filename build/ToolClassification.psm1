# ============================================================================
#  ToolClassification.psm1 - the check behind plugin/hooks/tool-classes.json:
#  every tool the server registers is on purpose either auto-allowed or prompted.
#    Get-RegisteredToolNames : the tool names, read from the Register("...") calls
#                              of src/Tools/TestStandToolRegistry.cs;
#    Read-ToolClasses        : tool-classes.json as an object;
#    Test-ToolClassification : the violations of one classification (empty = valid).
#  Compatible with Windows PowerShell 5.1 and PowerShell 7.
# ============================================================================
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1')

$script:RegisterCallPattern = 'Register\("([^"]+)"'
$script:LiteralToolNamePattern = '\A[a-z0-9_]+\z'

function Read-ToolClasses {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $text = Read-Utf8Text $Path
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        Write-BuildFailure -What "Invalid JSON in ${Path}: $($_.Exception.Message)" `
            -Why 'The auto-allow hook and the classification check both read this file, so no tool can be classified without it.' `
            -Fix 'Fix the JSON syntax of the file.'
    }
}

function Get-RegisteredToolNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistryPath)
    $text = Read-Utf8Text $RegistryPath
    $names = @([regex]::Matches($text, $script:RegisterCallPattern) | ForEach-Object { $_.Groups[1].Value })
    if ($names.Count -eq 0) {
        Write-BuildFailure -What "No Register(`"...`") call found in $RegistryPath" `
            -Why 'An empty tool list would make every classification look complete, so the check refuses it.' `
            -Fix 'Point -RegistryPath at the file that registers the MCP tools.'
    }
    return $names
}

function New-Violation {
    param([string]$Tool, [string]$Rule, [string]$Message)
    return [pscustomobject]@{ Tool = $Tool; Rule = $Rule; Message = "$Rule : $Tool - $Message" }
}

function Get-ClassList {
    param($Classes, [string]$ListName)
    $list = Get-JsonProperty $Classes $ListName
    if ($null -eq $list) { return @() }
    return @($list)
}

# Names of the properties of a JSON object (empty for a missing or non-object value).
function Get-PropertyNames {
    param($Object)
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Test-CoverageRules {
    param([string[]]$Allow, [string[]]$Prompt, [string[]]$RegisteredTools)
    foreach ($tool in $RegisteredTools) {
        $isAllowed = $Allow -ccontains $tool
        $isPrompted = $Prompt -ccontains $tool
        if (-not $isAllowed -and -not $isPrompted) {
            New-Violation $tool 'E_UNCLASSIFIED' 'is registered but is in neither the allow list nor the prompt list'
        }
        if ($isAllowed -and $isPrompted) {
            New-Violation $tool 'E_IN_BOTH_LISTS' 'is in both the allow list and the prompt list'
        }
    }
}

# Literal names only: lower-case letters, digits and underscore. Anything else (a *, ?, [], (), |,
# a space) is a pattern or a typo, and a pattern in the allow list would approve tools nobody reviewed.
function Test-AllowEntryRules {
    param([string[]]$Allow, [string[]]$RegisteredTools, $NeverAllow)
    $neverNames = Get-PropertyNames $NeverAllow
    foreach ($tool in $Allow) {
        if ($tool -cnotmatch $script:LiteralToolNamePattern) {
            New-Violation $tool 'E_ALLOW_WILDCARD' 'is not a literal tool name (a wildcard or a character outside a-z, 0-9 and _)'
        } elseif ($RegisteredTools -cnotcontains $tool) {
            New-Violation $tool 'E_ALLOW_NOT_REGISTERED' 'is in the allow list but is not a registered tool'
        }
        if ($neverNames -ccontains $tool) {
            $why = Get-JsonProperty $NeverAllow $tool
            New-Violation $tool 'E_ALLOW_NEVER' "is a named exclusion and can never be auto-allowed ($why)"
        }
    }
}

function Test-DuplicateRules {
    param([string[]]$Names, [string]$ListName)
    $seen = @{}
    foreach ($name in $Names) {
        if ($seen.ContainsKey($name)) {
            New-Violation $name 'E_DUPLICATE' "appears more than once in the $ListName list"
        }
        $seen[$name] = $true
    }
}

# An audit entry records WHY a tool sits where it does; it must agree with the lists and say why.
function Test-AuditRules {
    param($Audit, [string[]]$Allow, [string[]]$Prompt)
    foreach ($tool in (Get-PropertyNames $Audit)) {
        $entry = Get-JsonProperty $Audit $tool
        $verdict = Get-JsonProperty $entry 'verdict'
        $reason = Get-JsonProperty $entry 'reason'
        $actualList = if ($Allow -ccontains $tool) { 'allow' } elseif ($Prompt -ccontains $tool) { 'prompt' } else { 'none' }
        if ($verdict -cne $actualList) {
            New-Violation $tool 'E_AUDIT_MISMATCH' "is audited as '$verdict' but is in the '$actualList' list"
        }
        if ([string]::IsNullOrWhiteSpace($reason)) {
            New-Violation $tool 'E_AUDIT_NO_REASON' 'has an audit entry without a reason'
        }
    }
}

function Test-ToolClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Classes,
        [Parameter(Mandatory)][string[]]$RegisteredTools
    )
    $allow = Get-ClassList $Classes 'allow'
    $prompt = Get-ClassList $Classes 'prompt'
    $violations = @()
    $violations += @(Test-CoverageRules $allow $prompt $RegisteredTools)
    $violations += @(Test-AllowEntryRules $allow $RegisteredTools (Get-JsonProperty $Classes 'neverAllow'))
    $violations += @(Test-DuplicateRules $allow 'allow')
    $violations += @(Test-DuplicateRules $prompt 'prompt')
    $violations += @(Test-AuditRules (Get-JsonProperty $Classes 'audit') $allow $prompt)
    return $violations
}

Export-ModuleMember -Function Read-ToolClasses, Get-RegisteredToolNames, Test-ToolClassification
