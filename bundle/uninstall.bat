@echo off
REM ---------------------------------------------------------------------
REM uninstall.bat - one-click GaiaSeis uninstaller.
REM
REM Wraps uninstall.ps1 so users don't have to lower the system
REM ExecutionPolicy.  Forwards arguments through to the .ps1, so e.g.
REM     uninstall.bat -Force
REM     uninstall.bat -KeepUserData
REM still works.
REM ---------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%uninstall.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo Uninstaller exited with code %RC%.
    pause
)
endlocal & exit /b %RC%
