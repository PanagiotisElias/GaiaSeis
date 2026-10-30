# ---------------------------------------------------------------------------
# Health panel: what on this machine could delay or lose epochs.
#
# A sampler task on the worker pool reads /proc every 2 s: CPU split between
# this GaiaSeis process, other GaiaSeis processes, everything else and idle;
# I/O wait; load average; memory and swap; disk throughput (whole machine and
# this process); Julia GC pause share. `_draw_health` renders bars from the
# latest sample, a short history, the current delay chain (arrival, solve,
# miniSEED on disk, miniSEED → live client) and a list of warnings.
# ---------------------------------------------------------------------------

mutable struct SysSample
    t::Float64                 # wall time (time())
    ncores::Int
    cpu_self::Float64          # % of the whole machine (0-100)
    cpu_gaia_other::Float64
    cpu_others::Float64
    cpu_iowait::Float64
    cpu_idle::Float64
    load1::Float64
    mem_total_mb::Float64
    mem_avail_mb::Float64
    swap_used_mb::Float64
    disk_read_mbs::Float64     # whole machine
    disk_write_mbs::Float64
    self_read_mbs::Float64     # this process
    self_write_mbs::Float64
    gc_pct::Float64            # share of wall time in GC pauses (this process)
    gaia_procs::Vector{Tuple{String,Float64,Float64}}   # (label, cpu %, rss MB) incl. self first
    top_others::Vector{Tuple{String,Float64}}           # (label, cpu %) heaviest non-GaiaSeis processes
end

const _SYS_LOCK   = ReentrantLock()
const _DEGRADE_SESS = Ref{Any}(nothing)     # session the status endpoint reports on
# (wall time, cumulative backpressure skips) samples of the last 60 s, so the
# note can say how many epochs the overload cost recently.
const _SKIP_RING = NTuple{2,Float64}[]
function _skips_last_60s(sess)
    sess === nothing && return 0
    now = time(); cum = Float64(sess.stats.epochs_skipped_backpressure)
    lock(_SYS_LOCK) do
        (isempty(_SKIP_RING) || now - _SKIP_RING[end][1] >= 0.5) && push!(_SKIP_RING, (now, cum))
        while length(_SKIP_RING) > 1 && now - _SKIP_RING[1][1] > 60.0; popfirst!(_SKIP_RING); end
        # a new session restarts the counter
        _SKIP_RING[1][2] > cum && (empty!(_SKIP_RING); push!(_SKIP_RING, (now, cum)))
        return round(Int, cum - _SKIP_RING[1][2])
    end
end
const _SYS_LATEST = Ref{Union{SysSample,Nothing}}(nothing)
const _SYS_HIST   = SysSample[]                       # last _SYS_HIST_S seconds
const _SYS_HIST_S = 600.0
const _SYS_STARTED = Threads.Atomic{Bool}(false)
const _SYS_PERIOD_S = 2.0

_read_first_line(path) = try; open(path) do io; readline(io); end; catch; ""; end

# /proc/stat aggregate cpu line → (busy_ticks, iowait_ticks, idle_ticks, total_ticks)
function _cpu_ticks()
    l = _read_first_line("/proc/stat")
    f = split(l)
    (length(f) < 8 || f[1] != "cpu") && return (0, 0, 0, 0)
    v = [parse(Int, x) for x in f[2:min(end, 9)]]
    while length(v) < 8; push!(v, 0); end
    user, nice, sys, idle, iow, irq, sirq, steal = v[1:8]
    busy = user + nice + sys + irq + sirq + steal
    return (busy, iow, idle, busy + iow + idle)
end

# All processes: pid => (ticks, rss_kb); reads /proc/<pid>/stat only.
function _proc_ticks()
    out = Dict{Int,Tuple{Int,Int}}()
    for d in readdir("/proc")
        pid = tryparse(Int, d); pid === nothing && continue
        l = _read_first_line("/proc/$d/stat"); isempty(l) && continue
        # fields after the ")" of comm: state ppid ... utime(14) stime(15) ... rss(24)
        k = findlast(')', l); k === nothing && continue
        f = split(l[k+1:end])
        length(f) < 22 && continue
        ut = tryparse(Int, f[12]); st = tryparse(Int, f[13]); rss = tryparse(Int, f[22])
        (ut === nothing || st === nothing) && continue
        out[pid] = (ut + st, rss === nothing ? 0 : rss * 4)   # pages → kB (4 kB pages)
    end
    return out
end

function _proc_label(pid::Int)
    cmd = try; replace(read("/proc/$pid/cmdline", String), '\0' => ' '); catch; ""; end
    isempty(cmd) && return (_read_first_line("/proc/$pid/comm"), false)
    # A GaiaSeis process is a julia running from the GaiaSeis tree (the GUI,
    # realtime.jl, headless sessions) — not the shell wrappers around them.
    exe = basename(String(first(split(strip(cmd)))))
    gaia = startswith(exe, "julia") &&
           (occursin("GaiaSeis", cmd) || occursin("NtripClient", cmd) || occursin("realtime.jl", cmd))
    # short label: the script name if a julia/python process, else the command
    parts = split(strip(cmd))
    lab = basename(String(parts[1]))
    for p in parts[2:end]
        if endswith(p, ".jl") || endswith(p, ".py") || endswith(p, ".sh")
            lab = basename(String(p)); break
        end
    end
    return (lab, gaia)
end

function _diskstats()
    r = 0; w = 0
    try
        for l in eachline("/proc/diskstats")
            f = split(l); length(f) < 14 && continue
            name = f[3]
            occursin(r"^(sd[a-z]+|vd[a-z]+|nvme\d+n\d+|mmcblk\d+|xvd[a-z]+)$", name) || continue
            r += parse(Int, f[6]); w += parse(Int, f[10])      # sectors read / written
        end
    catch; end
    return (r * 512, w * 512)
end
function _self_io()
    r = 0; w = 0
    try
        for l in eachline("/proc/self/io")
            startswith(l, "read_bytes:")  && (r = parse(Int, split(l)[2]))
            startswith(l, "write_bytes:") && (w = parse(Int, split(l)[2]))
        end
    catch; end
    return (r, w)
end
function _meminfo()
    tot = 0.0; avail = 0.0; stot = 0.0; sfree = 0.0
    try
        for l in eachline("/proc/meminfo")
            f = split(l); length(f) < 2 && continue
            v = parse(Float64, f[2]) / 1024
            f[1] == "MemTotal:" && (tot = v); f[1] == "MemAvailable:" && (avail = v)
            f[1] == "SwapTotal:" && (stot = v); f[1] == "SwapFree:" && (sfree = v)
        end
    catch; end
    return (tot, avail, stot - sfree)
end

function _sys_sampler_loop()
    ncores = Sys.CPU_THREADS
    self = getpid()
    labels = Dict{Int,Tuple{String,Bool}}()
    prev_cpu = _cpu_ticks(); prev_proc = _proc_ticks(); prev_disk = _diskstats(); prev_io = _self_io()
    prev_gc = Base.gc_num().total_time; prev_t = time()
    while true
        sleep(_SYS_PERIOD_S)
        try
            t = time(); dt = max(t - prev_t, 1e-3)
            cpu = _cpu_ticks(); proc = _proc_ticks(); disk = _diskstats(); io = _self_io()
            gc = Base.gc_num().total_time
            dtot = max(cpu[4] - prev_cpu[4], 1)
            pct(ticks) = 100.0 * ticks / dtot
            cpu_self = 0.0; cpu_gaia = 0.0; cpu_all = 0.0
            gaia = Tuple{String,Float64,Float64}[]; others = Tuple{String,Float64}[]
            for (pid, (ticks, rss)) in proc
                p0 = get(prev_proc, pid, nothing); p0 === nothing && continue
                d = ticks - p0[1]; d < 0 && continue
                c = pct(d); cpu_all += c
                if pid == self
                    cpu_self = c
                    lab = get!(() -> _proc_label(pid), labels, pid)
                    pushfirst!(gaia, ("this GUI (pid $pid)", c, rss / 1024))
                else
                    lab, isg = get!(() -> _proc_label(pid), labels, pid)
                    if isg
                        cpu_gaia += c; push!(gaia, (lab * " (pid $pid)", c, rss / 1024))
                    elseif c >= 2.0
                        push!(others, (lab, c))
                    end
                end
            end
            sort!(others; by = x -> -x[2]); length(others) > 6 && resize!(others, 6)
            for pid in collect(keys(labels)); haskey(proc, pid) || delete!(labels, pid); end
            iow = pct(cpu[2] - prev_cpu[2]); idle = pct(cpu[3] - prev_cpu[3])
            busy = 100.0 - iow - idle
            cpu_others = max(busy - cpu_self - cpu_gaia, 0.0)
            load1 = try; parse(Float64, split(_read_first_line("/proc/loadavg"))[1]); catch; NaN; end
            mem = _meminfo()
            s = SysSample(t, ncores, cpu_self, cpu_gaia, cpu_others, iow, idle, load1,
                          mem[1], mem[2], mem[3],
                          (disk[1] - prev_disk[1]) / dt / 1e6, (disk[2] - prev_disk[2]) / dt / 1e6,
                          (io[1] - prev_io[1]) / dt / 1e6, (io[2] - prev_io[2]) / dt / 1e6,
                          100.0 * (gc - prev_gc) / 1e9 / dt,
                          gaia, others)
            lock(_SYS_LOCK) do
                _SYS_LATEST[] = s
                push!(_SYS_HIST, s)
                while !isempty(_SYS_HIST) && t - _SYS_HIST[1].t > _SYS_HIST_S; popfirst!(_SYS_HIST); end
            end
            msg = try; _degradation_message(_DEGRADE_SESS[]); catch; ""; end
            isempty(msg) || _cause_event!(:overload, _SYS_PERIOD_S, msg)
            # Alarms: one Causes case when each alarm starts (the red banner shows them while they last).
            al = try; _alarms(_DEGRADE_SESS[]); catch; Tuple{Symbol,String}[]; end
            for (k, t) in al
                k in _ALARMS_PREV[] || _cause_event!(:alarm, 1, t)
            end
            _ALARMS_PREV[] = Set{Symbol}(first.(al))
            prev_cpu = cpu; prev_proc = proc; prev_disk = disk; prev_io = io; prev_gc = gc; prev_t = t
        catch err
            @debug "system sampler" err
        end
    end
end

# Idempotent; called when the plot window or the web server starts.
function _start_sys_sampler!()
    Threads.atomic_cas!(_SYS_STARTED, false, true) == false || return
    Threads.@spawn _sys_sampler_loop()
    return
end

function _sys_snapshot()
    lock(_SYS_LOCK) do
        (_SYS_LATEST[], copy(_SYS_HIST))
    end
end

# JSON fragment for /status.json (no leading/trailing braces).
function _health_json_fields()
    s = _SYS_LATEST[]
    s === nothing && return "\"health\":null"
    j(x) = isnan(x) ? "null" : string(round(x; digits = 1))
    return string("\"degradation\":\"", _json_escape(_banner_text(_DEGRADE_SESS[])), "\",",
                  "\"health\":{\"cpu_self_pct\":", j(s.cpu_self), ",\"cpu_gaia_other_pct\":", j(s.cpu_gaia_other),
                  ",\"cpu_others_pct\":", j(s.cpu_others), ",\"cpu_iowait_pct\":", j(s.cpu_iowait),
                  ",\"cpu_idle_pct\":", j(s.cpu_idle), ",\"load1\":", j(s.load1), ",\"ncores\":", s.ncores,
                  ",\"mem_avail_mb\":", j(s.mem_avail_mb), ",\"mem_total_mb\":", j(s.mem_total_mb),
                  ",\"swap_used_mb\":", j(s.swap_used_mb), ",\"disk_read_mbs\":", j(s.disk_read_mbs),
                  ",\"disk_write_mbs\":", j(s.disk_write_mbs), ",\"gc_pct\":", j(s.gc_pct), "}")
end

# ---- alarms ---------------------------------------------------------------
# Silent failures made visible (plan item 3, corrected 2026-10-21; SSR-specific
# validity logic is NOT part of it): a stream the profile uses is down/refused
# or stalled, or an enabled constellation is missing from the solution. Pure
# function of the session state; returns (key, text) pairs.
const _ALARM_AFTER_S = 30.0       # stream down / stalled this long
const _ALARM_CONS_S  = 10.0       # constellation absent from the fit this long
const _ALARMS_PREV = Ref(Set{Symbol}())

function _last_drop_reason(st, label::AbstractString)
    for e in Iterators.reverse(copy(st.drop_log))
        occursin("[" * label * "]", e) || continue
        i = findfirst("] ", e)
        r = strip(replace(i === nothing ? e : e[last(i)+1:end], r"\s+" => " "))
        return first(r, 70)
    end
    return ""
end

function _alarms(sess)
    out = Tuple{Symbol,String}[]
    (sess === nothing || !isrunning(sess)) && return out
    st = sess.stats; p = sess.profile
    used = Pair{Symbol,String}[:obs => "obs"]
    p.use_ssr && !isempty(p.ssr_caster) && push!(used, :ssr => "SSR")
    p.use_eph && !isempty(p.eph_caster) && push!(used, :eph => "EPH")
    now_sod = _wall_utc_sod(); now_dt = Dates.now(Dates.UTC)
    outs = copy(st.outages)
    for (kind, label) in used
        code = _stream_code(kind)
        io = findlast(o -> o[3] == code && isnan(o[2]), outs)
        extra = kind === :ssr ? " (broadcast ephemeris only)" : ""
        if io !== nothing
            age = _sod_diff(now_sod, outs[io][1])
            if age >= _ALARM_AFTER_S
                why = _last_drop_reason(st, label)
                push!(out, (Symbol(kind, "_down"), string(uppercase(label), " stream down ", round(Int, age), " s",
                                                         isempty(why) ? "" : ": " * why, extra)))
            end
            continue
        end
        last = kind === :obs ? st.last_obs_byte_at : kind === :ssr ? st.last_ssr_byte_at : st.last_eph_byte_at
        if last != Dates.DateTime(0)
            age = Dates.value(now_dt - last) / 1000
            age >= _ALARM_AFTER_S &&
                push!(out, (Symbol(kind, "_stall"), string(uppercase(label), " stream stalled: no data for ", round(Int, age), " s", extra)))
        end
    end
    bs = sess.bridge_state
    if bs !== nothing && p.use_ssr && bs.options.RTC == 1
        names = Dict('G' => "GPS", 'R' => "GLONASS", 'E' => "Galileo", 'C' => "BeiDou")
        sysopt = bs.options.system
        en = Dict('G' => sysopt.gps == 1, 'R' => sysopt.glo == 1, 'E' => sysopt.gal == 1, 'C' => sysopt.bds == 1)
        for c in "GREC"
            v, n = get(bs.ssr_cons, c, (0, 0))
            (en[c] && n > 0 && v == 0) &&
                push!(out, (Symbol("ssr_", c), string("No usable SSR for ", names[c], p.ssr_fallback ?
                    " (broadcast orbit and clock used)" : " (satellites DROPPED from the solution)")))
        end
    end
    if bs !== nothing
        iv = (isfinite(st.input_interval_s) && st.input_interval_s > 0) ? st.input_interval_s : 1.0
        names = Dict('G' => "GPS", 'R' => "GLONASS", 'E' => "Galileo", 'C' => "BeiDou")
        for c in "GREC"
            t = get(bs.cons_absent, c, 0) * iv
            t >= _ALARM_CONS_S && push!(out, (Symbol("cons_", c), string("No ", names[c], " in the solution for ", round(Int, t), " s")))
        end
    end
    return out
end

# SSR state for /status.json: "off" (not used), "waiting" (used, not yet active), "active".
function _ssr_mode(sess)
    sess.profile.use_ssr || return "off"
    bs = sess.bridge_state
    (bs !== nothing && bs.options.RTC == 1) || return "waiting"
    v = sum((x[1] for x in values(bs.ssr_cons)); init = 0); n = sum((x[2] for x in values(bs.ssr_cons)); init = 0)
    return n == 0 ? "active" : v == 0 ? "fallback" : v == n ? "active" : "partial"
end

# "G 31/32 R 0/24 E 30/30 C 0/37": satellites with usable SSR / known broadcast ephemeris.
function _ssr_sats(sess)
    bs = sess.bridge_state
    (bs === nothing || isempty(bs.ssr_cons)) && return ""
    return join((string(c, " ", bs.ssr_cons[c][1], "/", bs.ssr_cons[c][2]) for c in "GREC" if haskey(bs.ssr_cons, c)), " ")
end

# Red banner text: alarms first, then the CPU-overload message.
function _banner_text(sess)
    parts = String[t for (_, t) in (try; _alarms(sess); catch; Tuple{Symbol,String}[]; end)]
    d = try; _degradation_message(sess); catch; ""; end
    isempty(d) || push!(parts, d)
    return join(parts, "  ·  ")
end

# ---- degradation banner --------------------------------------------------
# Non-empty when other processes on this machine are demonstrably slowing
# GaiaSeis: they hold at least half the CPU and either the machine is
# overloaded, the solve takes most of the epoch interval, or the stream is
# being processed late. Drawn in large red letters over the position
# waveforms (plot window and web page) and sent in /status.json.
function _degradation_message(sess)
    s = _SYS_LATEST[]
    s === nothing && return ""
    lrel = isnan(s.load1) ? 0.0 : s.load1 / s.ncores
    solve = NaN; interval = NaN; arr = NaN; missing60 = 0
    if sess !== nothing && !isempty(sess.stats.metrics_history)
        m = sess.stats.metrics_history[end]
        solve = m[_M_SOLVE]; arr = m[_M_ARR]; interval = sess.stats.input_interval_s
        missing60 = _missing_last(sess.stats, 60.0)
    end
    slow   = !isnan(solve) && !isnan(interval) && interval > 0 && solve / 1000 > 0.7 * interval
    behind = !isnan(arr) && arr > 2.0
    (s.cpu_others >= 50.0 && (lrel > 1.0 || slow || behind)) || return ""
    msg = @sprintf("CPU overload: other processes use %.0f%% of the CPU, GaiaSeis is delayed", s.cpu_others)
    behind && (msg *= @sprintf(" (stream processed %.0f s late)", arr))
    # Epochs the catch-up rule had to drop because the solve could not keep
    # up: these are lost BECAUSE of the load, so say so.
    skips = _skips_last_60s(sess)
    skips > 0 && (msg *= @sprintf(" — %d epochs skipped in the last 60 s because of the load", skips))
    # Being behind the stream makes the reader queue fill and the caster
    # drop; only then are missing epochs attributable to the overload.
    behind && missing60 > 0 && (msg *= @sprintf(", and %d epochs missing from the stream for the same reason", missing60))
    return msg
end

# ---- drawing ------------------------------------------------------------
function _draw_health(cr, w::Float64, h::Float64, sess, settings::PlotSettings)
    G = Main.Gtk4; C = Main.Cairo
    G.set_source_rgb(cr, 1.0, 1.0, 1.0); G.rectangle(cr, 0, 0, w, h); G.fill(cr)
    C.select_font_face(cr, "sans-serif", 0, 0); C.set_font_size(cr, 11.0)
    s, hist = _sys_snapshot()
    txt(x, y, str; rgb = (0.15, 0.15, 0.15)) = (G.set_source_rgb(cr, rgb...); G.move_to(cr, x, y); C.show_text(cr, str))
    if s === nothing
        txt(20, 30, "(collecting system samples…)"); return
    end
    ml = 16.0; lw = 150.0                     # label column
    bar_x = ml + lw; bar_w = max(w * 0.42 - bar_x, 120.0); row_h = 22.0
    px0 = w * 0.72; pw = w - px0 - 14.0       # sparklines on the right
    legend_limit = px0 - 12.0
    y = 26.0
    # stacked bar helper: segments = [(value, rgb, label)], full = 100 %
    function stacked(y, title, segs, full; unit = "%")
        txt(ml, y + 4, title)
        G.set_source_rgb(cr, 0.92, 0.92, 0.92); G.rectangle(cr, bar_x, y - 9, bar_w, 16); G.fill(cr)
        x = bar_x
        for (v, rgb, _) in segs
            v <= 0 && continue
            ww = bar_w * clamp(v / full, 0.0, 1.0)
            G.set_source_rgb(cr, rgb...); G.rectangle(cr, x, y - 9, ww, 16); G.fill(cr); x += ww
        end
        G.set_source_rgb(cr, 0.6, 0.6, 0.6); G.set_line_width(cr, 0.8); G.rectangle(cr, bar_x, y - 9, bar_w, 16); G.stroke(cr)
        lx = bar_x + bar_w + 8; ly = y; rows = 0
        for (v, rgb, lab) in segs
            isempty(lab) && continue
            str = @sprintf("%s %.0f%s", lab, v, unit)
            tw = C.text_extents(cr, str)[3] + 22
            if lx + tw > legend_limit && lx > bar_x + bar_w + 8
                lx = bar_x + bar_w + 8; ly += 14; rows += 1
            end
            G.set_source_rgb(cr, rgb...); G.rectangle(cr, lx, ly - 6, 9, 9); G.fill(cr)
            txt(lx + 12, ly + 3, str); lx += tw
        end
        return rows * 14.0
    end
    function single(y, title, v, full, rgb, str)
        txt(ml, y + 4, title)
        G.set_source_rgb(cr, 0.92, 0.92, 0.92); G.rectangle(cr, bar_x, y - 9, bar_w, 16); G.fill(cr)
        G.set_source_rgb(cr, rgb...); G.rectangle(cr, bar_x, y - 9, bar_w * clamp(v / full, 0.0, 1.0), 16); G.fill(cr)
        G.set_source_rgb(cr, 0.6, 0.6, 0.6); G.rectangle(cr, bar_x, y - 9, bar_w, 16); G.stroke(cr)
        txt(bar_x + bar_w + 8, y + 3, str)
    end
    c_self = (0.15, 0.45, 0.85); c_gaia = (0.35, 0.65, 0.95); c_oth = (0.85, 0.45, 0.15); c_iow = (0.75, 0.2, 0.2); c_idle = (0.75, 0.9, 0.75)
    y += stacked(y, "CPU, all $(s.ncores) cores", [(s.cpu_self, c_self, "this GUI"), (s.cpu_gaia_other, c_gaia, "other GaiaSeis"),
                                          (s.cpu_others, c_oth, "other processes"), (s.cpu_iowait, c_iow, "I/O wait"),
                                          (s.cpu_idle, c_idle, "free")], 100.0); y += row_h
    for (lab, c, rss) in s.gaia_procs
        single(y, "  " * first(lab, 24), c, 100.0, lab == s.gaia_procs[1][1] ? c_self : c_gaia,
               @sprintf("%.0f%% of machine (%.1f cores)  RSS %.0f MB", c, c * s.ncores / 100, rss)); y += row_h
    end
    for (lab, c) in s.top_others
        single(y, "  " * first(lab, 24), c, 100.0, c_oth, @sprintf("%.0f%% (%.1f cores)", c, c * s.ncores / 100)); y += row_h
    end
    lrel = isnan(s.load1) ? 0.0 : s.load1 / s.ncores
    single(y, "Load average (1 min)", lrel, 2.0, lrel > 1 ? c_iow : c_self,
           @sprintf("%.1f runnable / %d cores%s", s.load1, s.ncores, lrel > 1 ? "  — overloaded" : "")); y += row_h
    mem_used = s.mem_total_mb - s.mem_avail_mb
    single(y, "Memory", mem_used, s.mem_total_mb, mem_used / max(s.mem_total_mb, 1) > 0.9 ? c_iow : c_self,
           @sprintf("%.1f / %.1f GB used, %.1f GB available%s", mem_used / 1024, s.mem_total_mb / 1024, s.mem_avail_mb / 1024,
                    s.swap_used_mb > 100 ? @sprintf(", swap %.0f MB in use", s.swap_used_mb) : "")); y += row_h
    dmax = max(50.0, s.disk_read_mbs + s.disk_write_mbs)
    y += stacked(y, "Disk, machine", [(s.disk_read_mbs, c_self, "read"), (s.disk_write_mbs, c_oth, "write")], dmax; unit = " MB/s"); y += row_h
    y += stacked(y, "Disk, this GUI", [(s.self_read_mbs, c_self, "read"), (s.self_write_mbs, c_oth, "write")], dmax; unit = " MB/s"); y += row_h
    single(y, "GC pauses, this GUI", s.gc_pct, 25.0, s.gc_pct > 10 ? c_iow : c_self, @sprintf("%.1f%% of wall time", s.gc_pct)); y += row_h
    # ---- delay chain (current) ----
    y += 8; txt(ml, y, "Delays (last epoch)"; rgb = (0.1, 0.1, 0.1)); y += row_h - 4
    arr = NaN; slv = NaN; msd = NaN; interval = NaN; nsat = 0; deliv = NaN
    if sess !== nothing && !isempty(sess.stats.metrics_history)
        m = sess.stats.metrics_history[end]
        arr = m[_M_ARR]; slv = m[_M_SOLVE]; msd = m[_M_MSEED]; interval = sess.stats.input_interval_s
        # newest flushed record: on-disk latency of the last flushed epoch
        for k in length(sess.stats.metrics_history):-1:max(1, length(sess.stats.metrics_history) - 3000)
            v = sess.stats.metrics_history[k][_M_MSEED]; isnan(v) || (msd = v; break)
        end
        dh = sess.stats.mseed_delivery_history
        isempty(dh) || (deliv = dh[end][2])
    end
    fmt(v, u) = isnan(v) ? "—" : @sprintf("%.2f %s", v, u)
    dmaxs = max(2.0, arr, isnan(msd) ? 0.0 : msd, isnan(deliv) ? 0.0 : deliv)
    single(y, "receiver -> GaiaSeis", isnan(arr) ? 0.0 : arr, dmaxs, arr > 2 ? c_iow : c_self, fmt(arr, "s") * "  (arrival latency)"); y += row_h
    single(y, "solve", isnan(slv) ? 0.0 : slv / 1000, dmaxs, (!isnan(interval) && slv / 1000 > interval) ? c_iow : c_self,
           fmt(slv, "ms") * (isnan(interval) ? "" : @sprintf("  (epoch every %.0f ms)", interval * 1000))); y += row_h
    single(y, "epoch -> miniSEED on disk", isnan(msd) ? 0.0 : msd, dmaxs, c_self, fmt(msd, "s") * "  (last flushed record)"); y += row_h
    single(y, "epoch -> live client", isnan(deliv) ? 0.0 : deliv, dmaxs, c_self,
           fmt(deliv, "s") * (isnan(deliv) ? "  (no /mseed/live client)" : "  (last bytes sent to a puller)")); y += row_h
    # ---- warnings ----
    warns = String[]
    lrel > 1.0 && push!(warns, @sprintf("machine overloaded: load %.0f on %d cores — other processes are taking the data thread's time", s.load1, s.ncores))
    s.cpu_others > 70 && push!(warns, @sprintf("other processes use %.0f%% of the CPU", s.cpu_others))
    s.cpu_iowait > 10 && push!(warns, @sprintf("I/O wait %.0f%% — disk saturated", s.cpu_iowait))
    s.mem_avail_mb < 0.1 * s.mem_total_mb && push!(warns, "less than 10 % of memory available")
    s.swap_used_mb > 500 && push!(warns, @sprintf("swap in use (%.0f MB)", s.swap_used_mb))
    s.gc_pct > 10 && push!(warns, @sprintf("GC pauses %.0f%% of wall time — allocation pressure", s.gc_pct))
    !isnan(interval) && !isnan(slv) && slv / 1000 > interval && push!(warns, "solve slower than the epoch interval — backlog builds")
    arr > 2 && push!(warns, @sprintf("arrival latency %.1f s — backlog or slow link", arr))
    if sess !== nothing
        st = sess.stats
        st.input_missing > 0 && !isnan(st.input_last_sod) && _missing_last(st, 60.0) > 0 &&
            push!(warns, @sprintf("%d epochs missing from the stream in the last 60 s", _missing_last(st, 60.0)))
        _LIVE_TASKS[] >= _LIVE_MAX && push!(warns, "live-stream cap reached ($(_LIVE_TASKS[])) — a client is reconnecting too often")
    end
    y += 6
    if isempty(warns)
        txt(ml, y, "No condition that would delay or lose epochs."; rgb = (0.1, 0.5, 0.1))
    else
        for wv in warns; txt(ml, y, "! " * wv; rgb = (0.75, 0.15, 0.15)); y += 16; end
    end
    # ---- history sparkline on the right: CPU busy (machine) and this GUI ----
    if pw > 120 && length(hist) > 2
        py0 = 26.0; ph = min(150.0, h * 0.35)
        G.set_source_rgb(cr, 0.93, 0.93, 0.93); G.rectangle(cr, px0, py0, pw, ph); G.fill(cr)
        t0 = hist[1].t; tspan = max(hist[end].t - t0, 1.0)
        function line(vals, rgb)
            G.set_source_rgb(cr, rgb...); G.set_line_width(cr, 1.2); first_ = true
            for (k, sm) in enumerate(hist)
                x = px0 + pw * (sm.t - t0) / tspan; yy = py0 + ph * (1 - clamp(vals[k] / 100, 0, 1))
                first_ ? (G.move_to(cr, x, yy); first_ = false) : G.line_to(cr, x, yy)
            end
            G.stroke(cr)
        end
        line([100 - sm.cpu_idle for sm in hist], c_oth)
        line([sm.cpu_self + sm.cpu_gaia_other for sm in hist], c_self)
        txt(px0, py0 - 6, @sprintf("CPU, last %.0f min: machine (orange), GaiaSeis (blue)", tspan / 60))
        # load history below
        py1 = py0 + ph + 30; ph1 = min(90.0, h - py1 - 10)
        if ph1 > 30
            G.set_source_rgb(cr, 0.93, 0.93, 0.93); G.rectangle(cr, px0, py1, pw, ph1); G.fill(cr)
            lmax = max(2.0, maximum(sm -> isnan(sm.load1) ? 0.0 : sm.load1 / sm.ncores, hist))
            G.set_source_rgb(cr, c_iow...); first_ = true
            for sm in hist
                x = px0 + pw * (sm.t - t0) / tspan; yy = py1 + ph1 * (1 - clamp((isnan(sm.load1) ? 0.0 : sm.load1 / sm.ncores) / lmax, 0, 1))
                first_ ? (G.move_to(cr, x, yy); first_ = false) : G.line_to(cr, x, yy)
            end
            G.stroke(cr)
            yl = py1 + ph1 * (1 - 1 / lmax); G.set_source_rgb(cr, 0.4, 0.4, 0.4); G.set_line_width(cr, 0.6)
            G.move_to(cr, px0, yl); G.line_to(cr, px0 + pw, yl); G.stroke(cr)
            txt(px0, py1 - 6, "Load average / cores (line = all cores busy)")
        end
    end
    return
end
