#!/usr/bin/env bash
# make-bundle.sh — build a portable GaiaSeis installation bundle for Linux.
#
# Stages the GaiaSeis source tree and the GaiaVario engine package into
#   bundle/linux/dist/GaiaSeis-<version>-linux/
# together with the installer scripts, the licence files and a generated
# THIRD_PARTY_LICENSES.md, and packs it into a .tar.gz and/or .zip.
#
# Runs anywhere with bash + coreutils + tar (Git Bash / WSL included).
# The .zip path additionally needs Info-ZIP `zip`.
#
#   ./bundle/linux/make-bundle.sh            # .tar.gz (default)
#   ./bundle/linux/make-bundle.sh --zip      # .zip instead
#   ./bundle/linux/make-bundle.sh --both     # both archives
#
# Options:
#   --out-dir <path>       target for the staged tree + archives
#                          (default bundle/linux/dist)
#   --gaiavario <path>     GaiaVario.jl checkout (default: ../GaiaVario.jl
#                          beside this repository). Required.
#   --with-ppphva [path]   also stage the PPPHVA package (the Julia
#                          translation of PPPH-VA, NOT part of the public
#                          release). Default: not staged. Without a path it
#                          is looked for at ../PPPH_VA/PPPHVA.jl.
#   --zip                  emit a .zip instead of the .tar.gz
#   --both                 emit both a .tar.gz and a .zip
#   --no-tar               keep the staged directory, emit no archive
#   --clean                wipe the output directory first
#   --keep-credentials     ship config/ntrip_profiles.toml verbatim.  By
#                          default every user/password field is blanked and
#                          Windows paths are rewritten — the TOML in a working
#                          tree may hold live NTRIP caster credentials and a
#                          bundle is something you hand to other people.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

OUT_DIR="$HERE/dist"
GAIAVARIO_DIR=""
WITH_PPPHVA=0
PPPHVA_DIR=""
DO_TAR=1
DO_ZIP=0
DO_CLEAN=0
SCRUB=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir)          OUT_DIR="$2"; shift 2 ;;
        --out-dir=*)        OUT_DIR="${1#*=}"; shift ;;
        --gaiavario)        GAIAVARIO_DIR="$2"; shift 2 ;;
        --gaiavario=*)      GAIAVARIO_DIR="${1#*=}"; shift ;;
        --with-ppphva)
            WITH_PPPHVA=1
            if [[ $# -gt 1 && "$2" != -* ]]; then PPPHVA_DIR="$2"; shift 2; else shift; fi ;;
        --with-ppphva=*)    WITH_PPPHVA=1; PPPHVA_DIR="${1#*=}"; shift ;;
        --zip)              DO_ZIP=1; DO_TAR=0; shift ;;
        --both)             DO_ZIP=1; DO_TAR=1; shift ;;
        --no-tar)           DO_TAR=0; DO_ZIP=0; shift ;;
        --clean)            DO_CLEAN=1; shift ;;
        --keep-credentials) SCRUB=0; shift ;;
        -h|--help)          sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -t 1 ]]; then C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
else C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""; fi
step() { echo "${C_STEP}==> $*${C_OFF}"; }
done_() { echo "${C_OK}    $*${C_OFF}"; }
warn() { echo "${C_WARN}    $*${C_OFF}"; }
die()  { echo "${C_ERR}$*${C_OFF}" >&2; exit 1; }

# ---- 0. Resolve paths --------------------------------------------------
PROJ_TOML="$REPO_ROOT/Project.toml"
[[ -f "$PROJ_TOML" ]] || die "Project.toml not found at $PROJ_TOML — am I running from the right place?"

VERSION="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$PROJ_TOML" | head -1)"
[[ -n "$VERSION" ]] || die "Could not parse version from $PROJ_TOML"
done_ "GaiaSeis version $VERSION"

# The engine: GaiaVario.jl, a sibling of this repository in the development
# layout. Its Manifest refers to the engine API inside this repository
# (../NtripClient.jl/GaiaSeisEngineAPI); step 3 rewrites that path for the
# staged layout, where the repository is named GaiaSeis/.
if [[ -z "$GAIAVARIO_DIR" ]]; then
    for cand in "$REPO_ROOT/../GaiaVario.jl" "$REPO_ROOT/GaiaVario.jl"; do
        if [[ -f "$cand/Project.toml" ]]; then GAIAVARIO_DIR="$(cd "$cand" && pwd)"; break; fi
    done
fi
[[ -n "$GAIAVARIO_DIR" && -f "$GAIAVARIO_DIR/Project.toml" ]] \
    || die "GaiaVario.jl not found. Pass --gaiavario <path> to the GaiaVario.jl checkout."
grep -q '^name = "GaiaVario"' "$GAIAVARIO_DIR/Project.toml" \
    || die "$GAIAVARIO_DIR/Project.toml is not the GaiaVario package"
[[ -d "$REPO_ROOT/GaiaSeisEngineAPI" ]] \
    || die "GaiaSeisEngineAPI not found at $REPO_ROOT/GaiaSeisEngineAPI"
done_ "GaiaVario at $GAIAVARIO_DIR"

# PPPHVA is optional and off by default: it is not distributed with the
# public release. With --with-ppphva it is staged beside GaiaSeis/ as
# PPPH_VA/PPPHVA.jl, where the platform finds it at run time.
GPT_SRC=""
if [[ $WITH_PPPHVA -eq 1 ]]; then
    if [[ -z "$PPPHVA_DIR" ]]; then
        for cand in \
            "$REPO_ROOT/../PPPH_VA/PPPHVA.jl" \
            "$REPO_ROOT/../../PPPH_VA/PPPHVA.jl"
        do
            if [[ -f "$cand/Project.toml" ]]; then PPPHVA_DIR="$(cd "$cand" && pwd)"; break; fi
        done
    fi
    if [[ -n "$PPPHVA_DIR" && -f "$PPPHVA_DIR/Project.toml" ]]; then
        done_ "PPPHVA at $PPPHVA_DIR (will be staged)"
        # The GPT3 grid lives outside PPPHVA.jl in the upstream layout.
        for cand in \
            "$PPPHVA_DIR/data/gpt3_5.grd" \
            "$PPPHVA_DIR/../PPPH_VA_final/3.Modelling/GMF/gpt3_5.grd"
        do
            if [[ -f "$cand" ]]; then GPT_SRC="$cand"; break; fi
        done
        [[ -n "$GPT_SRC" ]] || warn "gpt3_5.grd not found — PPPHVA ships without it (tropo model fallback)"
    else
        warn "--with-ppphva given but PPPHVA.jl was not found — bundling without it"
        WITH_PPPHVA=0
        PPPHVA_DIR=""
    fi
else
    done_ "PPPHVA not included (default; --with-ppphva to add it)"
fi

# ---- 1. Staging directory ---------------------------------------------
[[ $DO_CLEAN -eq 1 && -d "$OUT_DIR" ]] && rm -rf "$OUT_DIR"
STAGE_NAME="GaiaSeis-$VERSION-linux"
STAGE="$OUT_DIR/$STAGE_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# ---- 2. GaiaSeis source ------------------------------------------------
step "Staging GaiaSeis source"
GS="$STAGE/GaiaSeis"
mkdir -p "$GS"
for d in src examples docs config test tools GaiaSeisEngineAPI; do
    [[ -d "$REPO_ROOT/$d" ]] && cp -r "$REPO_ROOT/$d" "$GS/"
done
for f in Project.toml Manifest.toml README.md LICENSE NOTICE.md; do
    [[ -f "$REPO_ROOT/$f" ]] && cp "$REPO_ROOT/$f" "$GS/"
done
for f in LICENSE NOTICE.md; do
    [[ -f "$REPO_ROOT/$f" ]] || warn "$f is missing from the repository root — the bundle ships without it"
done

# Content that must not travel with a release: runtime output, build
# scratch, development notes, live-caster test scripts, site data.
# ANTEX files (*.atx) are third-party data and are not redistributed; the
# user supplies one through the profile's antex_file.
for r in logs mseed mseed2 docs/_build docs/MANUAL.docx \
         LINUX_HANDOFF.md CLAUDE.md ANYD_ipirnet files.zip \
         test/seed_caster_profiles.jl tools/export_public.sh; do
    if [[ -e "$GS/$r" ]]; then rm -rf "$GS/$r"; warn "Pruned $r"; fi
done
# Internal operator reports and engineering notes under docs/: they
# describe the development installation and are not part of the release
# (the same list as the public-tree export in tools/export_public.sh).
while IFS= read -r f; do
    case "$(basename "$f")" in
        Release_Decisions_*|UPA_vs_UPC_*|Causes_and_Mitigation_*|Constellation_Effect_*|\
        Epoch_Anomalies_*|GaiaSeis_Missing_Measurements_*|Missing_Epochs_Analysis.docx|\
        NtripClient_Manual*.docx|UPC10.xml|SPIKES_*|GaiaVario_vs_PPPHVA_overnight_interactive.html|\
        GaiaVario_Engine_Plan.md|GaiaVario_continuity_options_*|GaiaSeis_Leaflet.*|\
        gaiaseis_seiscomp_guide*.pdf|GaiaSeis_miniSEED_Operator_Guide.*|*_original.*)
            rm -f "$f"; warn "Pruned docs/$(basename "$f")" ;;
    esac
done < <(find "$GS/docs" -maxdepth 2 -type f)
while IFS= read -r -d '' f; do
    rm -rf "$f"; warn "Pruned $(realpath --relative-to="$GS" "$f")"
done < <(find "$GS" -mindepth 1 \( \
        \( -type d \( -name 'mseed*' -o -name 'logs' -o -name '__pycache__' \) \) \
        -o -name '*.atx' -o -path "$GS/docs/_*" -o -path "$GS/test/live_*" \
    \) -prune -print0)
find "$GS" -name '.DS_Store' -delete 2>/dev/null || true
find "$GS" -name 'desktop.ini' -delete 2>/dev/null || true
done_ "GaiaSeis source staged"

# ---- 2b. The shipped profile TOML --------------------------------------
# The profile TOML in a working tree carries the developer's casters and
# credentials. Ship config/ntrip_profiles.example.toml when the repository
# has one; otherwise fall back to scrubbing the live file.
TOML_OUT="$GS/config/ntrip_profiles.toml"
if [[ -f "$REPO_ROOT/config/ntrip_profiles.example.toml" ]]; then
    step "Shipping config/ntrip_profiles.example.toml as the profile template"
    rm -f "$TOML_OUT" "$GS/config/ntrip_profiles.example.toml"
    cp "$REPO_ROOT/config/ntrip_profiles.example.toml" "$TOML_OUT"
    done_ "Template in place; the working tree's profile TOML is not shipped"
elif [[ -f "$TOML_OUT" ]]; then
    if [[ $SCRUB -eq 1 ]]; then
        step "Scrubbing credentials + Windows paths from the shipped profile TOML"
        # Absolute Windows paths -> relative, backslashes -> forward.
        sed -i -E 's|"[A-Za-z]:\\\\[^"]*\\\\([^"\\]+)"|"./\1"|g' "$TOML_OUT"
        # Blank every credential field on every profile. Note the `#`
        # delimiter — the pattern's alternation is full of `|`.
        sed -i -E 's#^(user|password|ssr_user|ssr_password|eph_user|eph_password)[[:space:]]*=.*#\1 = ""#' "$TOML_OUT"
        done_ "Credentials blanked; users fill them in via the GUI"
    else
        warn "--keep-credentials: shipping config/ntrip_profiles.toml verbatim,"
        warn "INCLUDING NTRIP usernames and passwords. Do not publish this bundle."
    fi
fi

# ---- 2c. Project/Manifest without PPPHVA -------------------------------
# The platform loads PPPHVA only when it can be resolved; a bundle without
# it must not list it as a dependency, or Pkg.instantiate on the target
# machine fails on the missing path. Drop it from the staged Project.toml
# and Manifest.toml. With --with-ppphva, pin the Manifest path to the
# staged location instead.
if [[ $WITH_PPPHVA -eq 0 ]]; then
    if grep -q '^PPPHVA[[:space:]]*=' "$GS/Project.toml"; then
        sed -i '/^PPPHVA[[:space:]]*=/d' "$GS/Project.toml"
        done_ "Project.toml: PPPHVA dependency removed from the staged copy"
    fi
    if [[ -f "$GS/Manifest.toml" ]] && grep -q '^\[\[deps\.PPPHVA\]\]' "$GS/Manifest.toml"; then
        awk '
            /^\[\[deps\.PPPHVA\]\]/ { skip = 1; next }
            /^\[/ { skip = 0 }
            skip { next }
            { print }
        ' "$GS/Manifest.toml" > "$GS/Manifest.toml.new" && mv "$GS/Manifest.toml.new" "$GS/Manifest.toml"
        # ... and from the dependency list of GaiaSeis itself.
        sed -i -E '/^deps = \[/ { s/, "PPPHVA"//; s/"PPPHVA", //; s/"PPPHVA"// }' "$GS/Manifest.toml"
        done_ "Manifest.toml: PPPHVA entry removed from the staged copy"
    fi
elif [[ -f "$GS/Manifest.toml" ]]; then
    sed -i -E 's|^path = ".*PPPHVA\.jl"$|path = "../PPPH_VA/PPPHVA.jl"|' "$GS/Manifest.toml"
    done_ "Manifest PPPHVA path pinned to ../PPPH_VA/PPPHVA.jl"
fi

# ---- 3. GaiaVario engine -----------------------------------------------
step "Staging the GaiaVario engine"
GV="$STAGE/GaiaVario.jl"
mkdir -p "$GV"
# The package: sources, tests, replay/analysis tools, project files,
# licence and notices. Two tools are tied to the development installation
# and stay out (same as the public-tree export in tools/export_public.sh).
for d in src test tools; do
    [[ -d "$GAIAVARIO_DIR/$d" ]] && cp -r "$GAIAVARIO_DIR/$d" "$GV/"
done
for f in Project.toml Manifest.toml README.md LICENSE NOTICE.md CHANGELOG.md CITATION.cff CONTRIBUTING.md .zenodo.json; do
    [[ -f "$GAIAVARIO_DIR/$f" ]] && cp "$GAIAVARIO_DIR/$f" "$GV/"
done
[[ -f "$GAIAVARIO_DIR/LICENSE" ]] || warn "GaiaVario.jl/LICENSE is missing — the bundle ships without it"
for r in tools/after_overnight.sh tools/serve_viewer.py; do
    if [[ -e "$GV/$r" ]]; then rm -f "$GV/$r"; warn "Pruned GaiaVario.jl/$r"; fi
done
find "$GV" \( -name '.DS_Store' -o -name 'desktop.ini' -o -name '__pycache__' -o -name 'logs' \) -prune -exec rm -rf {} + 2>/dev/null || true
# GaiaVario's Manifest names the engine API by its development path,
# ../NtripClient.jl/GaiaSeisEngineAPI. In the bundle the repository is
# staged as GaiaSeis/, so point the path there.
if [[ -f "$GV/Manifest.toml" ]]; then
    sed -i -E 's|^path = "\.\./[^/"]+/GaiaSeisEngineAPI"$|path = "../GaiaSeis/GaiaSeisEngineAPI"|' "$GV/Manifest.toml"
    grep -q '^path = "../GaiaSeis/GaiaSeisEngineAPI"' "$GV/Manifest.toml" \
        || die "GaiaVario Manifest: could not pin the GaiaSeisEngineAPI path (edit expected 'path = \"../NtripClient.jl/GaiaSeisEngineAPI\"')"
    done_ "GaiaVario Manifest: GaiaSeisEngineAPI pinned to ../GaiaSeis/GaiaSeisEngineAPI"
else
    warn "GaiaVario.jl has no Manifest.toml — install.sh will resolve it from scratch"
fi
done_ "GaiaVario staged"

# ---- 3b. Optional PPPHVA -----------------------------------------------
if [[ $WITH_PPPHVA -eq 1 ]]; then
    step "Staging PPPHVA (optional engine)"
    mkdir -p "$STAGE/PPPH_VA"
    cp -r "$PPPHVA_DIR" "$STAGE/PPPH_VA/PPPHVA.jl"
    rm -rf "$STAGE/PPPH_VA/PPPHVA.jl/docs/_build"
    find "$STAGE/PPPH_VA" \( -name '.DS_Store' -o -name 'desktop.ini' \) -delete 2>/dev/null || true
    # Embed the GPT3 grid inside the package so PPPHVA's relative fallback
    # path resolves wherever the user installs.
    if [[ -n "$GPT_SRC" ]]; then
        mkdir -p "$STAGE/PPPH_VA/PPPHVA.jl/data"
        cp "$GPT_SRC" "$STAGE/PPPH_VA/PPPHVA.jl/data/gpt3_5.grd"
        done_ "Embedded gpt3_5.grd ($(du -m "$GPT_SRC" | cut -f1) MB)"
    fi
    done_ "PPPHVA staged"
fi

# ---- 4. Installer / launcher / uninstaller / README / licences ---------
step "Staging installer scripts and licence files"
cp "$HERE/install.sh"           "$STAGE/"
cp "$HERE/launch.sh"            "$STAGE/"
cp "$HERE/uninstall.sh"         "$STAGE/"
cp "$HERE/gaiaseis.desktop.in"  "$STAGE/"
cp "$HERE/README_INSTALL.md"    "$STAGE/"
for f in LICENSE NOTICE.md; do
    [[ -f "$REPO_ROOT/$f" ]] && cp "$REPO_ROOT/$f" "$STAGE/"
done
# Optional: the PackageCompiler build kit, for users who want a
# Julia-free binary rather than the script install.
if [[ -d "$HERE/app" ]]; then
    mkdir -p "$STAGE/build-app"
    cp -r "$HERE/app" "$STAGE/build-app/"
    cp "$HERE/build-app.sh" "$HERE/build_app.jl" "$HERE/third-party-licenses.sh" "$STAGE/build-app/"
    chmod +x "$STAGE/build-app/build-app.sh" "$STAGE/build-app/third-party-licenses.sh"
fi
chmod +x "$STAGE/install.sh" "$STAGE/launch.sh" "$STAGE/uninstall.sh"
# Strip CRLFs — the scripts may have been edited on Windows, and a shebang
# line ending in \r makes the kernel report "bad interpreter".
for f in "$STAGE/install.sh" "$STAGE/launch.sh" "$STAGE/uninstall.sh" \
         "$STAGE/build-app/build-app.sh" "$STAGE/build-app/third-party-licenses.sh"; do
    [[ -f "$f" ]] && sed -i 's/\r$//' "$f"
done
done_ "Installer scripts staged"

# ---- 4a. Third-party licences -----------------------------------------
step "Generating THIRD_PARTY_LICENSES.md"
MANIFESTS=("$GS/Manifest.toml")
[[ -f "$GV/Manifest.toml" ]] && MANIFESTS+=("$GV/Manifest.toml")
[[ $WITH_PPPHVA -eq 1 && -f "$STAGE/PPPH_VA/PPPHVA.jl/Manifest.toml" ]] && MANIFESTS+=("$STAGE/PPPH_VA/PPPHVA.jl/Manifest.toml")
bash "$HERE/third-party-licenses.sh" --out "$STAGE/THIRD_PARTY_LICENSES.md" --version "$VERSION" "${MANIFESTS[@]}" \
    || die "third-party licence generation failed"
NSEC="$(grep -c '^### ' "$STAGE/THIRD_PARTY_LICENSES.md" || true)"
[[ "${NSEC:-0}" -gt 0 ]] || die "THIRD_PARTY_LICENSES.md has no package section — is the Julia depot (~/.julia/packages) populated?"
done_ "THIRD_PARTY_LICENSES.md written ($NSEC package sections)"

# ---- 4b. Scratch-file sweep -------------------------------------------
# One pass over the WHOLE staged tree, not just GaiaSeis/ — editor and
# hand-made backups must never ship.  This is a security step, not
# tidiness: a stray config/ntrip_profiles.toml.win.bak carries exactly
# the NTRIP usernames and passwords that step 2b just scrubbed out of
# the live TOML, silently undoing it.
step "Sweeping editor/backup scratch files"
SWEPT=0
while IFS= read -r -d '' f; do
    rm -f "$f"; SWEPT=$((SWEPT + 1))
done < <(find "$STAGE" -type f \( \
        -name '*.bak' -o -name '*.bak[0-9]*' -o -name '*.bak_*' -o -name '*.pre_*' \
        -o -name '*~' -o -name '*.orig' -o -name '*.rej' \
        -o -name '*.swp' -o -name '.DS_Store' -o -name 'desktop.ini' \
    \) -print0)
done_ "Removed $SWEPT scratch file(s)"

# ---- 4c. Credential and site-detail guard -----------------------------
# Some developer scripts under test/ hard-code live caster credentials
# (they exist to hit a real caster).  They are useless to someone
# installing the bundle and must not travel with it, so drop any staged
# script that carries a populated credential rather than trying to
# rewrite it — dropping is the safe direction, and testing the content
# means a newly added script is caught automatically.
#
# Markdown is exempt from the credential pattern: README/MANUAL show
# `password = "secret"` as documentation examples, not secrets.  So is a
# value in angle brackets ("<ntrip user>"), the placeholder form used by
# config/ntrip_profiles.example.toml.
CRED_RE='^[[:space:]]*(user|password|ssr_user|ssr_password|eph_user|eph_password)[[:space:]]*=[[:space:]]*"[^"<][^"]*"'
# Site details of the development installation (receiver/network
# addresses, host name). Nothing in a public bundle may carry them; this
# check covers every file, Markdown included, and fails the build.
SITE_RE='150\.140\.|[Kk][Oo][Ll][Uu][Mm][Bb][Oo]'

if [[ $SCRUB -eq 1 ]]; then
    step "Dropping credential-bearing developer scripts"
    DROPPED=0
    while IFS= read -r f; do
        rm -f "$f"
        warn "Dropped $(realpath --relative-to="$STAGE" "$f") (hard-codes a credential)"
        DROPPED=$((DROPPED + 1))
    done < <(grep -rlE "$CRED_RE" "$STAGE" --exclude='*.md' 2>/dev/null || true)
    done_ "Dropped $DROPPED script(s)"

    # Belt and braces: fail loudly rather than ship a credential by accident.
    LEAK="$(grep -rlE "$CRED_RE" "$STAGE" --exclude='*.md' 2>/dev/null || true)"
    [[ -z "$LEAK" ]] || die "Refusing to pack: credential-bearing file(s) remain:
$LEAK"
    done_ "Verified: no populated credential fields in the staged tree"

    step "Scanning for site details"
    SITE="$(grep -rlIE "$SITE_RE" "$STAGE" 2>/dev/null || true)"
    [[ -z "$SITE" ]] || die "Refusing to pack: file(s) carry site details (address or host name of the development installation).
Clean them in the repository, then rebuild:
$SITE"
    done_ "Verified: no site details in the staged tree"
fi

# ---- 5. Archives -------------------------------------------------------
# Both archive steps run from inside OUT_DIR with relative names: an
# absolute Windows path like C:/… makes GNU tar read the colon as a
# remote host spec, which matters because this script is also cut from
# Git Bash.
if [[ $DO_TAR -eq 1 ]]; then
    step "Compressing to tar.gz"
    TARBALL="$OUT_DIR/$STAGE_NAME.tar.gz"
    rm -f "$TARBALL"
    ( cd "$OUT_DIR" && tar czf "$STAGE_NAME.tar.gz" "$STAGE_NAME" )
    done_ "Wrote $TARBALL ($(du -m "$TARBALL" | cut -f1) MB)"
fi

if [[ $DO_ZIP -eq 1 ]]; then
    step "Compressing to zip"
    command -v zip >/dev/null 2>&1 \
        || die "zip not found. Install it (apt install zip) or use the .tar.gz (drop --zip)."
    ZIPFILE="$OUT_DIR/$STAGE_NAME.zip"
    rm -f "$ZIPFILE"
    # -r recurse, -q quiet, -9 max compression, -X drop extra platform
    # attributes.  Info-ZIP records the unix permission bits, so
    # install.sh / launch.sh / uninstall.sh stay executable after
    # unzip — that is why this does not use python's zipfile.
    ( cd "$OUT_DIR" && zip -r -q -9 -X "$STAGE_NAME.zip" "$STAGE_NAME" )
    done_ "Wrote $ZIPFILE ($(du -m "$ZIPFILE" | cut -f1) MB)"
fi

echo
echo "${C_OK}Done. Staged tree: $STAGE${C_OFF}"
[[ $DO_TAR -eq 1 ]] && echo "${C_OK}Tarball:       $OUT_DIR/$STAGE_NAME.tar.gz${C_OFF}"
[[ $DO_ZIP -eq 1 ]] && echo "${C_OK}Zip:           $OUT_DIR/$STAGE_NAME.zip${C_OFF}"
