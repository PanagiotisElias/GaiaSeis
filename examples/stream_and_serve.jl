# Headless runner: start the NTRIP stream AND the web interface in one
# process, no Gtk window. The browser page is the UI — same five plot
# panels and the miniSEED file browser the desktop Plot window serves.
#
#   julia --project=. examples/stream_and_serve.jl [port] [profile]
#
# Defaults to port 8765 and the TOML's `active` profile. Ctrl-C stops the
# stream and drains the sinks; a `kill` is safe too (the atexit hook in
# GaiaSeis.__init__ flushes the buffered miniSEED tail either way).

using GaiaSeis
using Gtk4          # pulls in the Cairo primitives the panel renderer needs
using Dates

const G = GaiaSeis

# Rendering, the RTCM decoder and the engine bridge (the displacement engine
# is a plug-in, GaiaVario by default) all share the Julia scheduler. A panel render is CPU-bound with no yield points, so on one
# thread a slow redraw stalls the decoder — very visible at 10 Hz with a
# long plot span. `-t auto` moves that work off the bridge's thread.
if Threads.nthreads() == 1
    @warn "running single-threaded — at 10 Hz the plot redraw competes with " *
          "the decoder. Relaunch with `julia -t auto --project=. ...` for " *
          "smoother plots and steadier decoding."
end

# The plot/web code resolves Cairo and Gtk4 through `Main`, exactly as
# `launch_gui` sets them up. Mirror that here so no GUI is required.
isdefined(Main, :Gtk4) || @eval Main const Gtk4 = $(Gtk4)
if !isdefined(Main, :Cairo)
    for (id, m) in Base.loaded_modules
        if id.name == "Cairo"
            @eval Main const Cairo = $m
            break
        end
    end
end
isdefined(Main, :Cairo) || error("Cairo not found among loaded modules")

# Port: first argument, else $GAIASEIS_WEB_PORT (for launchers that cannot
# pass arguments, e.g. tools/run_gui_watched.sh), else 8765.
port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) :
       parse(Int, get(ENV, "GAIASEIS_WEB_PORT", "8765"))
active, profiles = G.load_profiles()
name = length(ARGS) >= 2 ? ARGS[2] : active
if !haskey(profiles, name)
    error("no such profile: " * name * " (have: " * join(sort(collect(keys(profiles))), ", ") * ")")
end
profile = profiles[name]

println("profile   : ", name)
println("obs       : ", profile.caster, ":", profile.port, "/", profile.mountpoint)
profile.use_ssr && !isempty(profile.ssr_caster) &&
    println("ssr       : ", profile.ssr_caster, ":", profile.ssr_port, "/", profile.ssr_mountpoint)
println("mseed dir : ", isempty(profile.miniseed_mseed_dir) ? "(disabled)" : abspath(profile.miniseed_mseed_dir))

session = G.NtripSession(profile)
G.start!(session)

state    = Dict{Symbol,Any}(:session => session)
# Saved plot settings (config/plot_settings.toml): the web page opens with
# the span, filters and cause view the desktop Plot window last used.
settings = G._load_plot_settings!(G.PlotSettings())
srv      = G._start_plot_web_server(port, state, settings)
lan      = G._primary_lan_ip()
println("web       : http://", lan, ":", port, "/   (also http://127.0.0.1:", port, "/)")
println()

try
    while true
        st = session.stats
        age = st.last_obs_byte_at == DateTime(0) ? Inf :
              Dates.value(Dates.now(Dates.UTC) - st.last_obs_byte_at) / 1000
        println("[", Dates.format(Dates.now(), "HH:MM:SS"), "] ",
                "bytes=", st.bytes_received,
                " frames=", st.frames_total,
                " badCRC=", st.frames_crc_failed,
                " nsat=", st.last_epoch_nsat,
                " sod=", round(st.last_epoch_sod, digits = 1),
                " sigma=", round(st.last_residual_m, digits = 4),
                " rx_age=", age === Inf ? "—" : string(round(age, digits = 1), "s"),
                " reconn=", st.reconnects_obs)
        flush(stdout)
        sleep(5)
    end
catch err
    err isa InterruptException || rethrow()
finally
    println("\nstopping…")
    try; close(srv); catch; end
    G.stop!(session)
    println("stopped — sinks drained.")
end
