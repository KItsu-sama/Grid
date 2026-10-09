@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

if not exist "%~dp0Grid.ps1" (
    echo ERROR: Grid.ps1 was not found in: "%~dp0"
    pause
    exit /b 1
)

if not exist "%~dp0GridMenu.ps1" (
    echo ERROR: GridMenu.ps1 was not found in: "%~dp0"
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0GridMenu.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo Grid menu exited with code %EXIT_CODE%.
if %EXIT_CODE% neq 0 (
    pause
)

exit /b %EXIT_CODE%