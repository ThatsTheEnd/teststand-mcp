# ============================================================================
#  TestHarness.ps1 - the plain PowerShell test harness every build/tests/*.Tests.ps1
#  file dot-sources:   . (Join-Path $PSScriptRoot 'TestHarness.ps1')
#  It holds Invoke-Case (one PASS / FAIL line per case), the common asserts, New-TempDir
#  and the end-of-run summary + exit code. The output format is the same in every test file:
#      PASS  <name>                          FAIL  <name>
#                                                  <message>
#      (blank line)  N case(s) FAILED  |  All cases passed
#  A test file sets $script:TempDirPrefix (before its first New-TempDir) to name its temp folders.
#  Compatible with Windows PowerShell 5.1 and PowerShell 7. ASCII only (5.1 reads a BOM-less
#  script as ANSI).
# ============================================================================
$script:Failures = 0
$script:TempDirs = @()
$script:TempDirPrefix = 'Tests_'

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
    param([string]$Text, [string]$Needle, [string]$What = 'text')
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) { throw "$What does not contain [$Needle]. Text was:`n$Text" }
}

function Assert-NotContains {
    param([string]$Text, [string]$Needle, [string]$What = 'text')
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) { throw "$What unexpectedly contains [$Needle]. Text was:`n$Text" }
}

# A fresh temp folder (removed by Remove-TestTempDirs). $Suffix lets a test put a space or a
# non-ASCII letter into the path.
function New-TempDir {
    param([string]$Suffix = '')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ($script:TempDirPrefix + [Guid]::NewGuid().ToString('N') + $Suffix)
    [void](New-Item -ItemType Directory -Path $dir)
    $script:TempDirs += $dir
    return $dir
}

function Remove-TestTempDirs {
    foreach ($dir in $script:TempDirs) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Prints the summary and ends the process: exit 1 when any case failed, else 0.
function Complete-TestRun {
    if ($script:Failures -gt 0) {
        Write-Host ''
        Write-Host "$script:Failures case(s) FAILED"
        exit 1
    }
    Write-Host ''
    Write-Host 'All cases passed'
    exit 0
}
