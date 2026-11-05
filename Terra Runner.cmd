@echo off
setlocal EnableExtensions
cd /d "%~dp0"
chcp 65001 >nul
set "FORCE_COLOR=1"
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo.
  echo Terra Runner requires PowerShell 7 or newer ^(pwsh.exe^).
  echo Install PowerShell 7, then double-click this file again.
  echo.
  pause
  exit /b 1
)
title Terra Runner 2.3
if "%~1"=="" (
  where node.exe >nul 2>nul
  if errorlevel 1 (
    echo.
    echo Terra Runner 2.3 requires Node.js 20 or newer for the central dispatcher.
    echo Install Node.js 20+, then start Terra Runner again.
    echo.
    pause
    exit /b 1
  ) else (
    node.exe "%~dp0node-ui\index.mjs"
  )
) else (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0terra-runner.ps1" %*
)
set "RESULT=%ERRORLEVEL%"
echo.
if not "%TERRA_RUNNER_NO_PAUSE%"=="1" pause
exit /b %RESULT%
