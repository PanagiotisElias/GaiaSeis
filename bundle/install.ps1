# GaiaSeis installer (Windows / PowerShell).
#
# Copies the bundled source tree to %LOCALAPPDATA%\GaiaSeis, resolves +
# precompiles every Julia dependency, then drops a Start-Menu and
# Desktop shortcut that launches the GUI in one click.
#
# Run from the unzipped bundle root, e.g.:
#   .\install.ps1                  # default install
#   .\install.ps1 -NoShortcuts     # skip Start-Menu / Desktop shortcuts
#   .\install.ps1 -InstallDir D:\Apps\GaiaSeis
#
# Re-running the installer is safe - it overwrites the previous copy and
# re-precompiles.  Use uninstall.ps1 to remove everything.

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "GaiaSeis"),
    [switch]$NoShortcuts,
    [switch]$NoPrecompile
)

$ErrorActionPreference = "Stop"
$bundleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Done ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# ---- 1. Locate julia -----------------------------------------------------
Write-Step "Looking for Julia (>= 1.10) on PATH"
$julia = Get-Command julia -ErrorAction SilentlyContinue
if ($null -eq $julia) {
    Write-Host ""
    Write-Host "Julia was not found on PATH." -ForegroundColor Red
    Write-Host "Install it via juliaup (recommended):" -ForegroundColor Red
    Write-Host "    winget install --id JuliaLang.Juliaup -e" -ForegroundColor Red
    Write-Host "or download from https://julialang.org/downloads/ and re-run this installer."
    exit 1
}
$juliaExe = $julia.Source
Write-Done "Found $juliaExe"

# Quick version sanity check
$verLine = & $juliaExe -e 'print(string(VERSION))'
$ver = [Version]$verLine
if ($ver.Major -lt 1 -or ($ver.Major -eq 1 -and $ver.Minor -lt 10)) {
    Write-Host "Julia $ver is too old. Please install Julia >= 1.10." -ForegroundColor Red
    exit 1
}
Write-Done "Julia version $ver"

# ---- 2. Copy source into the install location ----------------------------
Write-Step "Installing to $InstallDir"
if (Test-Path $InstallDir) {
    Write-Warn2 "Existing install found - replacing"
    # Preserve user-generated runtime data if present
    foreach ($keep in @("logs", "mseed", "mseed2", "ntrip_profiles.toml")) {
        $src = Join-Path $InstallDir $keep
        if (Test-Path $src) {
            $backup = "$InstallDir.$keep.bak"
            if (Test-Path $backup) { Remove-Item -Recurse -Force $backup }
            Move-Item -Path $src -Destination $backup
            Write-Warn2 "Preserved existing '$keep' as '$backup'"
        }
    }
    Remove-Item -Recurse -Force $InstallDir
}
New-Item -ItemType Directory -Path $InstallDir | Out-Null

# The bundle contains two top-level dirs: GaiaSeis\ and PPPH_VA\PPPHVA.jl\
foreach ($d in @("GaiaSeis", "PPPH_VA")) {
    $srcDir = Join-Path $bundleRoot $d
    if (-not (Test-Path $srcDir)) {
        Write-Host "Bundle is missing '$d' - is install.ps1 next to GaiaSeis\ ?" -ForegroundColor Red
        exit 1
    }
    Copy-Item -Recurse -Force -Path $srcDir -Destination $InstallDir
}
Copy-Item -Path (Join-Path $bundleRoot "launch.bat")          -Destination $InstallDir
Copy-Item -Path (Join-Path $bundleRoot "uninstall.ps1")       -Destination $InstallDir
# uninstall.bat is the double-clickable wrapper around uninstall.ps1
# (bypasses Windows PowerShell's "Restricted" ExecutionPolicy). Skip
# silently if the bundle predates the .bat wrappers.
$uninstBat = Join-Path $bundleRoot "uninstall.bat"
if (Test-Path $uninstBat) {
    Copy-Item -Path $uninstBat -Destination $InstallDir
}
Copy-Item -Path (Join-Path $bundleRoot "README_INSTALL.md")   -Destination $InstallDir

# Restore preserved runtime data into the new copy
foreach ($keep in @("logs", "mseed", "mseed2", "ntrip_profiles.toml")) {
    $backup = "$InstallDir.$keep.bak"
    $target = Join-Path (Join-Path $InstallDir "GaiaSeis") $keep
    if (Test-Path $backup) {
        Move-Item -Path $backup -Destination $target
        Write-Done "Restored '$keep' from previous install"
    }
}
Write-Done "Source copied"

# ---- 3. Resolve + precompile dependencies --------------------------------
$projDir = Join-Path $InstallDir "GaiaSeis"
if ($NoPrecompile) {
    Write-Warn2 "Skipping precompile (re-run with no -NoPrecompile to populate the cache)"
} else {
    Write-Step "Resolving + precompiling Julia packages (this can take 5-10 min on first install)"
    & $juliaExe --project="$projDir" -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Pkg.instantiate / Pkg.precompile failed (see output above)." -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Done "Packages ready"
}

# ---- 4. Shortcuts --------------------------------------------------------
if (-not $NoShortcuts) {
    Write-Step "Creating Start-Menu + Desktop shortcuts"
    $launchBat = Join-Path $InstallDir "launch.bat"
    $iconPath  = Join-Path $projDir "docs\assets\icons\gaiaseis.ico"
    if (-not (Test-Path $iconPath)) { $iconPath = $launchBat }   # fallback

    $WSh = New-Object -ComObject WScript.Shell
    $startDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
    foreach ($where in @($startDir, [Environment]::GetFolderPath("Desktop"))) {
        if (-not (Test-Path $where)) { continue }
        $lnkPath = Join-Path $where "GaiaSeis.lnk"
        $lnk = $WSh.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $launchBat
        $lnk.WorkingDirectory = $InstallDir
        $lnk.IconLocation     = $iconPath
        $lnk.Description      = "GaiaSeis - GNSS real-time seismogeodesy"
        $lnk.Save()
        Write-Done "Wrote $lnkPath"
    }
}

# ---- 5. Done -------------------------------------------------------------
Write-Host ""
Write-Host "GaiaSeis $ver installed at $InstallDir" -ForegroundColor Green
Write-Host "Launch via Start Menu, Desktop shortcut, or:" -ForegroundColor Green
Write-Host "    $(Join-Path $InstallDir 'launch.bat')" -ForegroundColor Green
