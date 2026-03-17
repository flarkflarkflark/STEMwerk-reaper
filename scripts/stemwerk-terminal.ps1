Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-StemwerkRepoRoot {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Set-Location -Path $repoRoot
}

function taken {
    Invoke-StemwerkRepoRoot
    if (-not (Test-Path -LiteralPath "TODO.md")) {
        Write-Error "TODO.md not found in repo root."
        return
    }
    Get-Content -LiteralPath "TODO.md"
}

function bewaar {
    Invoke-StemwerkRepoRoot
    & (Join-Path $PWD "scripts\sync-todo.ps1")
}

function ga-door {
    Invoke-StemwerkRepoRoot
    Write-Host "Pulling latest from origin/main..." -ForegroundColor Cyan
    & git pull --rebase origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git pull --rebase failed. Resolve conflicts and retry."
        return
    }
    & git status -sb
}

function stemwerk-help {
    "Available commands:";
    "  taken        - Show TODO.md (tasks)";
    "  bewaar       - Sync TODO.md (pull --rebase, commit TODO.md, push)";
    "  ga-door      - Pull latest repo changes (git pull --rebase)";
    "  stemwerk-help - This help";
}

stemwerk-help
