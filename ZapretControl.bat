@echo off
rem Zapret Control launcher
rem GUI / fork: Bugulmek
rem zapret package: Flowseal (https://github.com/Flowseal/zapret-discord-youtube)
rem The PowerShell script requests administrator rights by itself.

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0ZapretControl.ps1"
exit /b 0
