@echo off
REM GaiaSeis launcher.  This batch file lives next to the GaiaSeis source
REM tree (= the directory created by install.ps1).  Double-click to open
REM the GUI; the working directory is set to the install dir so log
REM files / mseed dumps / TOML profile updates land beside the program.

setlocal
set "INSTALL_DIR=%~dp0"
set "PROJECT_DIR=%INSTALL_DIR%GaiaSeis"

if not exist "%PROJECT_DIR%\Project.toml" (
    echo Could not find Project.toml at "%PROJECT_DIR%".
    echo The install layout looks broken - re-run install.ps1.
    pause
    exit /b 1
)

REM `-t auto`  = use all CPU threads (the bridge / decoder benefit on
REM              multi-channel streams).
REM `-i`       = interactive REPL kept alive in the console window so the
REM              user can inspect state after they close the GUI window.
REM `examples\gui.jl` blocks on a close-request signal, so the REPL just
REM idles until you Ctrl-C it.
cd /d "%INSTALL_DIR%"
julia.exe -t auto --project="%PROJECT_DIR%" -i "%PROJECT_DIR%\examples\gui.jl"

endlocal
