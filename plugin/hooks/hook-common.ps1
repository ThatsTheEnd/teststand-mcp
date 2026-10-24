# ============================================================================
#  hook-common.ps1 - helpers the plugin hooks share (dot-sourced, never run alone).
#  Windows PowerShell 5.1 and PowerShell 7. Every hook is silent and non-blocking:
#  these helpers never print a diagnostic, the callers swallow every failure.
# ============================================================================

$script:MaxHookInputChars = 1048576   # hook stdin is untrusted: never buffer more than 1 MB

# The text on stdin as UTF-8, or $null when it is longer than the cap (treated as no input).
function Read-HookStdin {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    try {
        $buffer = New-Object char[] ($script:MaxHookInputChars + 1)
        $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($count -gt $script:MaxHookInputChars) { return $null }
        return (New-Object System.Text.StringBuilder).Append($buffer, 0, $count).ToString()
    } finally {
        $reader.Dispose()
    }
}

# Compact JSON in which every non-ASCII character is a \uXXXX escape, so the hook output is
# plain ASCII whatever the console code page is.
function ConvertTo-AsciiJson {
    param([Parameter(Mandatory)]$Object)
    $json = $Object | ConvertTo-Json -Compress -Depth 6
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($match) '\u{0:x4}' -f [int][char]$match.Value })
}

function Write-HookOutput {
    param([Parameter(Mandatory)]$Object)
    [Console]::Out.Write((ConvertTo-AsciiJson $Object) + "`n")
}
