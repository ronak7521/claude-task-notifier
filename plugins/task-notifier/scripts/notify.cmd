@echo off
rem Task Notifier for Claude Code - Windows launcher for notify.ps1.
rem "ifpending" runs after every tool call and at session end: skip PowerShell unless a sticky toast is waiting.
if /i "%~1"=="ifpending" if not exist "%TEMP%\claude-task-notifier\*.pending" exit /b 0
rem Clear PSModulePath so Windows PowerShell 5.1 does not load PowerShell 7 modules
rem inherited from the parent process (causes "AuthorizationManager check failed").
set "PSModulePath="
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0notify.ps1"
exit /b 0
