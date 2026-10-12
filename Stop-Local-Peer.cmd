@echo off
setlocal
powershell.exe -NoProfile -File "%~dp0tools\stop-local-peer.ps1"
if errorlevel 1 echo The peer was not stopped. Read the verification error above.
pause
