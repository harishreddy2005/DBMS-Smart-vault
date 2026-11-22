@echo off
setlocal
cd /d "%~dp0"
title SmartVault - Inventory ^& Anomaly Detection

echo ========================================================
echo   SmartVault DBMS System
echo ========================================================
echo.
echo [1/3] Checking PostgreSQL database...
"%~dp0.tools\pgsql\bin\pg_isready.exe" -h 127.0.0.1 -p 5432 >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo  [OK] PostgreSQL is already running on port 5432.
) else (
    echo  [..] Starting portable PostgreSQL server...
    start "SmartVault PostgreSQL" /MIN "%~dp0.tools\pgsql\bin\postgres.exe" -D "%~dp0.local\postgres-data"
    timeout /t 2 /nobreak >nul
)

echo [2/3] Opening Web Dashboard at http://127.0.0.1:3080...
start http://127.0.0.1:3080

echo [3/3] Starting Next.js Web Application...
echo  - Demo Admin: asha@smartvault.example / VaultAdmin!2026
echo  - Demo Staff: ravi@smartvault.example / VaultStaff!2026
echo.
echo (Press Ctrl+C to stop the web server)
cd /d "%~dp0web"
call npm.cmd start
