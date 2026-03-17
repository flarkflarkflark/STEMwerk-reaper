Param(
    [string]$Remote = "origin",
    [string]$Branch = "main",
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

Set-Location -Path (Split-Path -Parent $PSScriptRoot)  # repo root (scripts/..)

# Ensure we're in a git repo
& git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { Fail "Not a git repository." }

# Don’t accidentally sync/push unrelated changes
$porcelain = & git status --porcelain
if ($porcelain) {
    $other = $porcelain | Where-Object { $_ -notmatch '(^\s*M\s+TODO\.md$)|(^\?\?\s+TODO\.md$)' }
    if ($other) {
        Fail "Working tree has other changes besides TODO.md. Commit/stash those first before syncing TODO.md.\n\n$($other -join "`n")"
    }
}

Write-Host "Pulling latest $Remote/$Branch..." -ForegroundColor Cyan
& git pull --rebase $Remote $Branch
if ($LASTEXITCODE -ne 0) { Fail "git pull --rebase failed. Resolve conflicts and retry." }

if (-not (Test-Path -LiteralPath "TODO.md")) {
    Fail "TODO.md not found in repo root."
}

& git add -- "TODO.md"

# If nothing staged, we're already synced
& git diff --cached --quiet -- TODO.md
if ($LASTEXITCODE -eq 0) {
    Write-Host "TODO.md is already up to date (nothing to commit)." -ForegroundColor Green
    if (-not $NoPush) {
        Write-Host "Pushing (no changes) just to verify remote access..." -ForegroundColor Cyan
        & git push $Remote $Branch
    }
    exit 0
}

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
$msg = "chore(todo): sync ($timestamp)"
Write-Host "Committing TODO.md: $msg" -ForegroundColor Cyan
& git commit -m $msg -- "TODO.md"
if ($LASTEXITCODE -ne 0) { Fail "git commit failed." }

if ($NoPush) {
    Write-Host "Committed locally (NoPush set)." -ForegroundColor Yellow
    exit 0
}

Write-Host "Pushing to $Remote/$Branch..." -ForegroundColor Cyan
& git push $Remote $Branch
if ($LASTEXITCODE -ne 0) { Fail "git push failed." }

Write-Host "✅ TODO.md synced to GitHub." -ForegroundColor Green
