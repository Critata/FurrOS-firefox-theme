@echo off
setlocal
cd /d "%~dp0"
echo FurrOS Firefox theme installer - starting...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set EXITCODE=%ERRORLEVEL%
if not "%EXITCODE%"=="0" (
  echo.
  echo INSTALL FAILED ^(exit %EXITCODE%^).
  pause
)
exit /b %EXITCODE%
