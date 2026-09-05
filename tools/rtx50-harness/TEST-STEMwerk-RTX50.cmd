@echo off
setlocal

rem STEMwerk #118 RTX 50-series / Blackwell test harness launcher.
rem
rem Deliberately invokes "powershell.exe" (Windows PowerShell 5.1), NOT
rem "pwsh.exe" (PowerShell 7) - the harness is written to be PS 5.1-safe,
rem and this is the interpreter every plain Windows 11 machine has without
rem installing anything extra.

set "SCRIPT_DIR=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%STEMwerk-RTX50-cu128-test.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

echo.
echo Exit code: %EXITCODE%
echo Reports folder: %SCRIPT_DIR%reports
echo.
pause
exit /b %EXITCODE%
