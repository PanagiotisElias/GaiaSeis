#!/usr/bin/env bash
# GaiaSeis installer (Linux).
#
# Counterpart of install.ps1.  Copies the bundled tree to
# ~/.local/share/GaiaSeis, resolves + precompiles every Julia dependency,
# then registers a freedesktop .desktop entry and icon so GaiaSeis shows
# up in the application menu, plus a `gaiaseis` symlink in ~/.local/bin.
#
# Run from the unpacked bundle root:
#   ./install.sh                        default (per-user) install
#   ./install.sh --prefix /opt/gaiaseis system-wide (needs sudo)
#   ./install.sh --no-desktop           skip menu entry / icon / symlink
#   ./install.sh --no-precompile        skip the slow Pkg.precompile step
#
# Re-running is safe: the program directory is replaced, while user state
# under ${XDG_STATE_HOME:-~/.local/state}/gaiaseis (logs, miniSEED, the
# live profile TOML) is never touched.  Use uninstall.sh to remove.

set -euo pipefail

BUNDLE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/GaiaSeis"
DO_DESKTOP=1
DO_PRECOMPILE=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)        PREFIX="$2"; shift 2 ;;
        --prefix=*)      PREFIX="${1#*=}"; shift ;;
        --no-desktop)    DO_DESKTOP=0; shift ;;
        --no-precompile) DO_PRECOMPILE=0; shift ;;
        -h|--help)       sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Colour helpers, degrading to plain text when stdout is not a terminal.
if [[ -t 1 ]]; then C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
else C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""; fi
step() { echo "${C_STEP}==> $*${C_OFF}"; }
done_() { echo "${C_OK}    $*${C_OFF}"; }
warn() { echo "${C_WARN}    $*${C_OFF}"; }
die()  { echo "${C_ERR}$*${C_OFF}" >&2; exit 1; }

# ---- 1. Locate Julia ---------------------------------------------------
step "Looking for Julia (>= 1.10) on PATH"
JULIA="${JULIA:-julia}"
command -v "$JULIA" >/dev/null 2>&1 || die "Julia was not found on PATH.
Install it with juliaup (recommended):
    curl -fsSL https://install.julialang.org | sh
then open a new shell and re-run this installer."

JULIA_BIN="$(command -v "$JULIA")"
done_ "Found $JULIA_BIN"

JVER="$("$JULIA" -e 'print(string(VERSION))')"
"$JULIA" -e 'exit(VERSION >= v"1.10" ? 0 : 1)' \
    || die "Julia $JVER is too old. Please install Julia >= 1.10."
done_ "Julia version $JVER"

# ---- 2. Sanity-check the bundle ---------------------------------------
# GaiaSeis/ is the platform, GaiaVario.jl/ the displacement engine; both
# are required.  PPPH_VA/ (the optional PPPHVA engine) is only present in
# bundles made with --with-ppphva and is copied when it is there.
for d in GaiaSeis GaiaVario.jl; do
    [[ -f "$BUNDLE_ROOT/$d/Project.toml" ]] \
        || die "Bundle is missing '$d' — is install.sh next to GaiaSeis/ and GaiaVario.jl/ ?"
done
HAVE_PPPHVA=0
[[ -f "$BUNDLE_ROOT/PPPH_VA/PPPHVA.jl/Project.toml" ]] && HAVE_PPPHVA=1

# ---- 3. Copy the tree into place --------------------------------------
step "Installing to $PREFIX"
if [[ -e "$PREFIX" ]]; then
    warn "Existing install found — replacing"
    rm -rf "$PREFIX"
fi
mkdir -p "$PREFIX"

for d in GaiaSeis GaiaVario.jl; do
    cp -r "$BUNDLE_ROOT/$d" "$PREFIX/"
done
if [[ $HAVE_PPPHVA -eq 1 ]]; then
    cp -r "$BUNDLE_ROOT/PPPH_VA" "$PREFIX/"
    done_ "Optional PPPHVA engine included"
fi
for f in launch.sh uninstall.sh README_INSTALL.md gaiaseis.desktop.in \
         LICENSE NOTICE.md THIRD_PARTY_LICENSES.md; do
    [[ -f "$BUNDLE_ROOT/$f" ]] && cp "$BUNDLE_ROOT/$f" "$PREFIX/"
done
chmod +x "$PREFIX/launch.sh" "$PREFIX/uninstall.sh" 2>/dev/null || true
done_ "Source copied"

# User state lives outside the program directory, so a reinstall never
# risks the profile TOML or the recorded streams.
STATE_DIR="${GAIASEIS_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gaiaseis}"
mkdir -p "$STATE_DIR/logs" "$STATE_DIR/config" "$STATE_DIR/mseed2"
if [[ ! -f "$STATE_DIR/config/ntrip_profiles.toml" ]]; then
    cp "$PREFIX/GaiaSeis/config/ntrip_profiles.toml" "$STATE_DIR/config/"
    done_ "Seeded profile config at $STATE_DIR/config/ntrip_profiles.toml"
else
    done_ "Kept existing profile config at $STATE_DIR/config/ntrip_profiles.toml"
fi

# ---- 4. Resolve + precompile ------------------------------------------
if [[ $DO_PRECOMPILE -eq 0 ]]; then
    warn "Skipping precompile (re-run without --no-precompile to populate the cache)"
else
    step "Resolving + precompiling Julia packages (5-10 min on first install)"
    "$JULIA" --project="$PREFIX/GaiaSeis" \
        -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' \
        || die "Pkg.instantiate / Pkg.precompile failed (see output above)."
    done_ "GaiaSeis packages ready"
    # The engine has its own (small) environment: the engine API inside
    # GaiaSeis/ plus standard libraries. Precompile it with GaiaSeis on the
    # load path, the way launch.sh runs it.
    JULIA_LOAD_PATH="@:$PREFIX/GaiaSeis:@stdlib" "$JULIA" --project="$PREFIX/GaiaVario.jl" \
        -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(); using GaiaVario' \
        || die "GaiaVario could not be resolved or loaded (see output above)."
    done_ "GaiaVario engine ready"
fi

# ---- 5. Desktop integration -------------------------------------------
if [[ $DO_DESKTOP -eq 1 ]]; then
    step "Registering desktop entry + icons"

    # System-wide prefixes get system-wide integration; otherwise per-user.
    if [[ "$PREFIX" == /opt/* || "$PREFIX" == /usr/* ]]; then
        APPDIR="/usr/share/applications"
        ICONROOT="/usr/share/icons/hicolor"
        BINDIR="/usr/local/bin"
    else
        APPDIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
        ICONROOT="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
        BINDIR="$HOME/.local/bin"
    fi
    mkdir -p "$APPDIR" "$BINDIR"

    # Icons: the repo already ships a freedesktop-shaped tree under
    # docs/assets/icons (scalable/apps + <NN>x<NN>/apps), so each entry
    # maps 1:1 onto hicolor.
    SRC_ICONS="$PREFIX/GaiaSeis/docs/assets/icons"
    for sub in scalable 64x64 128x128; do
        if [[ -d "$SRC_ICONS/$sub/apps" ]]; then
            mkdir -p "$ICONROOT/$sub/apps"
            cp "$SRC_ICONS/$sub/apps/"gaiaseis.* "$ICONROOT/$sub/apps/" 2>/dev/null || true
        fi
    done
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache -q -t -f "$ICONROOT" 2>/dev/null || true
    done_ "Icons installed under $ICONROOT"

    # .desktop — @EXEC@ / @ICON@ are substituted from the template.
    DESKTOP_FILE="$APPDIR/gaiaseis.desktop"
    sed -e "s|@EXEC@|$PREFIX/launch.sh|g" \
        -e "s|@ICON@|gaiaseis|g" \
        -e "s|@PATH@|$PREFIX|g" \
        "$PREFIX/gaiaseis.desktop.in" > "$DESKTOP_FILE"
    chmod 644 "$DESKTOP_FILE"
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database -q "$APPDIR" 2>/dev/null || true
    done_ "Wrote $DESKTOP_FILE"

    ln -sf "$PREFIX/launch.sh" "$BINDIR/gaiaseis"
    done_ "Linked $BINDIR/gaiaseis"
    case ":$PATH:" in
        *":$BINDIR:"*) ;;
        *) warn "$BINDIR is not on your PATH — add it to run 'gaiaseis' directly" ;;
    esac
fi

# ---- 6. Done -----------------------------------------------------------
echo
echo "${C_OK}GaiaSeis installed at $PREFIX${C_OFF}"
echo "${C_OK}User data at        $STATE_DIR${C_OFF}"
echo "${C_OK}Launch with:        $PREFIX/launch.sh${C_OFF}"
[[ $DO_DESKTOP -eq 1 ]] && echo "${C_OK}or 'gaiaseis', or from the application menu.${C_OFF}"
