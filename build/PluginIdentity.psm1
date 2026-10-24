# ============================================================================
#  PluginIdentity.psm1 - the plugin's name, server key and tool prefix
#  Compatible with Windows PowerShell 5.1 and PowerShell 7.
#  The identity is READ from plugin/.claude-plugin/plugin.json and
#  plugin/.mcp.json; nothing else in the repository retypes the tool prefix.
#  Files are read and written with explicit .NET UTF-8 (no BOM) APIs: never
#  use Get-Content / Set-Content -Encoding UTF8 here (5.1 writes a BOM).
# ============================================================================
Set-StrictMode -Version 2.0

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:DefaultPluginJsonPath = Join-Path $script:RepoRoot 'plugin\.claude-plugin\plugin.json'
$script:DefaultMcpJsonPath = Join-Path $script:RepoRoot 'plugin\.mcp.json'

# Claude Code's naming rules for MCP tools (docs/validation/claude-code-plugin-facts.md, row 12).
$script:PluginToolPrefixFormat = 'mcp__plugin_{0}_{1}__'
$script:DirectToolPrefixFormat = 'mcp__{0}__'

$script:StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

function Read-Utf8Text {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    # GetString keeps a BOM as U+FEFF instead of dropping it, so a re-write stays byte-identical.
    return $script:StrictUtf8.GetString([IO.File]::ReadAllBytes($Path))
}

function Get-PluginIdentity {
    [CmdletBinding()]
    param(
        [string]$PluginJsonPath = $script:DefaultPluginJsonPath,
        [string]$McpJsonPath = $script:DefaultMcpJsonPath
    )

    $pluginJson = Read-Utf8Text $PluginJsonPath | ConvertFrom-Json
    $pluginName = $pluginJson.name
    if ([string]::IsNullOrWhiteSpace($pluginName)) { throw "No plugin name in $PluginJsonPath" }

    $mcpJson = Read-Utf8Text $McpJsonPath | ConvertFrom-Json
    $serverKeys = @($mcpJson.mcpServers.PSObject.Properties.Name)
    if ($serverKeys.Count -ne 1) { throw "Expected exactly one MCP server in $McpJsonPath but found $($serverKeys.Count)" }
    $serverKey = $serverKeys[0]

    return [pscustomobject]@{
        name         = $pluginName
        serverKey    = $serverKey
        toolPrefix   = ($script:PluginToolPrefixFormat -f $pluginName, $serverKey)
        directPrefix = ($script:DirectToolPrefixFormat -f $serverKey)
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

$script:FrontmatterPattern = '(?s)\A---\r?\n(.*?)\r?\n---'
$script:ToolsLinePattern = '(?m)^tools:'

function Get-AgentMappings {
    param([Parameter(Mandatory)]$Identity)
    return @(
        [pscustomobject]@{ Direct = $Identity.directPrefix; Plugin = $Identity.toolPrefix }
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
    param([string]$Text, [string[]]$Needles, [string]$Path, [string]$Reason)
    foreach ($needle in $Needles) {
        if ($Text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Agent contains '$needle' ($Reason): $Path"
        }
    }
}

function Convert-AgentText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$FromTerms,
        [Parameter(Mandatory)][string[]]$ToTerms
    )
    # The target terms must be absent first, or the reverse conversion could not restore the source.
    Assert-ContainsNone $Text $ToTerms $Path 'already in the target flavour, so the conversion would not round trip'
    for ($index = 0; $index -lt $FromTerms.Count; $index++) {
        $Text = $Text.Replace($FromTerms[$index], $ToTerms[$index])
    }
    # Only the exact spelling is mapped; any other case variant would survive, so refuse it.
    Assert-ContainsNone $Text $FromTerms $Path 'in a spelling the mapping does not cover'
    return $Text
}

function Invoke-AgentConversion {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('ToPlugin', 'FromPlugin')][string]$Direction,
        $Identity
    )
    if ($null -eq $Identity) { $Identity = Get-PluginIdentity }
    $mappings = Get-AgentMappings $Identity
    $directTerms = @($mappings | ForEach-Object { $_.Direct })
    $pluginTerms = @($mappings | ForEach-Object { $_.Plugin })
    $text = Read-Utf8Text $Path

    if ($Direction -eq 'ToPlugin') {
        Assert-HasToolsLine $text $Path
        return Convert-AgentText -Text $text -Path $Path -FromTerms $directTerms -ToTerms $pluginTerms
    }
    return Convert-AgentText -Text $text -Path $Path -FromTerms $pluginTerms -ToTerms $directTerms
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
