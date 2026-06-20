@echo off
setlocal EnableDelayedExpansion
title IDE Claw - Cascade Setup

echo.
echo ================================================================
echo                IDE Claw - Cascade Setup
echo ================================================================
echo.
echo  This script will:
echo    1. Detect if Python is installed
echo    2. Install Python 3.12 via winget if missing
echo    3. Install pip dependencies for dialog.py
echo       (requests, websocket-client)
echo.
echo  Who needs this?
echo    [Y] You want Cascade (Windsurf AI) to push messages to phone/desktop
echo    [N] You only want to receive messages on the desktop app -
echo        just double-click ide_claw.exe directly, no setup needed
echo.
echo ================================================================
echo.
pause
echo.

REM ----------------------------------------------------------------
REM  1. Detect Python
REM ----------------------------------------------------------------
echo [1/3] Detecting Python...
set "PY_CMD="

python --version > nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=python"
    for /f "tokens=*" %%i in ('python --version 2^>^&1') do set "PY_VER=%%i"
    echo       [OK] Found: !PY_VER!
    goto INSTALL_DEPS
)

py -3 --version > nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=py -3"
    for /f "tokens=*" %%i in ('py -3 --version 2^>^&1') do set "PY_VER=%%i"
    echo       [OK] Found: !PY_VER! ^(via py launcher^)
    goto INSTALL_DEPS
)

echo       [.] Python not found, attempting auto-install...

REM ----------------------------------------------------------------
REM  2. Install Python via winget
REM ----------------------------------------------------------------
echo.
echo [2/3] Installing Python 3.12 via winget...
where winget > nul 2>&1
if errorlevel 1 (
    echo.
    echo       [ERROR] winget is not available on your system.
    echo.
    echo       Please install Python manually:
    echo         1. Open https://www.python.org/downloads/
    echo         2. Download Python 3.10+ Windows installer
    echo         3. During install, check "Add Python to PATH"
    echo         4. After install, double-click this script again
    echo.
    pause
    exit /b 1
)

echo       [.] A UAC prompt may appear, please click "Yes"
echo.
winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent
if errorlevel 1 (
    echo.
    echo       [ERROR] winget install failed.
    echo       You can install Python manually from https://www.python.org/
    echo.
    pause
    exit /b 1
)

echo.
echo       [OK] Python installed.
echo.
echo ================================================================
echo  Please CLOSE this window and double-click setup-cascade.bat
echo  again to install pip dependencies.
echo  (Windows does not refresh PATH for the current shell -
echo   you need to reopen the script.)
echo ================================================================
echo.
pause
exit /b 0

REM ----------------------------------------------------------------
REM  3. Install pip dependencies
REM ----------------------------------------------------------------
:INSTALL_DEPS
echo.
echo [2/3] Upgrading pip...
%PY_CMD% -m pip install --upgrade pip --quiet
if errorlevel 1 (
    echo       [WARN] pip upgrade failed, continuing...
) else (
    echo       [OK] pip upgraded
)

echo.
echo [3/3] Installing dialog.py dependencies...

set "REQ_FILE=%~dp0cascade-requirements.txt"
if exist "%REQ_FILE%" (
    echo       Installing from %REQ_FILE%
    %PY_CMD% -m pip install -r "%REQ_FILE%"
) else (
    echo       cascade-requirements.txt not found, using built-in list
    %PY_CMD% -m pip install requests websocket-client
)

if errorlevel 1 (
    echo.
    echo       [ERROR] dependency install failed
    echo       Check your network. For users in China, try:
    echo         %PY_CMD% -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple requests websocket-client
    echo.
    pause
    exit /b 1
)

echo.
echo ================================================================
echo                    [OK] All dependencies ready!
echo ================================================================
echo.
echo  Next steps:
echo    1. dialog.py is at <project_root>\cascade\dialog.py
echo    2. If you only downloaded the desktop zip without source,
echo       grab the full project at https://push.shoot-game.cn/
echo       or prepare dialog.py yourself
echo    3. Configure dialog.py path in your Cascade .windsurfrules
echo.
echo  Double-click ide_claw.exe to launch the desktop app.
echo  Messages from dialog.py arrive via local IPC (127.0.0.1:13800)
echo  in milliseconds.
echo.
pause
exit /b 0
