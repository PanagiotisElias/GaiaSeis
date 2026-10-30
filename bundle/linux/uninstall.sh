#!/usr/bin/env bash
# GaiaSeis uninstaller (Linux).
#
# Removes the program directory, the desktop entry, the installed icons
# and the ~/.local/bin/gaiaseis symlink.  User data (logs, miniSEED, the
# profile TOML under ${XDG_STATE_HOME:-~/.local/state}/gaiaseis) is kept
# unless you ask for it to go.
#
# Julia itself and the package depot under ~/.julia are never touched.
#
#   ./uninstall.sh                 remove the program, keep user data
#   ./uninstall.sh --purge         also delete the user data directory
#   ./uninstall.sh --keep-user-data <dir>
#                                  archive user data to <dir> first
#   ./uninstall.sh --force         no confirmation prompts
#   ./uninstall.sh --prefix <dir>  uninstall a non-default location

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="$HERE"
[[ -d "$PREFIX/GaiaSeis" ]] || PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/GaiaSeis"
STATE_DIR="${GAIASEIS_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gaiaseis}"
PURGE=0
FORCE=0
ARCHIVE_TO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)         PREFIX="$2"; shift 2 ;;
        --prefix=*)       PREFIX="${1#*=}"; shift ;;
        --purge)          PURGE=1; shift ;;
        --force)          FORCE=1; shift ;;
        --keep-user-data) ARCHIVE_TO="$2"; shift 2 ;;
        -h|--help)        sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
else C_STEP=""; C_OK=""; C_WARN=""; C_OFF=""; fi
step() { echo "${C_STEP}==> $*${C_OFF}"; }
done_() { echo "${C_OK}    $*${C_OFF}"; }
warn() { echo "${C_WARN}    $*${C_OFF}"; }

echo "About to remove:"
echo "    program directory : $PREFIX"
echo "    desktop entry     : gaiaseis.desktop"
echo "    icons + gaiaseis symlink"
if [[ $PURGE -eq 1 ]]; then
    echo "    user data (PURGE) : $STATE_DIR"
else
    echo "    user data KEPT    : $STATE_DIR"
fi
echo

if [[ $FORCE -eq 0 ]]; then
    read -r -p "Proceed? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ---- Archive user data if asked ---------------------------------------
if [[ -n "$ARCHIVE_TO" && -d "$STATE_DIR" ]]; then
    step "Archiving user data"
    mkdir -p "$ARCHIVE_TO"
    tar czf "$ARCHIVE_TO/gaiaseis-userdata.tar.gz" -C "$(dirname "$STATE_DIR")" "$(basename "$STATE_DIR")"
    done_ "Wrote $ARCHIVE_TO/gaiaseis-userdata.tar.gz"
fi

# ---- Desktop integration ----------------------------------------------
step "Removing desktop integration"
for APPDIR in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" /usr/share/applications; do
    if [[ -f "$APPDIR/gaiaseis.desktop" ]]; then
        rm -f "$APPDIR/gaiaseis.desktop" && done_ "Removed $APPDIR/gaiaseis.desktop"
        command -v update-desktop-database >/dev/null 2>&1 \
            && update-desktop-database -q "$APPDIR" 2>/dev/null || true
    fi
done
for ICONROOT in "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" /usr/share/icons/hicolor; do
    for sub in scalable 64x64 128x128; do
        rm -f "$ICONROOT/$sub/apps/gaiaseis."* 2>/dev/null || true
    done
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache -q -t -f "$ICONROOT" 2>/dev/null || true
done
for BINDIR in "$HOME/.local/bin" /usr/local/bin; do
    if [[ -L "$BINDIR/gaiaseis" ]]; then
        rm -f "$BINDIR/gaiaseis" && done_ "Removed $BINDIR/gaiaseis"
    fi
done

# ---- Program directory -------------------------------------------------
# Guard against a mis-typed --prefix nuking something unrelated: only
# delete a directory that actually looks like a GaiaSeis install.
step "Removing program directory"
if [[ -d "$PREFIX" && -d "$PREFIX/GaiaSeis" && -f "$PREFIX/GaiaSeis/Project.toml" ]]; then
    # Deleting the tree we are executing from is fine on Linux (the inode
    # stays alive until this shell exits), but cd out of it to be safe.
    cd /
    rm -rf "$PREFIX"
    done_ "Removed $PREFIX"
else
    warn "$PREFIX does not look like a GaiaSeis install — left alone"
fi

# ---- User data ---------------------------------------------------------
if [[ $PURGE -eq 1 && -d "$STATE_DIR" ]]; then
    step "Purging user data"
    rm -rf "$STATE_DIR"
    done_ "Removed $STATE_DIR"
elif [[ -d "$STATE_DIR" ]]; then
    warn "User data kept at $STATE_DIR (delete manually or re-run with --purge)"
fi

echo
echo "${C_OK}GaiaSeis uninstalled.${C_OFF}"
