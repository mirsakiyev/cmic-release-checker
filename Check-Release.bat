@echo off
setlocal
if not "%~1"=="" goto commandline
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Release.ps1" -NoPause
set "checkerExit=%errorlevel%"
echo.
pause
exit /b %checkerExit%
:commandline
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Release.ps1" %*
exit /b %errorlevel%
