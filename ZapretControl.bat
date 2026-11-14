@echo off
rem ==========================================================
rem  Zapret Control - launcher
rem  GUI / fork: Bugulmek
rem  zapret package: Flowseal (https://github.com/Flowseal/zapret-discord-youtube)
rem
rem  The PowerShell script requests administrator rights by itself.
rem  This launcher only checks the environment and reports errors:
rem  messages are ASCII so they do not depend on the console codepage.
rem ==========================================================
setlocal EnableExtensions
cd /d "%~dp0"

set "ZAPRET_PS1=%~dp0ZapretControl.ps1"
rem Absolute path: no dependency on PATH, no hijack by a rogue powershell.exe
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PS_EXE%" goto ps_missing
if not exist "%ZAPRET_PS1%" goto script_missing

rem The WPF window stays hidden, but the exit code is checked below,
rem so a startup or parse failure is no longer silent.
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%ZAPRET_PS1%"
if errorlevel 1 goto run_failed

exit /b 0

:ps_missing
echo [Zapret Control] ERROR: Windows PowerShell 5.1 was not found.
echo Expected: "%PS_EXE%"
echo Windows PowerShell is a standard Windows component. If the file is
echo missing, the system is damaged or SystemRoot points to another drive.
pause
exit /b 2

:script_missing
echo [Zapret Control] ERROR: ZapretControl.ps1 is missing next to this file.
echo Expected: "%ZAPRET_PS1%"
echo Extract the whole archive first, then run ZapretControl.bat again.
pause
exit /b 3

:run_failed
echo [Zapret Control] ERROR: Windows PowerShell exited with a non-zero code.
echo Run the script manually to see the error details:
echo   "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Sta -File "%ZAPRET_PS1%"
pause
exit /b 4
