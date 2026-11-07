@echo off
setlocal
set "TOOL=%~dp0"
set "ROOT=%~dp0.."
start "" powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -STA -File "%TOOL%WebsiteManager.ps1" -SiteRoot "%ROOT%"
exit /b
