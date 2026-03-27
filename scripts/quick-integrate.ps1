# Quick Automation Script - kopieert Untitled-1 direct

Write-Host "STEMwerk i18n Integratie Automatisering" -ForegroundColor Cyan
Write-Host "======================================`n" -ForegroundColor Cyan

# Check of we in de juiste directory zitten
if (-not (Test-Path "i18n\languages.lua")) {
    Write-Error "Niet in STEMwerk directory! Navigeer eerst naar C:\Users\Administrator\STEMwerk"
    exit 1
}

Write-Host "⚠️  INSTRUCTIES:" -ForegroundColor Yellow
Write-Host "1. Open Untitled-1 in VS Code" -ForegroundColor White
Write-Host "2. Druk Ctrl+A (selecteer alles)" -ForegroundColor White
Write-Host "3. Druk Ctrl+C (kopieer)" -ForegroundColor White
Write-Host "4. Druk ENTER hier...`n" -ForegroundColor White

Read-Host "Druk ENTER wanneer Untitled-1 in clipboard zit"

$content = Get-Clipboard -Format Text

if (-not $content -or $content.Length -lt 10000) {
    Write-Error "Clipboard is leeg of te klein. Zorg dat Untitled-1 gekopieerd is (moet >10KB zijn)"
    exit 1
}

Write-Host "✓ Content gelezen: $([math]::Round($content.Length/1KB, 1)) KB" -ForegroundColor Green

# Vervang oude i18n pad met nieuwe
$content = $content -replace 'local lang_file = script_path \.\. "lang" \.\. PATH_SEP \.\. "i18n\.lua"',
                              'local lang_file = script_path .. ".." .. PATH_SEP .. ".." .. PATH_SEP .. "i18n" .. PATH_SEP .. "languages.lua"'

if ($content -match 'i18n.*languages\.lua') {
    Write-Host "✓ i18n pad aangepast naar: ../../i18n/languages.lua" -ForegroundColor Green
} else {
    Write-Host "⚠️  Kon i18n pad niet vinden - check handmatig" -ForegroundColor Yellow
}

# Maak directory
New-Item -ItemType Directory -Path "scripts\reaper" -Force | Out-Null

# Sla op
$outFile = "scripts\reaper\STEMwerk.lua"
[System.IO.File]::WriteAllText("$PWD\$outFile", $content, [System.Text.UTF8Encoding]::new($false))

Write-Host "✓ Opgeslagen: $outFile ($([math]::Round((Get-Item $outFile).Length/1KB, 1)) KB)" -ForegroundColor Green

# Git commit
Write-Host "`nCommitting..." -ForegroundColor Cyan
git add $outFile
git add i18n/ tests/i18n/ docs/dev/INTEGRATION.md

$commitMsg = "Add STEMwerk.lua with i18n integration (EN/NL/DE, 152 keys each)"
git commit -m $commitMsg

if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ Committed" -ForegroundColor Green
    
    git push
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Pushed naar GitHub`n" -ForegroundColor Green
    }
}

Write-Host ("="*60) -ForegroundColor Green
Write-Host "VOLTOOID! STEMwerk.lua is klaar met i18n support" -ForegroundColor Green  
Write-Host ("="*60) -ForegroundColor Green

Write-Host "`nTest in REAPER:" -ForegroundColor White
Write-Host "  Actions → ReaScript: Load → STEMwerk/scripts/reaper/STEMwerk.lua" -ForegroundColor Yellow

Write-Host "`nVerifieer i18n:" -ForegroundColor White  
Write-Host "  python tests\i18n\test_languages.py" -ForegroundColor Yellow
Write-Host "  Expected: 4/4 tests passed, 100% coverage`n" -ForegroundColor Gray
