@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 install.py %*
  goto done
)
where python >nul 2>nul
if %errorlevel%==0 (
  python install.py %*
  goto done
)
echo Error: Python 3 is required. Install it from https://www.python.org/downloads/
echo Make sure to check "Add Python to PATH" during installation.
:done
echo.
pause
