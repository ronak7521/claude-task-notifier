@echo off
rem Runs all Task Notifier tests in Windows PowerShell 5.1, the engine the plugin uses.
rem Usage: run-tests.cmd [live]   ("live" also shows and removes one real toast)
rem PSModulePath is cleared for the same reason as in notify.cmd (PowerShell 7 modules break 5.1).
setlocal
set "PSModulePath="
set "CTN_TEST_LIVE="
if /i "%~1"=="live" set "CTN_TEST_LIVE=1"
set "FAILED=0"
for %%T in (feature security) do (
  echo.
  echo ===== %%T tests =====
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0%%T-tests.ps1"
  if errorlevel 1 set "FAILED=1"
)
echo.
if "%FAILED%"=="1" (echo SOME TESTS FAILED) else (echo ALL TESTS PASSED)
exit /b %FAILED%
