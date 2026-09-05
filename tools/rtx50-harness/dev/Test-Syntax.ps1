#Requires -Version 5.1
<#
    Test-Syntax.ps1  (DEV-ONLY, excluded from tester ZIP)

    Parses every .ps1 file in the harness with the PowerShell language
    parser and reports any syntax errors, without executing anything.
    Catches issues like an unescaped "```" (triple backtick) inside a
    double-quoted string - the closing backtick escapes the string's
    terminating quote, producing a cascade of confusing downstream parse
    errors - or "$var:" inside a double-quoted string being misread as a
    scope/drive qualifier. Both have bitten this harness for real; run
    this after any edit to a .ps1 file, before running anything else.
#>
$HarnessRoot = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $HarnessRoot -Filter '*.ps1' -Recurse | Where-Object { $_.FullName -notmatch '\\reports\\' }

$hadError = $false
foreach ($file in $files) {
    $errors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $rel = $file.FullName.Substring($HarnessRoot.Length + 1)
    if ($errors.Count -gt 0) {
        $hadError = $true
        Write-Host "SYNTAX ERRORS in $rel" -ForegroundColor Red
        foreach ($e in $errors) { Write-Host "  $($e.Message) at line $($e.Extent.StartLineNumber)" -ForegroundColor Red }
    }
    else {
        Write-Host "OK: $rel" -ForegroundColor Green
    }
}
if ($hadError) { exit 1 } else { exit 0 }
