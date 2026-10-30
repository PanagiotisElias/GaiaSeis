module GaiaSeisApp

# PackageCompiler entry point for the standalone GaiaSeis binary.
#
# `create_app` compiles this package (and everything it `using`s) into a
# sysimage and emits `bin/gaiaseis`.  Nothing here belongs in GaiaSeis
# proper — it is purely the plumbing a compiled app needs that a
# `julia examples/gui.jl` invocation gets for free:
#
#   * Path roots.  In a compiled app `@__DIR__` points at the build
#     machine, so we pin GaiaSeis's roots explicitly: read-only program
#     data next to the binary, writable state under XDG_STATE_HOME.
#   * Module bindings.  `GaiaSeis.launch_gui` normally does
#     `@eval Main using Gtk4`, which needs a package depot at run time,
#     and the engine loader does `@eval Main using GaiaVario` the same
#     way.  A compiled app has no depot, so we bind the already-compiled
#     Gtk4, Cairo and GaiaVario modules into `Main` ourselves and the lazy
#     paths are skipped.
#   * A blocking main loop, since the process must stay alive until the
#     window closes.

using GaiaSeis
using GaiaVario
using Gtk4
using Cairo

const USAGE = """
gaiaseis — GNSS-based real-time seismogeodesy (variometric engine GaiaVario)

Usage:
  gaiaseis [options]

Options:
  --data-dir <path>   writable state directory (logs, miniSEED, profile
                      TOML). Default: \$XDG_STATE_HOME/gaiaseis
  --root <path>       read-only program data (assets, config template,
                      ANTEX files). Default: <bindir>/../share/gaiaseis
  --version           print the version and exit
  --help              this message

Environment:
  GAIASEIS_DATA_DIR, GAIASEIS_ROOT, GAIASEIS_PROFILES, PPPHVA_GPT3_GRID
"""

_state_home() = get(ENV, "XDG_STATE_HOME", joinpath(homedir(), ".local", "state"))

# Program data ships beside the binary: PackageCompiler lays the app out
# as <app>/bin/gaiaseis, and build-app.sh copies docs/assets, config and
# the ANTEX files into <app>/share/gaiaseis.
_default_root() = normpath(joinpath(Sys.BINDIR, "..", "share", "gaiaseis"))

function _parse_args(args)
    root = get(ENV, "GAIASEIS_ROOT", "")
    data = get(ENV, "GAIASEIS_DATA_DIR", "")
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--help" || a == "-h"
            print(USAGE); return nothing
        elseif a == "--version" || a == "-V"
            println("GaiaSeis ", _version()); return nothing
        elseif a == "--root" && i < length(args)
            root = args[i+1]; i += 2
        elseif a == "--data-dir" && i < length(args)
            data = args[i+1]; i += 2
        else
            println(stderr, "Unknown option: ", a)
            print(stderr, USAGE)
            return :error
        end
    end
    return (root, data)
end

_version() = try
    string(Base.pkgversion(GaiaSeis))
catch
    "0.2.0"
end

function _setup!(root::AbstractString, data::AbstractString)
    root = isempty(root) ? _default_root() : abspath(root)
    isdir(root) || @warn "program data directory not found — logos and the \
                          bundled ANTEX files will be missing" root
    GaiaSeis.set_app_root!(root)

    data = isempty(data) ? joinpath(_state_home(), "gaiaseis") : abspath(data)
    GaiaSeis.set_data_root!(data)
    # Also export it: the roots are pinned in-process, but anything that
    # re-reads the environment (a spawned tool, a debug dump path) agrees.
    ENV["GAIASEIS_ROOT"] = root
    ENV["GAIASEIS_DATA_DIR"] = data
    for sub in ("logs", "config", "mseed2")
        mkpath(joinpath(data, sub))
    end

    # Seed the profile TOML once, then never touch it again — upgrades
    # must not overwrite the user's casters and credentials.
    dst = joinpath(data, "config", "ntrip_profiles.toml")
    src = joinpath(root, "config", "ntrip_profiles.toml")
    if !isfile(dst) && isfile(src)
        cp(src, dst)
        @info "seeded profile config" path=dst
    end

    # GaiaSeis probes for the GPT3 grid in `__init__`, which already ran
    # before we pinned the roots. Point it at the bundled copy and redo
    # the detection.
    if !haskey(ENV, "PPPHVA_GPT3_GRID")
        for cand in (joinpath(root, "data", "gpt3_5.grd"),
                     joinpath(root, "gpt3_5.grd"))
            if isfile(cand)
                ENV["PPPHVA_GPT3_GRID"] = cand
                break
            end
        end
    end
    try
        GaiaSeis._autodetect_gpt3_grid!()
    catch err
        @warn "GPT3 grid detection failed — tropo model falls back" exception=err
    end
    return root, data
end

function _run_gui()
    # Hand the GUI the modules it expects to find in `Main`. Both are
    # already in the sysimage; this only creates the bindings, so the
    # depot-dependent `@eval Main using …` path in `launch_gui` is never
    # taken.
    @eval Main const Gtk4 = $(Gtk4)
    @eval Main const Cairo = $(Cairo)
    # The engine the same way: `_load_engine!` first asks whether the
    # engine is registered, which GaiaVario's `__init__` has done by now,
    # so the `using` fallback is never reached.
    @eval Main const GaiaVario = $(GaiaVario)

    if isempty(get(ENV, "DISPLAY", "")) && isempty(get(ENV, "WAYLAND_DISPLAY", ""))
        @warn "neither DISPLAY nor WAYLAND_DISPLAY is set — GTK4 has no \
               display to open on (try `xvfb-run gaiaseis` on a headless host)"
    end

    win = GaiaSeis.launch_gui()

    # Block the main task on a condition the close handler signals. A
    # sleep loop here would starve the GLib event loop and the window
    # would render blank — same reasoning as examples/gui.jl.
    closed = Base.Event()
    Gtk4.signal_connect(win, "close-request") do _
        notify(closed)
        false          # let the window actually close
    end
    # Gtk4.jl's `__init__` starts the GLib main loop only when
    # `isinteractive()` — a compiled app never is. Without this the window
    # maps and gets a WM frame but never paints a single pixel, so it looks
    # like nothing launched at all. Same fix as examples/gui.jl.
    Gtk4.GLib.is_loop_running() || Gtk4.GLib.start_main_loop(true)

    wait(closed)
    return 0
end

function julia_main()::Cint
    try
        parsed = _parse_args(ARGS)
        parsed === nothing && return 0        # --help / --version
        parsed === :error && return 2
        root, data = _setup!(parsed[1], parsed[2])
        @info "GaiaSeis $(_version())" root data
        return Cint(_run_gui())
    catch err
        @error "GaiaSeis exited with an unhandled error" exception=(err, catch_backtrace())
        return Cint(1)
    end
end

end # module
