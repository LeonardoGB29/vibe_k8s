@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect-aws-tunnel.ps1"
if errorlevel 1 pause
