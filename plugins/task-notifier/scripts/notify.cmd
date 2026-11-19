@echo off
rem Task Notifier for Claude Code - Windows launcher for notify.ps1.
rem "ifpending" runs after every tool call and at session end: skip PowerShell unless a sticky toast is waiting.
if /i "%~1"=="ifpending" if not exist "%TEMP%\claude-task-notifier\*.pending" exit /b 0
rem Hooks run in the project folder, and cmd.exe would look for programs there first: a powershell.exe
rem planted in a cloned repo would run. Use the full path, and turn that lookup off for anything else.
set "NoDefaultCurrentDirectoryInExePath=1"
rem Clear PSModulePath so Windows PowerShell 5.1 does not load PowerShell 7 modules
rem inherited from the parent process (causes "AuthorizationManager check failed").
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0notify.ps1"
rem notify.ps1 always exits 0, so any other code means PowerShell could not run it. Leave a note for the doctor.
if errorlevel 1 (
  if not exist "%TEMP%\claude-task-notifier\" mkdir "%TEMP%\claude-task-notifier" 2>nul
  >"%TEMP%\claude-task-notifier\last-problem.txt" echo %DATE% %TIME% PowerShell could not run notify.ps1 ^(exit code %ERRORLEVEL%^). A company policy may block PowerShell scripts.
)
exit /b 0
