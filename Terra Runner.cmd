@echo off
setlocal EnableExtensions
cd /d "%~dp0"
chcp 65001 >nul
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo.
  echo Terra Runner requires PowerShell 7 or newer ^(pwsh.exe^).
  echo Install PowerShell 7, then double-click this file again.
  echo.
  pause
  exit /b 1
)
title Terra Runner 1.4
if "%~1"=="" (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0terra-ui.ps1"
) else (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0terra-runner.ps1" %*
)
set "RESULT=%ERRORLEVEL%"
echo.
if not "%TERRA_RUNNER_NO_PAUSE%"=="1" pause
exit /b %RESULT%
