@echo off
rem Task Notifier for Claude Code - Windows launcher for notify.ps1.
rem Clear PSModulePath so Windows PowerShell 5.1 does not load PowerShell 7 modules
rem inherited from the parent process (causes "AuthorizationManager check failed").
set "PSModulePath="
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0notify.ps1"
exit /b 0
