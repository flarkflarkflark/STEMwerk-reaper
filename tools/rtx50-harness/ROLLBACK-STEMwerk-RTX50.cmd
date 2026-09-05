@echo off
setlocal

rem STEMwerk #118 RTX 50-series harness: rollback launcher.
rem Deliberately invokes "powershell.exe" (Windows PowerShell 5.1).

set "SCRIPT_DIR=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%STEMwerk-RTX50-rollback.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

echo.
echo Exit code: %EXITCODE%
echo Reports folder: %SCRIPT_DIR%reports
echo.
pause
exit /b %EXITCODE%
