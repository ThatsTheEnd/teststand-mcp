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

Export-ModuleMember -Function Get-PluginIdentity
