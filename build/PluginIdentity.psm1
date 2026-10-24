# ============================================================================
#  PluginIdentity.psm1 - two responsibilities that share one source of truth:
#    1. the plugin identity: name, server key and tool prefixes, READ from
#       plugin/.claude-plugin/plugin.json and plugin/.mcp.json;
#    2. agent flavour conversion: source agents (direct tool prefix, CLAUDE.md)
#       <-> plugin agents (plugin tool prefix, rules skill), driven by that identity.
#  Nothing else in the repository retypes the tool prefix.
#  Compatible with Windows PowerShell 5.1 and PowerShell 7.
#  Files are read with explicit .NET UTF-8 (no BOM added or dropped) APIs: never
#  use Get-Content / Set-Content -Encoding UTF8 here (5.1 writes a BOM).
# ============================================================================
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'BuildCommon.psm1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:DefaultPluginJsonPath = Join-Path $script:RepoRoot 'plugin\.claude-plugin\plugin.json'
$script:DefaultMcpJsonPath = Join-Path $script:RepoRoot 'plugin\.mcp.json'

# Claude Code's naming rules for MCP tools (docs/validation/claude-code-plugin-facts.md, row 12).
$script:PluginToolPrefixFormat = 'mcp__plugin_{0}_{1}__'
$script:DirectToolPrefixFormat = 'mcp__{0}__'

# ----------------------------------------------------------------------------
#  File and JSON reading (Read-Utf8Text and Get-JsonProperty come from BuildCommon.psm1)
# ----------------------------------------------------------------------------
function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    $text = Read-Utf8Text $Path
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        Write-BuildFailure -What "Invalid JSON in ${Path}: $($_.Exception.Message)" `
            -Why 'The plugin identity (name, server key, tool prefix) is read from this file, so nothing can be built without it.' `
            -Fix 'Fix the JSON syntax of the file.'
    }
}

# ----------------------------------------------------------------------------
#  Plugin identity
# ----------------------------------------------------------------------------
function Get-PluginIdentity {
    [CmdletBinding()]
    param(
        [string]$PluginJsonPath = $script:DefaultPluginJsonPath,
        [string]$McpJsonPath = $script:DefaultMcpJsonPath
    )

    $pluginName = Get-JsonProperty (Read-JsonFile $PluginJsonPath) 'name'
    if ([string]::IsNullOrWhiteSpace($pluginName)) {
        Write-BuildFailure -What "No plugin name ('name') in $PluginJsonPath" `
            -Why 'The plugin name is part of every tool prefix the agents use (mcp__plugin_<name>_<server>__).' `
            -Fix "Add a non-empty 'name' to the plugin manifest."
    }

    $servers = Get-JsonProperty (Read-JsonFile $McpJsonPath) 'mcpServers'
    if ($null -eq $servers) {
        Write-BuildFailure -What "No 'mcpServers' object in $McpJsonPath" `
            -Why 'The server key is part of every tool prefix the agents use, and it is read from this object.' `
            -Fix "Add an 'mcpServers' object with exactly one server."
    }
    $serverKeys = @($servers.PSObject.Properties | ForEach-Object { $_.Name })
    if ($serverKeys.Count -ne 1) {
        Write-BuildFailure -What "Expected exactly one MCP server in $McpJsonPath but found $($serverKeys.Count)" `
            -Why 'The tool prefix is derived from the one server key; with none or several it would be ambiguous.' `
            -Fix "Keep exactly one entry under 'mcpServers'."
    }
    $serverKey = $serverKeys[0]

    return [pscustomobject]@{
        name             = $pluginName
        serverKey        = $serverKey
        pluginToolPrefix = ($script:PluginToolPrefixFormat -f $pluginName, $serverKey)
        directToolPrefix = ($script:DirectToolPrefixFormat -f $serverKey)
    }
}

# ----------------------------------------------------------------------------
#  Agent conversion: direct flavour (committed source) <-> plugin flavour
#  (generated while staging). ONE mapping table drives both directions and is
#  applied to the WHOLE file text - frontmatter, body and code blocks alike.
# ----------------------------------------------------------------------------
$script:RulesFileReference = 'CLAUDE.md'
$script:RulesSkillName = 'teststand-rules'
$script:RulesSkillReference = "the $($script:RulesSkillName) skill"   # exact, so the round trip is byte-identical

# An optional BOM (U+FEFF) may precede the opening fence; it stays in the text untouched.
$script:FrontmatterPattern = '(?s)\A' + [regex]::Escape([string][char]0xFEFF) + '?---\r?\n(.*?)\r?\n---'
$script:ToolsLinePattern = '(?m)^tools:'

function Get-AgentMappingTable {
    param([Parameter(Mandatory)]$Identity)
    return @(
        [pscustomobject]@{ Direct = $Identity.directToolPrefix; Plugin = $Identity.pluginToolPrefix }
        [pscustomobject]@{ Direct = $script:RulesFileReference; Plugin = $script:RulesSkillReference }
    )
}

function Assert-HasToolsLine {
    param([string]$Text, [string]$Path)
    $frontmatter = [regex]::Match($Text, $script:FrontmatterPattern)
    if (-not $frontmatter.Success -or -not [regex]::IsMatch($frontmatter.Groups[1].Value, $script:ToolsLinePattern)) {
        throw "Agent has no 'tools:' line in its frontmatter: $Path"
    }
}

function Assert-ContainsNone {
    param([string]$Text, [string[]]$Terms, [string]$Path, [string]$Reason)
    foreach ($term in $Terms) {
        if ($Text.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Agent contains '$term' ($Reason): $Path"
        }
    }
}

# $Terms: objects with From (what to find) and To (what to put there).
function Convert-AgentText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Terms
    )
    # The target terms must be absent first, or the reverse conversion could not restore the source.
    Assert-ContainsNone $Text @($Terms | ForEach-Object { $_.To }) $Path 'already in the target flavour, so the conversion does not round trip'
    foreach ($term in $Terms) {
        $Text = $Text.Replace($term.From, $term.To)
    }
    # Only the exact spelling is mapped; any other case variant would survive, so refuse it.
    Assert-ContainsNone $Text @($Terms | ForEach-Object { $_.From }) $Path 'in a spelling the mapping does not cover'
    return $Text
}

function Invoke-AgentConversion {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('ToPlugin', 'FromPlugin')][string]$Direction,
        $Identity
    )
    if ($null -eq $Identity) { $Identity = Get-PluginIdentity }
    $text = Read-Utf8Text $Path
    if ($text.Length -eq 0) { throw "Agent file is empty: $Path" }

    $toPlugin = ($Direction -eq 'ToPlugin')
    if ($toPlugin) { Assert-HasToolsLine $text $Path }
    $terms = @(Get-AgentMappingTable $Identity | ForEach-Object {
        if ($toPlugin) { [pscustomobject]@{ From = $_.Direct; To = $_.Plugin } }
        else           { [pscustomobject]@{ From = $_.Plugin; To = $_.Direct } }
    })
    return Convert-AgentText -Text $text -Path $Path -Terms $terms
}

function ConvertTo-PluginAgent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, $Identity)
    return Invoke-AgentConversion -Path $Path -Direction ToPlugin -Identity $Identity
}

function ConvertFrom-PluginAgent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, $Identity)
    return Invoke-AgentConversion -Path $Path -Direction FromPlugin -Identity $Identity
}

Export-ModuleMember -Function Get-PluginIdentity, ConvertTo-PluginAgent, ConvertFrom-PluginAgent
