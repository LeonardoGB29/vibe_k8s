@echo off
setlocal
rem Uso: "Conectar VIBE AWS.cmd" [desarrollo|staging|produccion]   (por defecto desarrollo)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect-aws-tunnel.ps1" %*
if errorlevel 1 pause
