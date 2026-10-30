module GaiaSeis
# GaiaSeis — GNSS-based Real-time Seismogeodesy
# Deforming Gaia Lab, Department of Geology, University of Patras, Greece
# (formerly: NtripClient.jl)

using Base64
using Dates
using HTTP
using LinearAlgebra
using Printf
using Sockets
using TOML
using GaiaSeisEngineAPI

# Core types and state — defined before sub-modules use them.
include("paths.jl")            # app_root()/data_root() — must precede config.jl
include("types.jl")
include("pstruct.jl")          # dynamic structs of the bridge; optional PPPHVA
include("config.jl")           # NTRIP profile + TOML I/O

# RTCM stack
include("RTCM/bitreader.jl")
include("RTCM/crc24q.jl")
include("RTCM/frame.jl")
include("RTCM/messages_station.jl")
include("RTCM/messages_msm7.jl")
include("RTCM/messages_ephemeris.jl")
include("RTCM/messages_ssr.jl")
include("RTCM/decoder.jl")

# NTRIP transport
include("ntrip.jl")

# miniSEED writer (direct .mseed sink — alongside the CSV sink for the
# Python `seedlink_integration.py` agent).
include("miniseed.jl")
include("datalink.jl")         # DataLink push to ringserver (SeedLink service)

# Engine plug-ins and the bridge (epoch grouping, gates, sinks)
include("engine_api.jl")       # engine plug-ins (GaiaSeisEngineAPI) — before the bridge
include("bridge.jl")

# Top-level session orchestrator
include("session.jl")

# Diagnostic dump (used by the GUI's Debug window)
include("diagnostics.jl")

# GUI — included unconditionally so it precompiles in the same world as the
# launch_gui entry point. The body references `Main.Gtk4` only at call time,
# so the `using Gtk4` happens lazily in `launch_gui`.
include("GUI/gui.jl")
include("GUI/metrics.jl")
include("GUI/health.jl")      # system sampler + Health panel
include("GUI/causes.jl")      # cause log + Causes panel

export NtripProfile, load_profiles, save_profiles, default_profile,
       NtripSession, start!, stop!, flush_session_data!, isrunning,
       SessionStats, profiles_path,
       launch_gui, diagnostic_dump,
       app_root, data_root, set_app_root!, set_data_root!

"""
    launch_gui(; profiles_path = default_profiles_path())

Open the Gtk4 configuration / streaming GUI. Requires `Gtk4` to be installed.
The same TOML file is read/written by both this GUI and any CLI usage.
"""
# Verify GTK4 actually initialised before any widget is constructed.
#
# Gtk4.jl records the result of `gtk_init_check()` in `Gtk4.initialized[]`
# and, when it fails, only emits a @warn — then returns. Nothing stops the
# caller from building a widget anyway, and GTK4 dereferences a null default
# display deep in its CSS machinery when you do: the process dies with
# SIGSEGV inside `gtk_style_provider_get_settings`, dumps core, and leaves no
# Julia-level error to act on. That is what `launch.sh` with no DISPLAY did.
#
# `Gtk4.isinitialized()` cannot be used here — it calls `gtk_is_initialized()`,
# which returns true even after a failed `gtk_init_check()`.
function _assert_gtk_display(Gtk4mod)
    ok = try
        Gtk4mod.initialized[]::Bool
    catch
        # A Gtk4.jl without that internal binding: fall back to asking
        # whether there is any display to open at all.
        !(isempty(get(ENV, "DISPLAY", "")) && isempty(get(ENV, "WAYLAND_DISPLAY", "")))
    end
    ok && return nothing

    disp = get(ENV, "DISPLAY", "")
    wl   = get(ENV, "WAYLAND_DISPLAY", "")
    error("""
    GTK4 could not open a display — the GaiaSeis GUI cannot start.
      DISPLAY=$(isempty(disp) ? "(unset)" : disp)  \
    WAYLAND_DISPLAY=$(isempty(wl) ? "(unset)" : wl)

    Creating a window in this state would crash the process, so GaiaSeis
    stops here instead. Options:

      over SSH       reconnect with `ssh -X` (or `ssh -Y`), then retry
      headless host  run under a virtual X server: `xvfb-run -a <command>`
      Wayland only   install XWayland so GTK can fall back to X11
      no GUI needed  streaming does not require the GUI — drive a session
                     directly with NtripSession/start!, or see
                     examples/headless_stream.jl

    To check the install without a display, use: launch.sh --check
    """)
end

function launch_gui(; profiles_path::AbstractString = default_profiles_path())
    if !isdefined(Main, :Gtk4)
        @eval Main using Gtk4
    end
    # Must come before ANY widget is constructed — see _assert_gtk_display.
    _assert_gtk_display(Main.Gtk4)
    # Gtk4 re-exports the Cairo drawing primitives (move_to/line_to/stroke/…)
    # but NOT the font helpers (select_font_face/set_font_size/show_text).
    # Cairo is a transitive dep of Gtk4 so it is already loaded, but we can't
    # `using Cairo` here (GaiaSeis does not depend on it directly). Locate
    # the already-loaded module via `Base.loaded_modules` and bind it in Main.
    if !isdefined(Main, :Cairo)
        for (id, m) in Base.loaded_modules
            if id.name == "Cairo"
                @eval Main const Cairo = $m
                break
            end
        end
        isdefined(Main, :Cairo) || error("Cairo module not found among loaded packages; " *
                                          "the plot draw needs it for font primitives.")
    end
    return Base.invokelatest(_launch_gui_impl, profiles_path)
end

# Runs every time GaiaSeis is loaded (not just during precompile). This is
# where we re-set PPPHVA's GPT3 grid-file path, because PPPHVA holds it in a
# `Ref{String}` whose value is reset by the precompile cache.
function __init__()
    _init_ppphva!()            # optional PPPHVA (engine "ppphva"); no-op when absent
    # Drain miniSEED/log sinks on exit, Ctrl-C and SIGTERM (all of which run
    # atexit hooks) so a shutdown that never reaches `stop!` still lands the
    # buffered tail on disk.
    _install_shutdown_hooks!()
    return nothing
end

end # module
