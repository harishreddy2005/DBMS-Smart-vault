@echo off
cd /d "%~dp0"
echo Stopping SmartVault services...
taskkill /F /IM postgres.exe >nul 2>&1
taskkill /F /FI "WINDOWTITLE eq SmartVault*" >nul 2>&1
echo [OK] All SmartVault processes stopped.
timeout /t 2 >nul
