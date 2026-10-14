@echo off
powershell.exe -NoProfile -File "%~dp0tools\start-emulator.ps1"
if errorlevel 1 pause
