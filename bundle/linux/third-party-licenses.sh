#!/usr/bin/env bash
# third-party-licenses.sh — write THIRD_PARTY_LICENSES.md for a GaiaSeis bundle.
#
# Reads one or more Julia Manifest.toml files and, for every package that
# has a source checkout in the Julia depot (~/.julia/packages/<Name>/<slug>/),
# copies its LICENSE file into a section of the output.  Standard-library
# packages get a one-line entry; the Julia runtime, the GTK stack and
# ringserver get fixed sections because they are not Julia packages.
#
# Usage:
#   third-party-licenses.sh --out <file> --version <gaiaseis-version> \
#                           [--depot <dir>] [--stdlib <dir>] <Manifest.toml>...
#
# Needs bash, awk, coreutils.  Julia is used only to find the stdlib
# directory when --stdlib is not given; without Julia on PATH the stdlib
# check falls back to a name list.

set -euo pipefail

OUT=""
VERSION=""
DEPOT="${JULIA_DEPOT_PATH:-}"
DEPOT="${DEPOT%%:*}"
DEPOT="${DEPOT:-$HOME/.julia}"
STDLIB=""
MANIFESTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)       OUT="$2"; shift 2 ;;
        --out=*)     OUT="${1#*=}"; shift ;;
        --version)   VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --depot)     DEPOT="$2"; shift 2 ;;
        --depot=*)   DEPOT="${1#*=}"; shift ;;
        --stdlib)    STDLIB="$2"; shift 2 ;;
        --stdlib=*)  STDLIB="${1#*=}"; shift ;;
        -h|--help)   sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *)  MANIFESTS+=("$1"); shift ;;
    esac
done

[[ -n "$OUT" ]]              || { echo "--out is required" >&2; exit 2; }
[[ -n "$VERSION" ]]          || { echo "--version is required" >&2; exit 2; }
[[ ${#MANIFESTS[@]} -gt 0 ]] || { echo "at least one Manifest.toml is required" >&2; exit 2; }

warn() { echo "    $*" >&2; }

# Standard-library directory of the Julia on PATH (upgradable stdlibs such
# as Statistics may ALSO live in the depot; the depot copy wins below, so
# their licence text is included rather than summarised).
if [[ -z "$STDLIB" ]]; then
    JULIA="${JULIA:-julia}"
    if command -v "$JULIA" >/dev/null 2>&1; then
        STDLIB="$("$JULIA" --startup-file=no -e 'print(Sys.STDLIB)' 2>/dev/null || true)"
    fi
fi
STDLIB_NAMES=" ArgTools Artifacts Base64 CRC32c CompilerSupportLibraries_jll Dates DelimitedFiles \
Distributed Downloads FileWatching Future GMP_jll InteractiveUtils JuliaSyntaxHighlighting LLD_jll \
LLVMLibUnwind_jll LazyArtifacts LibCURL LibCURL_jll LibGit2 LibGit2_jll LibSSH2_jll LibUV_jll \
LibUnwind_jll Libdl LinearAlgebra Logging MPFR_jll Markdown Mmap MozillaCACerts_jll NetworkOptions \
OpenBLAS_jll OpenLibm_jll OpenSSL_jll PCRE2_jll Pkg Printf Profile REPL Random SHA Serialization \
SharedArrays Sockets SparseArrays Statistics StyledStrings SuiteSparse SuiteSparse_jll TOML Tar Test \
UUIDs Unicode Zlib_jll dSFMT_jll libLLVM_jll libblastrampoline_jll nghttp2_jll p7zip_jll "

is_stdlib() {
    local name="$1"
    if [[ -n "$STDLIB" && -d "$STDLIB" ]]; then
        [[ -d "$STDLIB/$name" ]]
    else
        [[ "$STDLIB_NAMES" == *" $name "* ]]
    fi
}

# ---- 1. Collect name<TAB>version<TAB>kind from the manifests -------------
# kind: "path" for path-local packages (GaiaSeis itself, its engine API, an
# engine checkout) which are not third party, "pkg" otherwise.
collect() {
    awk '
        /^\[\[deps\.[^]]+\]\]/ {
            flush()
            name = $0; sub(/^\[\[deps\./, "", name); sub(/\]\].*$/, "", name)
            ver = ""; kind = "pkg"; next
        }
        /^[[:space:]]*version[[:space:]]*=/ {
            v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v); ver = v; next
        }
        /^[[:space:]]*path[[:space:]]*=/ { kind = "path"; next }
        /^\[/ { flush() }
        function flush() { if (name != "") { printf "%s\t%s\t%s\n", name, ver, kind; name = "" } }
        END { flush() }
    ' "$1"
}

ENTRIES="$(for m in "${MANIFESTS[@]}"; do
    [[ -f "$m" ]] || { warn "manifest not found: $m"; continue; }
    collect "$m"
done | sort -u -t$'\t' -k1,1 -k2,2)"

# ---- 2. Locate a package's source in the depot ---------------------------
# ~/.julia/packages/<Name>/<slug>/ — several slugs may exist (several
# versions installed); pick the one whose Project.toml carries the
# manifest's version.
find_source() {
    local name="$1" ver="$2" d pv
    [[ -d "$DEPOT/packages/$name" ]] || return 1
    for d in "$DEPOT/packages/$name"/*/; do
        [[ -f "$d/Project.toml" ]] || continue
        pv="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$d/Project.toml" | head -1)"
        if [[ "$pv" == "$ver" ]]; then printf '%s' "${d%/}"; return 0; fi
    done
    return 1
}

find_license_file() {
    local d="$1" f
    for f in LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md LICENSE.rst COPYING COPYING.md; do
        [[ -f "$d/$f" ]] && { printf '%s' "$d/$f"; return 0; }
    done
    return 1
}

# ---- 3. Write the document ----------------------------------------------
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
cat <<EOF
# Third-party licences — GaiaSeis $VERSION (Linux bundle)

GaiaSeis
Copyright (C) 2026 Panagiotis Elias, Deforming Gaia Lab, Department of Geology, University of Patras

GaiaSeis is free software, licensed under the GNU Affero General Public
License, version 3 only (AGPL-3.0-only); see the file \`LICENSE\` at the root
of this bundle. The GaiaVario engine (directory \`GaiaVario.jl/\`) is released
under the licence in \`GaiaVario.jl/LICENSE\`. The documents under
\`GaiaSeis/docs/\` are licensed separately (CC BY-NC 4.0, see
\`GaiaSeis/docs/LICENSE-DOCS\`).

**Source offer.** The complete corresponding source of this bundle is the
tagged release v$VERSION at https://github.com/PanagiotisElias/GaiaSeis and
https://github.com/PanagiotisElias/GaiaVario.jl

This bundle installs, or causes the Julia package manager to install, the
third-party software listed below. Each section reproduces the licence file
that ships with the package, as found in the Julia package depot at the time
the bundle was made. The Julia packages themselves are **not** copied into the
bundle: \`install.sh\` resolves them from the versions pinned in
\`GaiaSeis/Manifest.toml\` and \`GaiaVario.jl/Manifest.toml\`.

## Contents

1. Julia runtime
2. GTK 4, GLib, Cairo, Pango (shared libraries)
3. ringserver (installed separately, not bundled)
4. Julia standard library
5. Julia packages

---

## 1. Julia runtime

The Julia language and runtime: MIT licence (with the exceptions for bundled
third-party components listed there).
https://github.com/JuliaLang/julia/blob/master/LICENSE.md

Julia is not part of this bundle; it is installed by the user.

## 2. GTK 4, GLib, Cairo, Pango

The graphical interface uses GTK 4 together with GLib, Cairo and Pango.
These libraries are licensed under the GNU Lesser General Public License,
version 2.1 or later (LGPL-2.1-or-later). They are dynamically linked and are
obtained either from the operating system or from the Julia JLL packages used
by Gtk4.jl (\`GTK4_jll\`, \`Glib_jll\`, \`Cairo_jll\`, \`Pango_jll\` and their
dependencies, listed with their licence files in section 5). Their source code
is available from https://gitlab.gnome.org/GNOME/ and
https://www.cairographics.org/ ; the JLL builds come from
https://github.com/JuliaBinaryWrappers/ and https://github.com/JuliaPackaging/Yggdrasil .

## 3. ringserver

The optional SeedLink service uses ringserver by EarthScope (formerly IRIS),
licensed under the Apache License, Version 2.0
(https://github.com/EarthScope/ringserver). ringserver is **not** included in
this bundle; \`GaiaSeis/tools/ringserver/install.sh\` downloads and builds it
separately when the user asks for the SeedLink service.

## 4. Julia standard library

The following packages are part of the Julia standard library and are
covered by the Julia licence (MIT), https://github.com/JuliaLang/julia/blob/master/LICENSE.md :

EOF

STD_LINES=""
PKG_LINES=""
MISSING=""
while IFS=$'\t' read -r name ver kind; do
    [[ -n "$name" ]] || continue
    [[ "$kind" == "path" ]] && continue
    if src="$(find_source "$name" "$ver")"; then
        PKG_LINES+="$name"$'\t'"$ver"$'\t'"$src"$'\n'
    elif is_stdlib "$name"; then
        STD_LINES+="- $name $ver — Julia standard library — MIT"$'\n'
    else
        MISSING+="- $name $ver"$'\n'
    fi
done <<< "$ENTRIES"

printf '%s' "$STD_LINES"
echo

if [[ -n "$MISSING" ]]; then
    cat <<EOF
### Packages whose source was not in the depot when this file was made

The licence text of these packages could not be copied; it is available in
the package's repository as listed in the Julia General registry
(https://github.com/JuliaRegistries/General).

$MISSING
EOF
fi

echo "## 5. Julia packages"
echo
echo "Package name, version pinned by the Manifest, and the licence file as"
echo "shipped with that version."
echo
N=0
while IFS=$'\t' read -r name ver src; do
    [[ -n "$name" ]] || continue
    N=$((N + 1))
    echo "### $name $ver"
    echo
    if lf="$(find_license_file "$src")"; then
        echo "Licence file: \`$(basename "$lf")\`"
        echo
        echo '```'
        sed 's/\r$//' "$lf"
        echo '```'
    else
        echo "No licence file was found in the package source; see the package"
        echo "repository as listed in the Julia General registry."
        warn "no LICENSE file in $src"
    fi
    echo
done <<< "$PKG_LINES"
} > "$TMP"

mv "$TMP" "$OUT"
chmod 644 "$OUT"     # mktemp creates 0600; the file is meant to be read
trap - EXIT
echo "    THIRD_PARTY_LICENSES: $(grep -c '^### ' "$OUT") package sections -> $OUT"
