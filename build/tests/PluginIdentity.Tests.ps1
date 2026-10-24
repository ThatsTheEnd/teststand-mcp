# ============================================================================
#  PluginIdentity.Tests.ps1 - plain PowerShell asserts for build/PluginIdentity.psm1
#  Runs under Windows PowerShell 5.1 and PowerShell 7:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\tests\PluginIdentity.Tests.ps1
#  Prints PASS/FAIL per case and exits non-zero when any case fails.
#  This file is ASCII only on purpose: 5.1 reads a BOM-less script as ANSI, so
#  non-ASCII characters are built from code points below.
# ============================================================================
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ModulePath = Join-Path $RepoRoot 'build\PluginIdentity.psm1'
$MarketplacePath = Join-Path $RepoRoot '.claude-plugin\marketplace.json'
$PluginJsonPath = Join-Path $RepoRoot 'plugin\.claude-plugin\plugin.json'
$McpJsonPath = Join-Path $RepoRoot 'plugin\.mcp.json'
$SourceAgentDir = Join-Path $RepoRoot '.claude\agents'

$ExpectedPluginToolPrefix = 'mcp__plugin_teststand-mcp_teststand__'
$DirectToolPrefix = 'mcp__teststand__'
$SkillReference = 'the teststand-rules skill'
$ExpectedArchiveUrl = 'https://github.com/Zuehlke/teststand-mcp/releases/latest/download/teststand-mcp.zip'
$PlaceholderVersion = '0.0.0'
$PluginEnvironmentVariable = 'TESTSTAND_MCP_TestStand__PluginEnvironmentPath'
$MachineEnvironmentVariable = 'TESTSTAND_MCP_TestStand__EnvironmentPath'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)
$BomChar = [string][char]0xFEFF
$UmlautU = [string][char]0x00FC   # the u-umlaut of the company name
$CompanyName = 'Z' + $UmlautU + 'hlke Engineering AG'

. (Join-Path $PSScriptRoot 'TestHarness.ps1')
$script:TempDirPrefix = 'PluginIdentityTests_'

# Passes only when the exception names the file AND states the reason.
function Assert-Throws {
    param([scriptblock]$Body, [string]$FileName, [string]$Reason)
    $thrown = $null
    try { & $Body } catch { $thrown = $_.Exception.Message }
    if ($null -eq $thrown) { throw 'expected an exception but none was thrown' }
    if ($thrown -notlike "*$FileName*") { throw "exception message [$thrown] does not name the file [$FileName]" }
    if ($thrown -notlike "*$Reason*") { throw "exception message [$thrown] does not state the reason [$Reason]" }
}

function Assert-SameBytes {
    param([byte[]]$Expected, [byte[]]$Actual, [string]$What = 'bytes')
    if ($Expected.Length -ne $Actual.Length) { throw "$What : expected $($Expected.Length) bytes but got $($Actual.Length)" }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) { throw "$What : first difference at byte $index" }
    }
}

function Get-Utf8Bytes {
    param([string]$Text)
    return , $Utf8NoBom.GetBytes($Text)
}

function Test-StartsWithBom {
    param([byte[]]$Bytes)
    return ($Bytes.Length -ge 3) -and ($Bytes[0] -eq $Utf8Bom[0]) -and ($Bytes[1] -eq $Utf8Bom[1]) -and ($Bytes[2] -eq $Utf8Bom[2])
}

function Read-JsonFile {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path, $Utf8NoBom) | ConvertFrom-Json)
}

function New-AgentFile {
    param([string]$Text, [string]$Name = 'fixture-agent.md')
    $path = Join-Path (New-TempDir) $Name
    [IO.File]::WriteAllText($path, $Text, $Utf8NoBom)
    return $path
}

# Writes a plugin.json / .mcp.json pair; returns the two paths for Get-PluginIdentity.
function New-IdentityFiles {
    param([string]$PluginJson, [string]$McpJson)
    $dir = New-TempDir
    [IO.File]::WriteAllText((Join-Path $dir 'plugin.json'), $PluginJson, $Utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $dir '.mcp.json'), $McpJson, $Utf8NoBom)
    return @{ PluginJsonPath = (Join-Path $dir 'plugin.json'); McpJsonPath = (Join-Path $dir '.mcp.json') }
}

try {
    Import-Module $ModulePath -Force

    # --- Scenario: The tool prefix is derived, not retyped --------------------
    Invoke-Case 'identity: tool prefix is derived from plugin.json and .mcp.json' {
        $identity = Get-PluginIdentity
        Assert-Equal 'teststand-mcp' $identity.name 'name'
        Assert-Equal 'teststand' $identity.serverKey 'serverKey'
        Assert-Equal $ExpectedPluginToolPrefix $identity.pluginToolPrefix 'pluginToolPrefix'
        Assert-Equal $DirectToolPrefix $identity.directToolPrefix 'directToolPrefix'
    }

    Invoke-Case 'identity: a different plugin name and server key change the prefix' {
        $files = New-IdentityFiles '{"name":"other-plugin"}' '{"mcpServers":{"srv":{}}}'
        $identity = Get-PluginIdentity @files
        Assert-Equal 'mcp__plugin_other-plugin_srv__' $identity.pluginToolPrefix 'pluginToolPrefix'
        Assert-Equal 'mcp__srv__' $identity.directToolPrefix 'directToolPrefix'
    }

    Invoke-Case 'identity: plugin.json without a name fails naming the file' {
        $files = New-IdentityFiles '{"version":"1.0.0"}' '{"mcpServers":{"srv":{}}}'
        Assert-Throws { Get-PluginIdentity @files } 'plugin.json' 'No plugin name'
    }

    Invoke-Case 'identity: .mcp.json without mcpServers fails naming the file' {
        $files = New-IdentityFiles '{"name":"p"}' '{}'
        Assert-Throws { Get-PluginIdentity @files } '.mcp.json' "No 'mcpServers'"
    }

    Invoke-Case 'identity: .mcp.json with no server fails naming the file' {
        $files = New-IdentityFiles '{"name":"p"}' '{"mcpServers":{}}'
        Assert-Throws { Get-PluginIdentity @files } '.mcp.json' 'exactly one MCP server'
    }

    Invoke-Case 'identity: .mcp.json with two servers fails naming the file' {
        $files = New-IdentityFiles '{"name":"p"}' '{"mcpServers":{"a":{},"b":{}}}'
        Assert-Throws { Get-PluginIdentity @files } '.mcp.json' 'exactly one MCP server'
    }

    Invoke-Case 'identity: a missing file fails naming the file' {
        $files = New-IdentityFiles '{"name":"p"}' '{"mcpServers":{"srv":{}}}'
        $files.McpJsonPath = Join-Path (New-TempDir) 'absent.mcp.json'
        Assert-Throws { Get-PluginIdentity @files } 'absent.mcp.json' 'File not found'
    }

    # Configuration errors are build failures with the three parts: What / Why / Fix.
    Invoke-Case 'identity: every configuration error carries a What, a Why and a Fix' {
        $absent = Join-Path (New-TempDir) 'absent.json'
        $cases = @{
            'no plugin name'      = (New-IdentityFiles '{"version":"1.0.0"}' '{"mcpServers":{"srv":{}}}')
            'no mcpServers'       = (New-IdentityFiles '{"name":"p"}' '{}')
            'two servers'         = (New-IdentityFiles '{"name":"p"}' '{"mcpServers":{"a":{},"b":{}}}')
            'invalid JSON'        = (New-IdentityFiles '{ not json' '{"mcpServers":{"srv":{}}}')
            'missing file'        = @{ PluginJsonPath = $absent; McpJsonPath = $absent }
        }
        foreach ($name in $cases.Keys) {
            $files = $cases[$name]
            $message = $null
            try { [void](Get-PluginIdentity @files) } catch { $message = $_.Exception.Message }
            Assert-True ($null -ne $message) "$name : expected a failure"
            foreach ($label in @('What', 'Why', 'Fix')) {
                Assert-True ($message -cmatch "(?m)^${label}: +\S") "$name : no '${label}:' line with content. Message was:`n$message"
            }
        }
    }

    # --- Scenario: The marketplace points at the fixed latest URL -------------
    Invoke-Case 'marketplace: one plugin teststand-mcp with the fixed latest archive URL' {
        $marketplace = Read-JsonFile $MarketplacePath
        Assert-Equal 'zuehlke-teststand' $marketplace.name 'marketplace name'
        Assert-Equal 1 @($marketplace.plugins).Count 'plugin count'
        $plugin = $marketplace.plugins[0]
        Assert-Equal 'teststand-mcp' $plugin.name 'plugin name'
        Assert-Equal 'archive' $plugin.source.source 'source kind'
        Assert-Equal $ExpectedArchiveUrl $plugin.source.url 'archive url'
    }

    Invoke-Case 'marketplace: the plugin name equals the identity read from plugin.json' {
        Assert-Equal (Get-PluginIdentity).name (Read-JsonFile $MarketplacePath).plugins[0].name 'marketplace plugin name'
    }

    Invoke-Case 'marketplace and plugin.json repeat the same descriptive fields' {
        $entry = (Read-JsonFile $MarketplacePath).plugins[0]
        $manifest = Read-JsonFile $PluginJsonPath
        Assert-Equal $manifest.description $entry.description 'description'
        Assert-Equal $manifest.author.name $entry.author.name 'author.name'
        Assert-Equal $manifest.homepage $entry.homepage 'homepage'
        Assert-Equal $manifest.repository $entry.repository 'repository'
        Assert-Equal $manifest.license $entry.license 'license'
        Assert-Equal ($manifest.keywords -join ',') ($entry.keywords -join ',') 'keywords'
    }

    Invoke-Case 'plugin.json: carries the version placeholder 0.0.0 as a literal line' {
        $text = [IO.File]::ReadAllText($PluginJsonPath, $Utf8NoBom)
        Assert-True ($text -cmatch '"version": "0\.0\.0"') 'plugin.json must contain exactly: "version": "0.0.0"'
        Assert-Equal $PlaceholderVersion (Read-JsonFile $PluginJsonPath).version 'parsed version'
    }

    foreach ($manifestPath in @($PluginJsonPath, $MarketplacePath, $McpJsonPath)) {
        Invoke-Case ('manifest: ' + (Split-Path -Leaf $manifestPath) + ' is UTF-8 without a BOM') {
            Assert-True (-not (Test-StartsWithBom ([IO.File]::ReadAllBytes($manifestPath)))) "$manifestPath starts with a UTF-8 BOM"
        }
    }

    Invoke-Case 'plugin.json: the company name holds the real UTF-8 bytes of the u-umlaut' {
        $bytes = [IO.File]::ReadAllBytes($PluginJsonPath)
        Assert-Equal 'C3-BC' ([BitConverter]::ToString((Get-Utf8Bytes $UmlautU))) 'umlaut encoding sanity'
        $hex = [BitConverter]::ToString($bytes)
        Assert-True ($hex.Contains([BitConverter]::ToString((Get-Utf8Bytes $CompanyName)))) 'plugin.json does not contain the UTF-8 bytes of the company name'
        Assert-Equal $CompanyName (Read-JsonFile $PluginJsonPath).author.name 'author name'
    }

    Invoke-Case 'plugin.json: optional tsenv_path userConfig of type file' {
        $entry = (Read-JsonFile $PluginJsonPath).userConfig.tsenv_path
        Assert-True ($null -ne $entry) 'userConfig.tsenv_path is missing'
        Assert-Equal 'file' $entry.type 'type'
        Assert-Equal $false $entry.required 'required'
        Assert-True ($entry.description -like '*.tsenv*') 'description must name the .tsenv file'
        Assert-True ($entry.description -like '*global*') 'description must say empty means the global environment'
    }

    Invoke-Case '.mcp.json: server command is the bundled exe under the plugin root' {
        Assert-Equal '${CLAUDE_PLUGIN_ROOT}/bin/TestStandMCP.exe' (Read-JsonFile $McpJsonPath).mcpServers.teststand.command 'command'
    }

    Invoke-Case '.mcp.json: the userConfig value travels under its own key, never the machine-wide one' {
        $env = (Read-JsonFile $McpJsonPath).mcpServers.teststand.env
        Assert-Equal '${user_config.tsenv_path}' $env.$PluginEnvironmentVariable 'plugin environment value'
        Assert-True ($null -eq $env.PSObject.Properties[$MachineEnvironmentVariable]) "$MachineEnvironmentVariable must not be written: an empty plugin value would mask a machine-wide setting"
    }

    Invoke-Case '.mcp.json: every ${user_config.KEY} it uses is declared in plugin.json userConfig' {
        $text = [IO.File]::ReadAllText($McpJsonPath, $Utf8NoBom)
        $declared = @((Read-JsonFile $PluginJsonPath).userConfig.PSObject.Properties | ForEach-Object { $_.Name })
        $used = @([regex]::Matches($text, '\$\{user_config\.([A-Za-z0-9_]+)\}') | ForEach-Object { $_.Groups[1].Value })
        Assert-True ($used.Count -gt 0) '.mcp.json uses no ${user_config.KEY} at all'
        foreach ($key in $used) { Assert-True ($declared -ccontains $key) "userConfig key '$key' is used in .mcp.json but not declared in plugin.json" }
    }

    # --- Agent conversion ------------------------------------------------------
    # A fixture with CRLF endings and non-ASCII text, so "all other bytes unchanged" is checkable.
    $FixtureSource = (@(
        '---',
        'name: fixture-agent',
        'tools: Read, mcp__teststand__connect_engine, mcp__teststand__open_sequence_file',
        '---',
        ('Rules come from CLAUDE.md (Z' + $UmlautU + 'hlke).'),
        'Call mcp__teststand__connect_engine first.',
        ''
    ) -join "`r`n")
    $FixtureConverted = (@(
        '---',
        'name: fixture-agent',
        ('tools: Read, ' + $ExpectedPluginToolPrefix + 'connect_engine, ' + $ExpectedPluginToolPrefix + 'open_sequence_file'),
        '---',
        ('Rules come from ' + $SkillReference + ' (Z' + $UmlautU + 'hlke).'),
        ('Call ' + $ExpectedPluginToolPrefix + 'connect_engine first.'),
        ''
    ) -join "`r`n")

    # --- Scenario: Converting an agent ----------------------------------------
    Invoke-Case 'convert: tool names and CLAUDE.md change, every other byte is unchanged' {
        $converted = ConvertTo-PluginAgent -Path (New-AgentFile $FixtureSource)
        Assert-SameBytes (Get-Utf8Bytes $FixtureConverted) (Get-Utf8Bytes $converted) 'converted bytes'
    }

    $sourceAgents = @(Get-ChildItem -LiteralPath $SourceAgentDir -Filter '*.md')
    Invoke-Case 'real agents: at least one source agent is found to convert' {
        Assert-True ($sourceAgents.Count -gt 0) "no *.md agent found in $SourceAgentDir"
    }

    foreach ($sourceAgent in $sourceAgents) {
        $agentName = $sourceAgent.BaseName

        Invoke-Case "convert real agent $agentName : no direct prefix and no claude.md in any case" {
            $converted = ConvertTo-PluginAgent -Path $sourceAgent.FullName
            Assert-True ($converted.IndexOf($DirectToolPrefix, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'direct tool prefix left in the converted agent'
            Assert-True ($converted.IndexOf('claude.md', [StringComparison]::OrdinalIgnoreCase) -lt 0) 'a claude.md reference is left in the converted agent'
            Assert-True ($converted.Contains($ExpectedPluginToolPrefix)) 'plugin tool prefix is missing from the converted agent'
        }

        # --- Scenario: Round trip ----------------------------------------------
        Invoke-Case "round trip real agent $agentName : byte-identical to the source" {
            $convertedPath = New-AgentFile (ConvertTo-PluginAgent -Path $sourceAgent.FullName) $sourceAgent.Name
            $roundTrip = ConvertFrom-PluginAgent -Path $convertedPath
            Assert-SameBytes ([IO.File]::ReadAllBytes($sourceAgent.FullName)) (Get-Utf8Bytes $roundTrip) 'round-trip bytes'
        }
    }

    Invoke-Case 'round trip fixture with CRLF and non-ASCII text is byte-identical' {
        $convertedPath = New-AgentFile (ConvertTo-PluginAgent -Path (New-AgentFile $FixtureSource))
        Assert-SameBytes (Get-Utf8Bytes $FixtureSource) (Get-Utf8Bytes (ConvertFrom-PluginAgent -Path $convertedPath)) 'round-trip bytes'
    }

    Invoke-Case 'round trip fixture with a leading BOM keeps the BOM and is byte-identical' {
        $bomSource = $BomChar + $FixtureSource
        $converted = ConvertTo-PluginAgent -Path (New-AgentFile $bomSource)
        Assert-True ($converted.StartsWith($BomChar)) 'the BOM was dropped by the conversion'
        $roundTrip = ConvertFrom-PluginAgent -Path (New-AgentFile $converted)
        Assert-SameBytes (Get-Utf8Bytes $bomSource) (Get-Utf8Bytes $roundTrip) 'round-trip bytes'
    }

    # --- Scenario: A source agent has no tools line ----------------------------
    Invoke-Case 'convert: a source agent without a tools line fails and names the file' {
        $path = New-AgentFile "---`nname: no-tools`n---`nBody mentions mcp__teststand__connect_engine.`n" 'no-tools-agent.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'no-tools-agent.md' "'tools:' line"
    }

    Invoke-Case 'convert: a tools line outside the frontmatter does not count' {
        $path = New-AgentFile "---`nname: x`n---`ntools: Read`n" 'tools-in-body.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'tools-in-body.md' "'tools:' line"
    }

    # --- Scenario: A stray tool name survives conversion -----------------------
    Invoke-Case 'convert: a tool name inside a fenced code block is converted too' {
        $text = "---`ntools: Read`n---`n``````text`nmcp__teststand__get_loaded_sequence_files`n```````n"
        $converted = ConvertTo-PluginAgent -Path (New-AgentFile $text)
        Assert-True ($converted.IndexOf($DirectToolPrefix, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'direct prefix left inside the code block'
        Assert-True ($converted.Contains($ExpectedPluginToolPrefix + 'get_loaded_sequence_files')) 'code block tool name was not converted'
    }

    # --- Guards that keep the mapping reversible, forward direction ------------
    Invoke-Case 'convert: a claude.md reference in another case fails and names the file' {
        $path = New-AgentFile "---`ntools: Read`n---`nSee claude.md.`n" 'lowercase-ref.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'lowercase-ref.md' 'spelling the mapping does not cover'
    }

    Invoke-Case 'convert: a direct tool prefix in another case fails and names the file' {
        $path = New-AgentFile "---`ntools: Read`n---`nCall MCP__TESTSTAND__x.`n" 'uppercase-prefix.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'uppercase-prefix.md' 'spelling the mapping does not cover'
    }

    Invoke-Case 'convert: a source that already holds the plugin phrase fails (it would not round trip)' {
        $path = New-AgentFile "---`ntools: Read`n---`nSee $SkillReference and CLAUDE.md.`n" 'ambiguous.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'ambiguous.md' 'does not round trip'
    }

    Invoke-Case 'convert: a missing file fails and names the file' {
        Assert-Throws { ConvertTo-PluginAgent -Path (Join-Path (New-TempDir) 'absent.md') } 'absent.md' 'File not found'
    }

    # --- Guards, reverse direction ---------------------------------------------
    Invoke-Case 'reverse: a plugin agent that still contains CLAUDE.md fails and names the file' {
        $path = New-AgentFile "---`ntools: Read`n---`nSee CLAUDE.md and $SkillReference.`n" 'mixed-rules.md'
        Assert-Throws { ConvertFrom-PluginAgent -Path $path } 'mixed-rules.md' 'does not round trip'
    }

    Invoke-Case 'reverse: a plugin agent that still contains the direct prefix fails and names the file' {
        $path = New-AgentFile "---`ntools: Read`n---`nCall ${DirectToolPrefix}x and ${ExpectedPluginToolPrefix}y.`n" 'mixed-prefix.md'
        Assert-Throws { ConvertFrom-PluginAgent -Path $path } 'mixed-prefix.md' 'does not round trip'
    }

    Invoke-Case 'reverse: a case variant of the skill phrase fails and names the file' {
        $path = New-AgentFile "---`ntools: Read`n---`nSee The Teststand-Rules Skill.`n" 'skill-case.md'
        Assert-Throws { ConvertFrom-PluginAgent -Path $path } 'skill-case.md' 'spelling the mapping does not cover'
    }

    Invoke-Case 'reverse: an empty agent file fails and names the file' {
        $path = New-AgentFile '' 'empty-agent.md'
        Assert-Throws { ConvertFrom-PluginAgent -Path $path } 'empty-agent.md' 'empty'
    }

    Invoke-Case 'convert: an empty agent file fails and names the file' {
        $path = New-AgentFile '' 'empty-source.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'empty-source.md' 'empty'
    }
}
finally {
    Remove-Module PluginIdentity -ErrorAction SilentlyContinue
    Remove-TestTempDirs
}

Complete-TestRun
