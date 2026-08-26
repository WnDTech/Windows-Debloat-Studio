@echo off
rem ---------------------------------------------------------------
rem  Windows Debloat Studio launcher
rem  Starts the app in a single-threaded apartment so WPF works,
rem  and lets Debloat.ps1 ask for elevation itself.
rem ---------------------------------------------------------------
setlocal
cd /d "%~dp0"
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0Debloat.ps1"
endlocal
