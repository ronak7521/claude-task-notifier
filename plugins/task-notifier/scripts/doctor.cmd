@echo off
rem Task Notifier for Claude Code - launcher for doctor.ps1 (/task-notifier:doctor, and "test" for /task-notifier:test).
rem Only the fixed word "test" is passed on, never other input. Same safety settings as notify.cmd.
set "NoDefaultCurrentDirectoryInExePath=1"
set "PSModulePath="
set "CTN_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="test" (
  "%CTN_PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0doctor.ps1" -TestOnly
) else (
  "%CTN_PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0doctor.ps1"
)
if %ERRORLEVEL% NEQ 0 echo [FAIL] PowerShell could not run the doctor script ^(exit code %ERRORLEVEL%^). A company policy may block PowerShell scripts.
exit /b 0
