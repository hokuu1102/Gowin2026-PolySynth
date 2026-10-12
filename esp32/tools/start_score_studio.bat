@echo off
rem ===========================================================================
rem  FPGA2026 - Score Studio launcher
rem
rem  Why a local server: Web Bluetooth needs a SECURE CONTEXT.
rem  http://127.0.0.1 and http://localhost ARE secure contexts, file:// is not
rem  (Chrome refuses navigator.bluetooth on file://).
rem  So we serve this folder on 127.0.0.1 and open the browser there.
rem
rem  Keep this file pure ASCII (no Chinese) - .bat encoding is a known trap.
rem ===========================================================================
setlocal
cd /d "%~dp0"
set PORT=8777

echo ==========================================================
echo   FPGA2026  -  Score Studio
echo.
echo   Server : http://127.0.0.1:%PORT%/score_studio.html
echo   Stop   : close the minimized [ScoreStudioServer] window
echo ==========================================================
echo.

where python >nul 2>nul
if errorlevel 1 (
  echo [ERROR] python not found in PATH.
  pause
  exit /b 1
)

start "ScoreStudioServer" /min cmd /c "python -m http.server %PORT% --bind 127.0.0.1"
timeout /t 2 /nobreak >nul
start "" "http://127.0.0.1:%PORT%/score_studio.html"

echo Browser opened. You can close THIS window.
echo (the server keeps running in the minimized window)
pause >nul
