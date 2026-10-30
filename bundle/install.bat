@echo off
REM ---------------------------------------------------------------------
REM install.bat - one-click GaiaSeis installer.
REM
REM Wraps install.ps1 so users don't have to fight Windows PowerShell's
REM default "Restricted" execution policy.  `-ExecutionPolicy Bypass`
REM applies ONLY to this single invocation; it does not change any
REM system or user setting.
REM
REM Forwards every argument verbatim to install.ps1, so:
REM     install.bat -NoShortcuts
REM     install.bat -InstallDir D:\Apps\GaiaSeis
REM still works.
REM ---------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%install.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo Installer exited with code %RC%.
    pause
)
endlocal & exit /b %RC%
