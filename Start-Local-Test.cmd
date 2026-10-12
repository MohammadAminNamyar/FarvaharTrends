@echo off
setlocal
powershell.exe -NoProfile -File "%~dp0tools\start-local-test.ps1"
if errorlevel 1 echo Local test startup failed. Read the message above and artifacts\local-test logs.
pause
