#!/usr/bin/env bash
# build-app.sh — compile GaiaSeis into a standalone Linux binary.
#
# Produces a directory that needs NO Julia installation on the target
# machine: the Julia runtime, every package and every GTK shared library
# are inside it.
#
#     dist/gaiaseis-app/
#     ├── bin/gaiaseis            <- the executable
#     ├── lib/                    <- Julia runtime + sysimage + artifacts
#     ├── share/julia/
#     └── share/gaiaseis/         <- assets, config template, licences
#
# The GaiaVario engine is compiled into the binary. The optional PPPHVA
# engine (not part of the public release) is compiled in only with
# --with-ppphva.
#
# MUST RUN ON LINUX.  Julia has no cross-compiler; a binary built here
# runs on Linux only, and on distributions whose glibc is at least as new
# as this machine's.  Build on the oldest target you care about.
#
# Usage:
#   ./bundle/linux/build-app.sh
#   ./bundle/linux/build-app.sh --dest /tmp/gaiaseis-app --tar
#
# Options:
#   --dest <path>         output directory (default bundle/linux/dist/gaiaseis-app)
#   --gaiavario <path>    GaiaVario.jl checkout (default ../GaiaVario.jl beside
#                         the repository, or GaiaVario.jl/ beside this kit)
#   --with-ppphva [path]  also compile in PPPHVA (default: not included;
#                         looked for at ../PPPH_VA/PPPHVA.jl without a path)
#   --tar                 also pack the result into a .tar.gz
#   --keep-credentials    ship the profile TOML verbatim instead of blanking
#                         the NTRIP usernames/passwords

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Repository root: two levels up in the source tree (bundle/linux/), or the
# GaiaSeis/ directory beside this kit when run from an unpacked bundle
# (<bundle>/build-app/).
if [[ -f "$HERE/../../Project.toml" ]]; then
    REPO_ROOT="$(cd "$HERE/../.." && pwd)"
elif [[ -f "$HERE/../GaiaSeis/Project.toml" ]]; then
    REPO_ROOT="$(cd "$HERE/../GaiaSeis" && pwd)"
else
    echo "Cannot locate the GaiaSeis Project.toml from $HERE" >&2; exit 1
fi

DEST="$HERE/dist/gaiaseis-app"
GAIAVARIO_DIR=""
WITH_PPPHVA=0
PPPHVA_DIR=""
DO_TAR=0
SCRUB=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)             DEST="$2"; shift 2 ;;
        --dest=*)           DEST="${1#*=}"; shift ;;
        --gaiavario)        GAIAVARIO_DIR="$2"; shift 2 ;;
        --gaiavario=*)      GAIAVARIO_DIR="${1#*=}"; shift ;;
        --with-ppphva)
            WITH_PPPHVA=1
            if [[ $# -gt 1 && "$2" != -* ]]; then PPPHVA_DIR="$2"; shift 2; else shift; fi ;;
        --with-ppphva=*)    WITH_PPPHVA=1; PPPHVA_DIR="${1#*=}"; shift ;;
        --tar)              DO_TAR=1; shift ;;
        --keep-credentials) SCRUB=0; shift ;;
        -h|--help)          sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
else C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""; fi
step() { echo "${C_STEP}==> $*${C_OFF}"; }
done_() { echo "${C_OK}    $*${C_OFF}"; }
warn() { echo "${C_WARN}    $*${C_OFF}"; }
die()  { echo "${C_ERR}$*${C_OFF}" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] \
    || die "This builds a Linux binary and Julia cannot cross-compile.
Run it on the Linux machine you are targeting (WSL counts)."

JULIA="${JULIA:-julia}"
command -v "$JULIA" >/dev/null 2>&1 \
    || die "julia not found on PATH. Install it with:
    curl -fsSL https://install.julialang.org | sh"
"$JULIA" -e 'exit(VERSION >= v"1.10" ? 0 : 1)' \
    || die "Julia >= 1.10 is required to build the app."
done_ "Using $(command -v "$JULIA") ($("$JULIA" -e 'print(string(VERSION))'))"

command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 \
    || warn "no C compiler found — PackageCompiler needs one (apt install build-essential)"

# ---- Locate the GaiaVario engine ----------------------------------------
if [[ -z "$GAIAVARIO_DIR" ]]; then
    for cand in "$REPO_ROOT/../GaiaVario.jl" "$HERE/../GaiaVario.jl"; do
        if [[ -f "$cand/Project.toml" ]]; then GAIAVARIO_DIR="$(cd "$cand" && pwd)"; break; fi
    done
fi
[[ -n "$GAIAVARIO_DIR" && -f "$GAIAVARIO_DIR/Project.toml" ]] \
    || die "GaiaVario.jl not found — pass --gaiavario <path>."
done_ "GaiaVario at $GAIAVARIO_DIR"

# ---- Optional PPPHVA ----------------------------------------------------
GPT_SRC=""
if [[ $WITH_PPPHVA -eq 1 ]]; then
    if [[ -z "$PPPHVA_DIR" ]]; then
        for cand in "$REPO_ROOT/../PPPH_VA/PPPHVA.jl" "$HERE/../PPPH_VA/PPPHVA.jl"; do
            if [[ -f "$cand/Project.toml" ]]; then PPPHVA_DIR="$(cd "$cand" && pwd)"; break; fi
        done
    fi
    if [[ -n "$PPPHVA_DIR" && -f "$PPPHVA_DIR/Project.toml" ]]; then
        done_ "PPPHVA at $PPPHVA_DIR (compiled in)"
        for cand in "$PPPHVA_DIR/data/gpt3_5.grd" \
                    "$PPPHVA_DIR/../PPPH_VA_final/3.Modelling/GMF/gpt3_5.grd"; do
            if [[ -f "$cand" ]]; then GPT_SRC="$cand"; break; fi
        done
        [[ -n "$GPT_SRC" ]] || warn "gpt3_5.grd not found — PPPHVA falls back on the simpler tropo model"
    else
        warn "--with-ppphva given but PPPHVA.jl was not found — building without it"
        WITH_PPPHVA=0; PPPHVA_DIR=""
    fi
else
    done_ "PPPHVA not included (default; --with-ppphva to add it)"
fi

# ---- Compile -----------------------------------------------------------
step "Compiling (10-30 min, several GB of RAM)"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
"$JULIA" --project="$HERE/app" "$HERE/build_app.jl" \
         "$REPO_ROOT" "$HERE/app" "$DEST" "$GAIAVARIO_DIR" "$PPPHVA_DIR"
[[ -x "$DEST/bin/gaiaseis" ]] || die "build finished but $DEST/bin/gaiaseis is missing"
done_ "Binary at $DEST/bin/gaiaseis"

# ---- Stage the runtime data -------------------------------------------
# `@__DIR__` is meaningless inside the binary, so the assets and the config
# template are laid down here and GaiaSeisApp points app_root() at this
# directory via Sys.BINDIR.  ANTEX files are third-party data and are not
# redistributed; the user names one in the profile's antex_file.
step "Staging program data into share/gaiaseis"
SHARE="$DEST/share/gaiaseis"
mkdir -p "$SHARE"
cp -r "$REPO_ROOT/docs" "$SHARE/"
cp -r "$REPO_ROOT/config" "$SHARE/"
for f in README.md LICENSE NOTICE.md; do
    [[ -f "$REPO_ROOT/$f" ]] && cp "$REPO_ROOT/$f" "$SHARE/"
done
[[ -f "$GAIAVARIO_DIR/LICENSE" ]] && cp "$GAIAVARIO_DIR/LICENSE" "$SHARE/LICENSE-GaiaVario"
rm -rf "$SHARE"/docs/_*
find "$SHARE" \( -name '.DS_Store' -o -name 'desktop.ini' -o -name '*.atx' \) -delete 2>/dev/null || true

# Profile template: the example file when the repository has one, else
# the live TOML with credentials blanked.
TOML_OUT="$SHARE/config/ntrip_profiles.toml"
if [[ -f "$SHARE/config/ntrip_profiles.example.toml" ]]; then
    mv -f "$SHARE/config/ntrip_profiles.example.toml" "$TOML_OUT"
    done_ "Profile template taken from ntrip_profiles.example.toml"
elif [[ -f "$TOML_OUT" && $SCRUB -eq 1 ]]; then
    sed -i -E 's|"[A-Za-z]:\\\\[^"]*\\\\([^"\\]+)"|"./\1"|g' "$TOML_OUT"
    sed -i -E 's#^(user|password|ssr_user|ssr_password|eph_user|eph_password)[[:space:]]*=.*#\1 = ""#' "$TOML_OUT"
    done_ "Credentials blanked from the shipped profile template"
elif [[ -f "$TOML_OUT" ]]; then
    warn "--keep-credentials: NTRIP usernames/passwords are inside this build."
fi

# Third-party licences for everything compiled into the binary.
MANIFESTS=("$REPO_ROOT/Manifest.toml")
[[ -f "$GAIAVARIO_DIR/Manifest.toml" ]] && MANIFESTS+=("$GAIAVARIO_DIR/Manifest.toml")
[[ $WITH_PPPHVA -eq 1 && -f "$PPPHVA_DIR/Manifest.toml" ]] && MANIFESTS+=("$PPPHVA_DIR/Manifest.toml")
APP_VERSION="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/Project.toml" | head -1)"
bash "$HERE/third-party-licenses.sh" --out "$SHARE/THIRD_PARTY_LICENSES.md" \
     --version "${APP_VERSION:-unknown}" "${MANIFESTS[@]}" \
    || warn "THIRD_PARTY_LICENSES.md could not be generated"

# GPT3 tropospheric grid (PPPHVA only) — GaiaSeisApp looks for
# share/gaiaseis/data/gpt3_5.grd.
if [[ -n "$GPT_SRC" ]]; then
    mkdir -p "$SHARE/data"
    cp "$GPT_SRC" "$SHARE/data/gpt3_5.grd"
    done_ "Embedded gpt3_5.grd"
fi

# ---- Desktop entry for the compiled app -------------------------------
sed -e "s|@EXEC@|$DEST/bin/gaiaseis|g" \
    -e "s|@ICON@|$SHARE/docs/assets/icons/128x128/apps/gaiaseis.png|g" \
    -e "s|@PATH@|$DEST|g" \
    "$HERE/gaiaseis.desktop.in" > "$DEST/gaiaseis.desktop"
done_ "Wrote $DEST/gaiaseis.desktop (copy to ~/.local/share/applications/ to register)"

# ---- Smoke test --------------------------------------------------------
step "Smoke-testing the binary"
if "$DEST/bin/gaiaseis" --version; then
    done_ "Binary runs"
else
    warn "--version failed; inspect the output above before shipping"
fi

if [[ $DO_TAR -eq 1 ]]; then
    step "Packing tarball"
    TARBALL="$(dirname "$DEST")/$(basename "$DEST").tar.gz"
    ( cd "$(dirname "$DEST")" && tar czf "$(basename "$DEST").tar.gz" "$(basename "$DEST")" )
    done_ "Wrote $TARBALL ($(du -m "$TARBALL" | cut -f1) MB)"
fi

echo
echo "${C_OK}Done. Run it with: $DEST/bin/gaiaseis${C_OFF}"
echo "${C_OK}User data goes to \${XDG_STATE_HOME:-~/.local/state}/gaiaseis${C_OFF}"
