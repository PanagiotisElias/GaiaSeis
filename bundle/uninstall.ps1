# GaiaSeis uninstaller.
#
# Removes the Start-Menu + Desktop shortcuts and the install directory.
# By default it asks before deleting any user data (logs, mseed dumps,
# the live ntrip_profiles.toml). Pass -Force to skip the prompts and
# -KeepUserData to keep them entirely.
#
# Usage from the installed location:
#   .\uninstall.ps1
#   .\uninstall.ps1 -Force
#   .\uninstall.ps1 -Force -KeepUserData

[CmdletBinding()]
param(
    [string]$InstallDir = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [switch]$Force,
    [switch]$KeepUserData
)

$ErrorActionPreference = "Stop"

function Write-Step ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Done ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

Write-Step "Uninstalling GaiaSeis from $InstallDir"

if (-not (Test-Path (Join-Path $InstallDir "GaiaSeis\Project.toml"))) {
    Write-Host "No GaiaSeis install detected at $InstallDir" -ForegroundColor Red
    exit 1
}

# ---- 1. Shortcuts --------------------------------------------------------
$startDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
foreach ($where in @($startDir, [Environment]::GetFolderPath("Desktop"))) {
    $lnk = Join-Path $where "GaiaSeis.lnk"
    if (Test-Path $lnk) {
        Remove-Item -Force $lnk
        Write-Done "Removed $lnk"
    }
}

# ---- 2. Optionally preserve user data ------------------------------------
$userDirs = @("logs", "mseed", "mseed2")
$userFiles = @("ntrip_profiles.toml")
$hasUserData = $false
foreach ($d in $userDirs) {
    if (Test-Path (Join-Path $InstallDir "GaiaSeis\$d")) { $hasUserData = $true; break }
}
foreach ($f in $userFiles) {
    if (Test-Path (Join-Path $InstallDir "GaiaSeis\$f")) { $hasUserData = $true; break }
}

if ($hasUserData) {
    if ($KeepUserData) {
        # Move them out of the install dir before deleting it
        $stash = Join-Path $env:USERPROFILE "GaiaSeis-data-backup-$(Get-Date -Format yyyyMMdd_HHmmss)"
        New-Item -ItemType Directory -Path $stash | Out-Null
        foreach ($d in $userDirs + $userFiles) {
            $src = Join-Path $InstallDir "GaiaSeis\$d"
            if (Test-Path $src) {
                Move-Item -Path $src -Destination (Join-Path $stash $d)
                Write-Done "Preserved $d under $stash"
            }
        }
    } elseif (-not $Force) {
        Write-Warn2 "User data detected (logs / mseed / ntrip_profiles.toml)."
        $ans = Read-Host "Delete EVERYTHING under $InstallDir, including user data? [y/N]"
        if ($ans -notmatch '^[yY]') {
            Write-Host "Aborted by user. Re-run with -KeepUserData to preserve it." -ForegroundColor Yellow
            exit 0
        }
    }
}

# ---- 3. Remove the install tree -----------------------------------------
# The script lives inside the directory we want to delete, so we copy
# ourselves to a temp location and re-exec from there. PowerShell holds a
# read lock on the running script that would otherwise prevent Remove-Item.
if ((Split-Path -Parent $PSCommandPath) -eq $InstallDir) {
    $tmpDir = Join-Path $env:TEMP ("gaiaseis-uninstall-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    $tmpScript = Join-Path $tmpDir "uninstall.ps1"
    Copy-Item -Path $PSCommandPath -Destination $tmpScript
    # Re-exec from the temp copy so the original can be deleted
    & powershell.exe -ExecutionPolicy Bypass -File $tmpScript `
        -InstallDir $InstallDir -Force:$Force -KeepUserData:$KeepUserData
    exit $LASTEXITCODE
}

Remove-Item -Recurse -Force $InstallDir
Write-Done "Removed $InstallDir"

Write-Host ""
Write-Host "GaiaSeis uninstalled." -ForegroundColor Green
