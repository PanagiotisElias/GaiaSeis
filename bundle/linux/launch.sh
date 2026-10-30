#!/usr/bin/env bash
# GaiaSeis launcher (Linux).
#
# Lives at the root of the installed tree, next to GaiaSeis/ (the
# platform) and GaiaVario.jl/ (the displacement engine).  Run it from a
# terminal, from the desktop menu entry, or via the `gaiaseis` symlink
# install.sh drops into ~/.local/bin.
#
# Unlike the Windows launch.bat, the program directory is treated as
# read-only: logs, miniSEED output and the live profile TOML go to
#   ${XDG_STATE_HOME:-$HOME/.local/state}/gaiaseis
# which survives a reinstall.  GAIASEIS_DATA_DIR overrides it.
#
# Usage:
#   ./launch.sh            open the GUI
#   ./launch.sh --repl     keep an interactive Julia REPL alive alongside
#                          it (the Windows launcher's `-i` behaviour)
#   ./launch.sh --check    load the package headlessly and exit — a
#                          smoke test that needs no display
#
# The console (stdout + stderr) is mirrored to
#   ${GAIASEIS_DATA_DIR}/logs/console_<timestamp>.log
# so a crash or a GUI freeze leaves its backtrace behind after the
# terminal scrollback has rolled over.  Set GAIASEIS_CONSOLE_LOG=0 to
# disable.  Not done for --repl, where a piped stdout would cost you
# line editing in the REPL.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$HERE/GaiaSeis"
ENGINE_DIR="$HERE/GaiaVario.jl"

if [[ ! -f "$PROJECT_DIR/Project.toml" ]]; then
    echo "Could not find Project.toml at $PROJECT_DIR." >&2
    echo "The install layout looks broken — re-run install.sh." >&2
    exit 1
fi
if [[ ! -f "$ENGINE_DIR/Project.toml" ]]; then
    echo "Could not find the GaiaVario engine at $ENGINE_DIR." >&2
    echo "The install layout looks broken — re-run install.sh." >&2
    exit 1
fi

JULIA="${JULIA:-julia}"
command -v "$JULIA" >/dev/null 2>&1 || {
    echo "julia not found on PATH. Install it with:" >&2
    echo "    curl -fsSL https://install.julialang.org | sh" >&2
    exit 1
}

# ---- Read-only program root -------------------------------------------
export GAIASEIS_ROOT="$PROJECT_DIR"

# ---- Engine on the load path ------------------------------------------
# The displacement engine is a separate package beside GaiaSeis/, loaded
# by name (`using GaiaVario`) when a profile selects engine = "gaiavario".
# Putting its directory on the Julia load path makes that work without
# installing it into the project; `@` is the --project environment below.
# A profile may still name another checkout through its `engine_path`.
export JULIA_LOAD_PATH="@:$ENGINE_DIR:@v#.#:@stdlib"

# ---- Writable state ----------------------------------------------------
: "${GAIASEIS_DATA_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/gaiaseis}"
export GAIASEIS_DATA_DIR
mkdir -p "$GAIASEIS_DATA_DIR/logs" "$GAIASEIS_DATA_DIR/config" "$GAIASEIS_DATA_DIR/mseed2"

# Seed the profile TOML from the shipped template on first run only —
# after that the user's edits are theirs and an upgrade must not stomp them.
if [[ ! -f "$GAIASEIS_DATA_DIR/config/ntrip_profiles.toml" && \
      -f "$PROJECT_DIR/config/ntrip_profiles.toml" ]]; then
    cp "$PROJECT_DIR/config/ntrip_profiles.toml" "$GAIASEIS_DATA_DIR/config/"
    echo "Seeded profile config at $GAIASEIS_DATA_DIR/config/ntrip_profiles.toml"
fi

# ---- Optional PPPHVA engine --------------------------------------------
# Not part of the public bundle. When a bundle was made with --with-ppphva
# the package sits at PPPH_VA/PPPHVA.jl beside GaiaSeis/, where the
# platform finds it on its own; only its tropospheric grid needs pointing
# at. Nothing here runs when the directory is absent.
if [[ -z "${PPPHVA_GPT3_GRID:-}" && -f "$HERE/PPPH_VA/PPPHVA.jl/data/gpt3_5.grd" ]]; then
    export PPPHVA_GPT3_GRID="$HERE/PPPH_VA/PPPHVA.jl/data/gpt3_5.grd"
fi

# ---- Mode --------------------------------------------------------------
case "${1:-}" in
    --check)
        exec "$JULIA" --project="$PROJECT_DIR" \
             -e 'using GaiaSeis; using GaiaVario; println("GaiaSeis loads OK — root=", GaiaSeis.app_root(), " data=", GaiaSeis.data_root(), " engines=", join(string.(GaiaSeis.available_engine_names()), ","))'
        ;;
    --repl)  INTERACTIVE=(-i); DO_CONSOLE_LOG=0 ;;
    "")      INTERACTIVE=();   DO_CONSOLE_LOG=1 ;;
    *)
        echo "Unknown option: $1  (expected --repl, --check, or nothing)" >&2
        exit 2
        ;;
esac

# ---- Display check -----------------------------------------------------
# Hard failure, not a warning.  GTK4 dereferences a null default display
# while building its first widget, so continuing here means SIGSEGV and a
# core dump instead of a diagnosable error.  GaiaSeis refuses the same way
# from the Julia side (`_assert_gtk_display`); this check just saves the
# ~15 s of Julia startup before saying so.
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    cat >&2 <<'NODISPLAY'
Error: neither DISPLAY nor WAYLAND_DISPLAY is set, so GTK4 has no display
to open and the GUI cannot start.

  over SSH       reconnect with `ssh -X` (or `ssh -Y`), then retry
  headless host  run under a virtual X server: `xvfb-run -a ./launch.sh`
  Wayland only   install XWayland so GTK can fall back to X11

Neither is needed to record data: `./launch.sh --check` verifies the
install headlessly, and a session can be driven from Julia directly
(see examples/headless_stream.jl).
NODISPLAY
    exit 1
fi

# `-t auto` = all CPU threads; the decoder and bridge both benefit on
# multi-stream profiles.
# ---- Console log -------------------------------------------------------
# A GUI callback that throws prints its backtrace to stderr and nowhere
# else.  On a session that runs for days the terminal scrollback has long
# since rolled over by the time anyone looks.  Mirror the console to a
# file so the evidence survives.
#
# `exec > >(tee ...)` rather than a trailing `| tee`: it preserves the
# `exec` handoff below, so Julia still replaces this shell rather than
# running as its child, and the exit status stays Julia's, not tee's.
if [[ "${DO_CONSOLE_LOG:-0}" == "1" && "${GAIASEIS_CONSOLE_LOG:-1}" != "0" ]]; then
    CONSOLE_LOG="$GAIASEIS_DATA_DIR/logs/console_$(date +%Y%m%d_%H%M%S).log"
    # Cap the total at 20: drop all but the newest 19 before adding this
    # run's file. One log per launch would otherwise accumulate forever on
    # a machine that restarts the app often.
    # The trailing `|| true` is load-bearing: on the FIRST launch the glob
    # matches nothing, `ls` exits 2, and `set -e` + `pipefail` would abort
    # the launcher before it ever starts Julia.
    ls -1t "$GAIASEIS_DATA_DIR"/logs/console_*.log 2>/dev/null \
        | tail -n +20 | xargs -r rm -f || true
    echo "Console log: $CONSOLE_LOG"
    exec > >(tee -a "$CONSOLE_LOG") 2>&1
fi

cd "$GAIASEIS_DATA_DIR"
# Memory control for the 10 Hz per-epoch allocation churn. Two levers:
#  - MALLOC_ARENA_MAX caps glibc malloc arenas. Julia runs many threads and
#    glibc gives each its own arena (default 8*ncpu), which fragment under
#    high alloc rate so freed pages never return to the OS — RSS balloons
#    even though Julia's GC is reclaiming. Capping to 2 arenas removes that.
#  - --heap-size-hint makes Julia's own GC trigger as RSS nears the hint.
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
HEAP_HINT="${GAIASEIS_HEAP_HINT:-8G}"
exec "$JULIA" -t auto --heap-size-hint="$HEAP_HINT" --project="$PROJECT_DIR" "${INTERACTIVE[@]+"${INTERACTIVE[@]}"}" \
     "$PROJECT_DIR/examples/gui.jl"
