@echo off
setlocal
set "checkerInteractive="
if "%~1"=="" set "checkerInteractive=-NoPause"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Release.ps1" %checkerInteractive% %*
set "checkerExit=%errorlevel%"
if "%~1"=="" pause
exit /b %checkerExit%
