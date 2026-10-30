# GUI memory soak: launch the real GUI, start a profile, open the Plot and
# Metrics windows and the web server, and log process memory every 30 s.
#   DISPLAY=:0 PROFILE=UPA10Z LOG=/tmp/gui_soak.log julia -t auto --project=. tools/gui_soak.jl
# Env: PROFILE (default UPA10Z), LOG (default logs/gui_soak_<ts>.log),
#      WEB_PORT (default 8765, 0 = no web server), OPEN_PLOT/OPEN_METRICS (1/0).
using GaiaSeis, Gtk4, Dates, Printf
const G = GaiaSeis
prof_name = get(ENV, "PROFILE", "UPA10Z")
logpath = get(ENV, "LOG", joinpath("logs", "gui_soak_" * Dates.format(now(), "yyyymmdd_HHMMSS") * ".log"))
win = launch_gui()
Gtk4.GLib.is_loop_running() || Gtk4.GLib.start_main_loop(true)
sleep(3)
h = G._GUI_HANDLES[]; state = h[:state]
names = sort!(collect(keys(state[:profiles]))); idx = findfirst(==(prof_name), names)
idx === nothing && error("profile $prof_name not found; have $(names)")
Gtk4.set_gtk_property!(h[:combo], :active, idx - 1); sleep(1)
press(b) = (try; Gtk4.G_.activate(b); catch; Gtk4.signal_emit(b, "clicked", Nothing); end)
press(h[:btn_start]); sleep(3)
get(ENV, "OPEN_PLOT", "1") == "1" && (press(h[:btn_plot]); sleep(2))
get(ENV, "OPEN_METRICS", "1") == "1" && (press(h[:btn_metrics]); sleep(2))
port = parse(Int, get(ENV, "WEB_PORT", "8765"))
port > 0 && (G._start_plot_web_server(port, state, G.PlotSettings()); println("web on $port"))
rss() = round(Int, parse(Int, split(read("/proc/self/statm", String))[2]) * 4096 / 1_048_576)
heapmb() = try; parse(Int, first(m.captures[1] for m in eachmatch(r"\[heap\]\n(?:.*\n){1,3}?Rss:\s+(\d+)", read("/proc/self/smaps", String)))) ÷ 1024; catch; -1; end
open(logpath, "w") do io
    println(io, "# GUI soak  profile=$prof_name  gc_pacing=$(get(ENV,"GAIASEIS_GC_PACING","0"))  plot=$(get(ENV,"OPEN_PLOT","1")) metrics=$(get(ENV,"OPEN_METRICS","1")) web=$port  started $(now())")
    println(io, "t_s,rss_mb,heap_mb,gc_live_mb,full_sweeps,maxrss_mb,epochs,nsat")
    t0 = time()
    while true
        sleep(30)
        s = state[:session]
        @printf(io, "%d,%d,%d,%d,%d,%d,%d,%d\n", round(Int, time() - t0), rss(), heapmb(), round(Int, Base.gc_live_bytes()/1e6), Base.gc_num().full_sweep, round(Int, Sys.maxrss()/1e6),
                s === nothing ? 0 : s.stats.input_epochs, s === nothing ? 0 : s.stats.last_epoch_nsat); flush(io)
    end
end
