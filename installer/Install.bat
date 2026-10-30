@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Simple LLM Usage Monitor Setup
rem Double-click entry point inside the release ZIP: runs setup\Setup-LLMUsageMonitor.ps1 from
rem this folder. Arguments are passed on (see the setup script's header).
rem No "exit /b" inside a parenthesised block: cmd /c then reports exit code 0.
if not exist "%~dp0setup\Setup-LLMUsageMonitor.ps1" goto :notextracted
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Setup-LLMUsageMonitor.ps1" %*
set "LLMUSAGE_EXIT=%ERRORLEVEL%"
if not "%~1"=="" exit /b %LLMUSAGE_EXIT%
echo.
echo Press Enter to exit.
pause >nul
exit /b %LLMUSAGE_EXIT%
:notextracted
echo Extract the whole ZIP first (right-click it, Extract All), then run Install.bat
echo from the extracted folder.
if not "%~1"=="" exit /b 9
echo.
echo Press Enter to exit.
pause >nul
exit /b 9
