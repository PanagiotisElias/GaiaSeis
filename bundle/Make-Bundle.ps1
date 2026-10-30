# Make-Bundle.ps1 - build a portable GaiaSeis installation bundle.
#
# Stages the GaiaSeis source tree, the path-local PPPHVA dependency, and
# the GPT3 grid file into  bundle\dist\GaiaSeis-<version>\  and zips
# everything into  bundle\dist\GaiaSeis-<version>.zip  ready to ship.
#
# Run from the repo root:
#   .\bundle\Make-Bundle.ps1
#
# Switches:
#   -OutDir <path>      target dir for the staged tree + ZIP  (default bundle\dist)
#   -NoZip              keep the staged directory, skip the .zip
#   -Clean              wipe -OutDir first

[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "dist"),
    [switch]$NoZip,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

function Write-Step ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Done ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# ---- 0. Resolve paths ----------------------------------------------------
$bundleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $bundleDir
$projTOML  = Join-Path $repoRoot "Project.toml"
if (-not (Test-Path $projTOML)) {
    Write-Host "Project.toml not found at $projTOML - am I running from the right place?" -ForegroundColor Red
    exit 1
}

# Locate the PPPHVA dependency (path declared in Manifest.toml)
$reposParent = Split-Path -Parent $repoRoot
$pppDir = Join-Path $reposParent "PPPH_VA\PPPHVA.jl"
if (-not (Test-Path (Join-Path $pppDir "Project.toml"))) {
    Write-Host "PPPHVA.jl not found at $pppDir" -ForegroundColor Red
    Write-Host "The bundle needs the path-local PPPHVA dep at ..\PPPH_VA\PPPHVA.jl" -ForegroundColor Red
    exit 1
}

# GPT3 grid lives outside PPPHVA.jl in the upstream layout
$gptSrc = Join-Path $reposParent "PPPH_VA\PPPH_VA_final\3.Modelling\GMF\gpt3_5.grd"
if (-not (Test-Path $gptSrc)) {
    Write-Warn2 "gpt3_5.grd not found at $gptSrc - bundle will ship without it (tropo model fallback)"
}

# Parse version out of Project.toml (single-line regex is enough)
$verLine = (Get-Content $projTOML | Where-Object { $_ -match '^\s*version\s*=' }) | Select-Object -First 1
if (-not ($verLine -match '"([^"]+)"')) {
    Write-Host "Could not parse version from $projTOML" -ForegroundColor Red
    exit 1
}
$version = $Matches[1]
Write-Done "GaiaSeis version $version"

# ---- 1. Prepare staging dir ---------------------------------------------
if ($Clean -and (Test-Path $OutDir)) {
    Remove-Item -Recurse -Force $OutDir
}
$stageRoot = Join-Path $OutDir "GaiaSeis-$version"
if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
New-Item -ItemType Directory -Path $stageRoot | Out-Null

# ---- 2. Stage GaiaSeis source -------------------------------------------
Write-Step "Staging GaiaSeis source"
$gsTarget = Join-Path $stageRoot "GaiaSeis"
New-Item -ItemType Directory -Path $gsTarget | Out-Null

# Things to include - everything the package needs to load + run, plus
# the antenna calibration files that ship with the repo.
$includeDirs = @("src", "examples", "docs", "config", "test")
foreach ($d in $includeDirs) {
    $src = Join-Path $repoRoot $d
    if (Test-Path $src) {
        Copy-Item -Recurse -Force -Path $src -Destination $gsTarget
    }
}
$includeFiles = @(
    "Project.toml", "Manifest.toml", "README.md", "LICENSE",
    "LINUX_HANDOFF.md",
    "ASH700936E_NONE.atx", "igs14_2163.atx"
)
foreach ($f in $includeFiles) {
    $src = Join-Path $repoRoot $f
    if (Test-Path $src) {
        Copy-Item -Force -Path $src -Destination $gsTarget
    }
}

# Prune runtime / scratch content from inside the staged source tree
$pruneRelative = @(
    "logs",
    "mseed",
    "mseed2",
    "docs\_build",
    "docs\MANUAL.docx",
    "src\.DS_Store"
)
foreach ($r in $pruneRelative) {
    $p = Join-Path $gsTarget $r
    if (Test-Path $p) {
        Remove-Item -Recurse -Force $p
        Write-Warn2 "Pruned $r"
    }
}
Write-Done "GaiaSeis source staged"

# ---- 3. Stage PPPHVA dependency -----------------------------------------
Write-Step "Staging PPPHVA dependency"
$pppTargetParent = Join-Path $stageRoot "PPPH_VA"
$pppTarget       = Join-Path $pppTargetParent "PPPHVA.jl"
New-Item -ItemType Directory -Path $pppTargetParent | Out-Null
# Copy the whole tree
Copy-Item -Recurse -Force -Path $pppDir -Destination $pppTargetParent
# Drop runtime junk
foreach ($r in @("docs\_build", ".DS_Store")) {
    $p = Join-Path $pppTarget $r
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}
# Embed the GPT3 grid inside the dep so PPPHVA's relative fallback path
# `dirname(pathof(PPPHVA))/../data/gpt3_5.grd` resolves wherever the user
# installs.
if ($gptSrc -and (Test-Path $gptSrc)) {
    $dataDir = Join-Path $pppTarget "data"
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
    Copy-Item -Force -Path $gptSrc -Destination (Join-Path $dataDir "gpt3_5.grd")
    $gptMB = [math]::Round((Get-Item $gptSrc).Length / 1MB, 1)
    Write-Done ("Embedded gpt3_5.grd ({0} MB)" -f $gptMB)
}
Write-Done "PPPHVA staged at $pppTarget"

# ---- 4. Stage installer / launcher / uninstaller / README ---------------
Write-Step "Staging installer scripts"
foreach ($f in @(
    "install.ps1", "install.bat",
    "uninstall.ps1", "uninstall.bat",
    "launch.bat",
    "README_INSTALL.md"
)) {
    Copy-Item -Force -Path (Join-Path $bundleDir $f) -Destination $stageRoot
}
Write-Done "Installer scripts staged"

# ---- 5. Pin the version into install.ps1's banner ----------------------
# (purely cosmetic - install.ps1 doesn't use the version itself but it's
# useful to see in the console output)
$installPath = Join-Path $stageRoot "install.ps1"
$installText = Get-Content -Raw $installPath
$installText = $installText -replace "GaiaSeis \`$ver installed", "GaiaSeis $version installed"
Set-Content -Path $installPath -Value $installText -NoNewline

# ---- 6. Zip --------------------------------------------------------------
if (-not $NoZip) {
    Write-Step "Compressing to ZIP"
    $zipPath = Join-Path $OutDir "GaiaSeis-$version.zip"
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
    Compress-Archive -Path $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal
    $zipMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Done "Wrote $zipPath ($zipMB MB)"
}

Write-Host ""
Write-Host "Done. Staged tree: $stageRoot" -ForegroundColor Green
if (-not $NoZip) {
    Write-Host "ZIP:           $(Join-Path $OutDir "GaiaSeis-$version.zip")" -ForegroundColor Green
}
