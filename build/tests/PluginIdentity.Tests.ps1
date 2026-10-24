# ============================================================================
#  PluginIdentity.Tests.ps1 - plain PowerShell asserts for build/PluginIdentity.psm1
#  Runs under Windows PowerShell 5.1 and PowerShell 7:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\tests\PluginIdentity.Tests.ps1
#  Prints PASS/FAIL per case and exits non-zero when any case fails.
#  This file is ASCII only on purpose: 5.1 reads a BOM-less script as ANSI, so
#  non-ASCII characters are built from code points below.
# ============================================================================
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'build\PluginIdentity.psm1'
$marketplacePath = Join-Path $repoRoot '.claude-plugin\marketplace.json'
$pluginJsonPath = Join-Path $repoRoot 'plugin\.claude-plugin\plugin.json'
$mcpJsonPath = Join-Path $repoRoot 'plugin\.mcp.json'
$sourceAgentDir = Join-Path $repoRoot '.claude\agents'

$ExpectedToolPrefix = 'mcp__plugin_teststand-mcp_teststand__'
$DirectToolPrefix = 'mcp__teststand__'
$ExpectedArchiveUrl = 'https://github.com/Zuehlke/teststand-mcp/releases/latest/download/teststand-mcp.zip'
$PlaceholderVersion = '0.0.0'
$SourceAgentNames = @('teststand-sequence-builder', 'teststand-doc-generator', 'teststand-presentation-generator')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$UmlautU = [string][char]0x00FC   # the u-umlaut of the company name

$script:failures = 0
$script:tempDirs = @()

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS  $Name"
    } catch {
        $script:failures++
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

function Assert-Throws {
    param([scriptblock]$Body, [string]$MessagePart)
    $thrown = $null
    try { & $Body } catch { $thrown = $_.Exception.Message }
    if ($null -eq $thrown) { throw 'expected an exception but none was thrown' }
    if ($thrown -notlike "*$MessagePart*") { throw "exception message [$thrown] does not contain [$MessagePart]" }
}

function New-TempDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('PluginIdentityTests_' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $script:tempDirs += $dir
    return $dir
}

function Read-JsonFile {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path, $Utf8NoBom) | ConvertFrom-Json)
}

try {
    Import-Module $modulePath -Force

    # --- Scenario: The tool prefix is derived, not retyped --------------------
    Invoke-Case 'identity: tool prefix is derived from plugin.json and .mcp.json' {
        $identity = Get-PluginIdentity
        Assert-Equal 'teststand-mcp' $identity.name 'name'
        Assert-Equal 'teststand' $identity.serverKey 'serverKey'
        Assert-Equal $ExpectedToolPrefix $identity.toolPrefix 'toolPrefix'
        Assert-Equal $DirectToolPrefix $identity.directPrefix 'directPrefix'
    }

    Invoke-Case 'identity: a different plugin name and server key change the prefix' {
        $dir = New-TempDir
        [IO.File]::WriteAllText((Join-Path $dir 'plugin.json'), '{"name":"other-plugin"}', $Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $dir '.mcp.json'), '{"mcpServers":{"srv":{}}}', $Utf8NoBom)
        $identity = Get-PluginIdentity -PluginJsonPath (Join-Path $dir 'plugin.json') -McpJsonPath (Join-Path $dir '.mcp.json')
        Assert-Equal 'mcp__plugin_other-plugin_srv__' $identity.toolPrefix 'toolPrefix'
        Assert-Equal 'mcp__srv__' $identity.directPrefix 'directPrefix'
    }

    # --- Scenario: The marketplace points at the fixed latest URL -------------
    Invoke-Case 'marketplace: one plugin teststand-mcp with the fixed latest archive URL' {
        $marketplace = Read-JsonFile $marketplacePath
        Assert-Equal 'zuehlke-teststand' $marketplace.name 'marketplace name'
        Assert-Equal 1 @($marketplace.plugins).Count 'plugin count'
        $plugin = $marketplace.plugins[0]
        Assert-Equal 'teststand-mcp' $plugin.name 'plugin name'
        Assert-Equal 'archive' $plugin.source.source 'source kind'
        Assert-Equal $ExpectedArchiveUrl $plugin.source.url 'archive url'
    }

    Invoke-Case 'plugin.json: carries the version placeholder 0.0.0 as a literal line' {
        $text = [IO.File]::ReadAllText($pluginJsonPath, $Utf8NoBom)
        Assert-True ($text -cmatch '"version": "0\.0\.0"') 'plugin.json must contain exactly: "version": "0.0.0"'
        Assert-Equal $PlaceholderVersion (Read-JsonFile $pluginJsonPath).version 'parsed version'
    }

    Invoke-Case 'plugin.json: UTF-8 without BOM and the company name holds the real u-umlaut bytes' {
        $bytes = [IO.File]::ReadAllBytes($pluginJsonPath)
        $hasBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
        Assert-True (-not $hasBom) 'plugin.json starts with a UTF-8 BOM'
        $expectedBytes = $Utf8NoBom.GetBytes('Z' + $UmlautU + 'hlke Engineering AG')
        Assert-Equal 'C3-BC' ([BitConverter]::ToString($Utf8NoBom.GetBytes($UmlautU))) 'umlaut encoding sanity'
        $hex = [BitConverter]::ToString($bytes)
        $needle = [BitConverter]::ToString($expectedBytes)
        Assert-True ($hex.Contains($needle)) 'plugin.json does not contain the UTF-8 bytes of the company name'
        Assert-Equal ('Z' + $UmlautU + 'hlke Engineering AG') (Read-JsonFile $pluginJsonPath).author.name 'author name'
    }

    Invoke-Case 'plugin.json: optional tsenv_path userConfig of type file' {
        $entry = (Read-JsonFile $pluginJsonPath).userConfig.tsenv_path
        Assert-True ($null -ne $entry) 'userConfig.tsenv_path is missing'
        Assert-Equal 'file' $entry.type 'type'
        Assert-Equal $false $entry.required 'required'
        Assert-True ($entry.description -like '*.tsenv*') 'description must name the .tsenv file'
        Assert-True ($entry.description -like '*global*') 'description must say empty means the global environment'
    }

    Invoke-Case '.mcp.json: server command and environment route from userConfig' {
        $server = (Read-JsonFile $mcpJsonPath).mcpServers.teststand
        Assert-Equal '${CLAUDE_PLUGIN_ROOT}/bin/TestStandMCP.exe' $server.command 'command'
        Assert-Equal '${user_config.tsenv_path}' $server.env.'TESTSTAND_MCP_TestStand__EnvironmentPath' 'environment path value'
    }

    # --- Agent conversion ------------------------------------------------------
    $identity = Get-PluginIdentity
    $skillReference = 'the teststand-rules skill'

    # A fixture with CRLF endings and non-ASCII text, so "all other bytes unchanged" is checkable.
    $fixtureBody = (@(
        '---',
        'name: fixture-agent',
        'tools: Read, mcp__teststand__connect_engine, mcp__teststand__open_sequence_file',
        '---',
        ('Rules come from CLAUDE.md (Z' + $UmlautU + 'hlke).'),
        'Call mcp__teststand__connect_engine first.',
        ''
    ) -join "`r`n")
    $fixtureConverted = (@(
        '---',
        'name: fixture-agent',
        ('tools: Read, ' + $ExpectedToolPrefix + 'connect_engine, ' + $ExpectedToolPrefix + 'open_sequence_file'),
        '---',
        ('Rules come from ' + $skillReference + ' (Z' + $UmlautU + 'hlke).'),
        ('Call ' + $ExpectedToolPrefix + 'connect_engine first.'),
        ''
    ) -join "`r`n")

    function New-AgentFile {
        param([string]$Text, [string]$Name = 'fixture-agent.md')
        $path = Join-Path (New-TempDir) $Name
        [IO.File]::WriteAllText($path, $Text, $Utf8NoBom)
        return $path
    }

    function Get-ConvertedBytes {
        param([string]$Text)
        return $Utf8NoBom.GetBytes($Text)
    }

    # --- Scenario: Converting an agent ----------------------------------------
    Invoke-Case 'convert: tool names and CLAUDE.md change, every other byte is unchanged' {
        $converted = ConvertTo-PluginAgent -Path (New-AgentFile $fixtureBody)
        Assert-Equal ([BitConverter]::ToString((Get-ConvertedBytes $fixtureConverted))) ([BitConverter]::ToString((Get-ConvertedBytes $converted))) 'converted bytes'
    }

    foreach ($agentName in $SourceAgentNames) {
        $sourcePath = Join-Path $sourceAgentDir ($agentName + '.md')

        Invoke-Case "convert real agent $agentName : no direct prefix and no claude.md in any case" {
            $converted = ConvertTo-PluginAgent -Path $sourcePath
            Assert-True ($converted.IndexOf($DirectToolPrefix, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'direct tool prefix left in the converted agent'
            Assert-True ($converted.IndexOf('claude.md', [StringComparison]::OrdinalIgnoreCase) -lt 0) 'a claude.md reference is left in the converted agent'
            Assert-True ($converted.Contains($ExpectedToolPrefix)) 'plugin tool prefix is missing from the converted agent'
        }

        # --- Scenario: Round trip ----------------------------------------------
        Invoke-Case "round trip real agent $agentName : byte-identical to the source" {
            $convertedPath = New-AgentFile (ConvertTo-PluginAgent -Path $sourcePath) ($agentName + '.md')
            $roundTrip = ConvertFrom-PluginAgent -Path $convertedPath
            $sourceHex = [BitConverter]::ToString([IO.File]::ReadAllBytes($sourcePath))
            Assert-Equal $sourceHex ([BitConverter]::ToString((Get-ConvertedBytes $roundTrip))) 'round-trip bytes'
        }
    }

    Invoke-Case 'round trip fixture with CRLF and non-ASCII text is byte-identical' {
        $convertedPath = New-AgentFile (ConvertTo-PluginAgent -Path (New-AgentFile $fixtureBody))
        $roundTrip = ConvertFrom-PluginAgent -Path $convertedPath
        Assert-Equal ([BitConverter]::ToString((Get-ConvertedBytes $fixtureBody))) ([BitConverter]::ToString((Get-ConvertedBytes $roundTrip))) 'round-trip bytes'
    }

    # --- Scenario: A source agent has no tools line ----------------------------
    Invoke-Case 'convert: a source agent without a tools line fails and names the file' {
        $path = New-AgentFile "---`nname: no-tools`n---`nBody mentions mcp__teststand__connect_engine.`n" 'no-tools-agent.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'no-tools-agent.md'
    }

    Invoke-Case 'convert: a tools line outside the frontmatter does not count' {
        $path = New-AgentFile "---`nname: x`n---`ntools: Read`n" 'tools-in-body.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'tools-in-body.md'
    }

    # --- Scenario: A stray tool name survives conversion -----------------------
    Invoke-Case 'convert: a tool name inside a fenced code block is converted too' {
        $text = "---`ntools: Read`n---`n``````text`nmcp__teststand__get_loaded_sequence_files`n```````n"
        $converted = ConvertTo-PluginAgent -Path (New-AgentFile $text)
        Assert-True ($converted.IndexOf($DirectToolPrefix, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'direct prefix left inside the code block'
        Assert-True ($converted.Contains($ExpectedToolPrefix + 'get_loaded_sequence_files')) 'code block tool name was not converted'
    }

    # --- Guards that keep the mapping reversible -------------------------------
    Invoke-Case 'convert: a claude.md reference in another case fails and names the file' {
        $path = New-AgentFile "---`ntools: Read`n---`nSee claude.md.`n" 'lowercase-ref.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'lowercase-ref.md'
    }

    Invoke-Case 'convert: a source that already holds the plugin phrase fails (it would not round trip)' {
        $path = New-AgentFile "---`ntools: Read`n---`nSee $skillReference and CLAUDE.md.`n" 'ambiguous.md'
        Assert-Throws { ConvertTo-PluginAgent -Path $path } 'ambiguous.md'
    }

    Invoke-Case 'convert: a missing file fails and names the file' {
        Assert-Throws { ConvertTo-PluginAgent -Path (Join-Path (New-TempDir) 'absent.md') } 'absent.md'
    }
}
finally {
    foreach ($dir in $script:tempDirs) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($script:failures -gt 0) {
    Write-Host ''
    Write-Host "$script:failures case(s) FAILED"
    exit 1
}
Write-Host ''
Write-Host 'All cases passed'
exit 0
