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
title Terra Runner 1.6
if "%~1"=="" (
  where node.exe >nul 2>nul
  if errorlevel 1 (
    echo.
    echo Node.js 20 or newer was not found. Starting the legacy PowerShell interface.
    pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0terra-ui.ps1"
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
