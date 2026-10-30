# NtripSession orchestrator — owns the reader task, decoder, and log file.
#
# When `profile.use_ssr` is true and `profile.ssr_caster` is set, the session
# additionally opens a second NTRIP connection to the SSR products caster
# (e.g. products.igs-ip.net/SSRA00CNES0). Both reader tasks feed the SAME
# `RtcmDecoder` — the decoder is mutated under a lock so the two streams can
# interleave safely. The bridge always reads the latest combined state.

# ---- Crash-safe sink draining ----
# Every completed 512-byte miniSEED record is already `Base.flush`ed to the
# OS as it is packed, so a dying process never loses data that made it into
# a full record. What IS at risk is the writer's in-RAM tail: up to
# `miniseed_flush_interval_sec` of samples not yet packed. `stop!` drains
# it, but `exit()`, an uncaught exception, Ctrl-C and `kill` never reach
# `stop!`. Keep a registry of live sessions so an atexit hook can drain
# them on every one of those paths.
#
# Not covered: SIGKILL and SIGSEGV, where no user code runs at all. A
# segfault therefore still costs at most one flush interval.
const _LIVE_SESSIONS = Set{NtripSession}()
const _LIVE_SESSIONS_LOCK = ReentrantLock()

_register_session!(s::NtripSession)   = lock(() -> push!(_LIVE_SESSIONS, s),   _LIVE_SESSIONS_LOCK)
_unregister_session!(s::NtripSession) = lock(() -> delete!(_LIVE_SESSIONS, s), _LIVE_SESSIONS_LOCK)

"""
    flush_sinks!(session) -> session

Drain and close the session's file sinks — the miniSEED writers' pending
partial record and the per-session log — without touching the reader tasks.

Idempotent, never throws, and safe to call from an `atexit` hook. `stop!`
uses it after the readers have been joined; the shutdown hook calls it
directly on whatever is still live.
"""
function flush_sinks!(s::NtripSession)
    if s.mseed_writers !== nothing
        for ch in (:N, :E, :Z)
            w = getfield(s.mseed_writers, ch)
            try; close_writer!(w); catch err; @debug "mseed close failed" err; end
        end
        s.mseed_writers = nothing
    end
    if s.datalink !== nothing
        try; close_datalink!(s.datalink); catch err; @debug "datalink close failed" err; end
        s.datalink = nothing
    end
    if s.log_file !== nothing
        try; flush(s.log_file); close(s.log_file); catch err; @debug "log close failed" err; end
        s.log_file = nothing
    end
    return s
end

"""
    _safe_filename(s) -> String

Strip characters that are illegal or awkward in a path component. Profile names
are free text from the GUI and are used to build log filenames.
"""
_safe_filename(s::AbstractString) = replace(String(s), r"[/\\:*?\"<>|\0]" => "_")

function _flush_all_live_sessions!()
    # Close any open web-viewer sessions too, so `kill` / Ctrl-C does not
    # leave a dangling CONNECT in the access history. Defined in GUI/gui.jl,
    # which is included after this file.
    try
        isdefined(@__MODULE__, :_flush_web_trackers!) && _flush_web_trackers!()
    catch err
        @debug "web tracker flush failed" err
    end
    sessions = lock(() -> collect(_LIVE_SESSIONS), _LIVE_SESSIONS_LOCK)
    isempty(sessions) && return nothing
    for s in sessions
        try
            flush_sinks!(s)
        catch err
            # An atexit hook must never throw — it would mask the real exit.
            @debug "shutdown flush failed" err
        end
    end
    return nothing
end

const _SHUTDOWN_HOOKS_INSTALLED = Ref(false)

# Called from `GaiaSeis.__init__`. Guarded so repeated module loads (or a
# manual call) cannot stack duplicate hooks.
function _install_shutdown_hooks!()
    _SHUTDOWN_HOOKS_INSTALLED[] && return nothing
    _SHUTDOWN_HOOKS_INSTALLED[] = true
    atexit(_flush_all_live_sessions!)
    return nothing
end

# Delete the oldest archived logs "<root>_<yyyymmdd_HHMMSS><ext>" beyond the newest `keep`.
# Only names of exactly that pattern next to the live log are touched.
function _prune_session_logs(root::AbstractString, ext::AbstractString, keep::Integer)
    dir = dirname(root); base = basename(root)
    isarch(f) = startswith(f, base * "_") && endswith(f, ext) && length(f) > length(base) + length(ext) + 1 &&
                occursin(r"^\d{8}_\d{6}$", f[length(base)+2:end-length(ext)])
    old = sort!(filter(isarch, readdir(dir)); rev = true)
    for f in old[keep+1:end]
        try; rm(joinpath(dir, f)); catch; end
    end
    return length(old) - keep > 0 ? length(old) - keep : 0
end

# An explicit output_filename is reused by every start; opening it with "w"
# destroyed the previous session's log (it had to be copied aside by hand).
# Keep the old one under its own modification time instead. A timestamped
# default name needs nothing. Returns the archive path or nothing.
function _keep_previous_log(logpath::AbstractString, output_filename::AbstractString; keep::Integer = 0)
    (isempty(output_filename) || !isfile(logpath) || filesize(logpath) == 0) && return nothing
    try
        root, ext = splitext(logpath)
        arch = string(root, "_", Dates.format(Dates.unix2datetime(mtime(logpath)), "yyyymmdd_HHMMSS"), ext)
        isfile(arch) && return nothing
        mv(logpath, arch)
        keep > 0 && _prune_session_logs(root, ext, keep)
        return arch
    catch err
        @warn "could not keep the previous session log" err
        return nothing
    end
end

"""
    start!(session) -> session

Spawn the reader task(s) that connect to the caster, decode RTCM, and feed the
PPPHVA bridge. If the active profile has `use_ssr = true` and a `ssr_caster`,
a second reader task is spawned for the SSR products stream.
"""
function start!(s::NtripSession)
    isrunning(s) && error("session already running")
    s.stop_requested[] = false
    s.stats = SessionStats(started_at = Dates.now())
    s.bridge_state = nothing

    # Open log file
    log_dir = isabspath(s.profile.log_dir) ? s.profile.log_dir :
                                              joinpath(data_root(), s.profile.log_dir)
    mkpath(log_dir)
    # The session log path must be unique per profile. Two profiles sharing one
    # `output_filename` both open it with "w": the second truncates the first,
    # then both append through independent handles, interleaving their epochs
    # into one unusable file. Seen on 2026-09-07 with two profiles both set to
    # `output_filename = "pop"` — a 384 MB log mixing a 1 Hz and a 10 Hz
    # station, useless for forensics.
    #
    # An explicit `output_filename` is still honoured, but the profile name is
    # prefixed unless it is already part of the name the user chose.
    fname = if isempty(s.profile.output_filename)
        "$(_safe_filename(s.profile.name))_$(Dates.format(Dates.now(),"yyyymmdd_HHMMSS")).txt"
    else
        base = _safe_filename(s.profile.output_filename)
        prof = _safe_filename(s.profile.name)
        occursin(prof, base) ? base : string(prof, "_", base)
    end
    logpath = joinpath(log_dir, fname)
    _keep_previous_log(logpath, s.profile.output_filename; keep = s.profile.keep_session_logs)
    s.log_file = open(logpath, "w")
    println(s.log_file, "# GaiaSeis session  profile=$(s.profile.name)  obs=$(s.profile.mountpoint)",
            s.profile.use_ssr ? "  ssr=$(s.profile.ssr_caster)/$(s.profile.ssr_mountpoint)" : "")
    println(s.log_file, "#    SOD nsat            dX            dY            dZ           DTG           DTR           DTE nused   rms_w_m   rms_u_m")
    # Per-epoch link metrics, one CSV per session (see _record_metrics!).
    try
        mpath = joinpath(log_dir, "$(_safe_filename(s.profile.name))_metrics_$(Dates.format(Dates.now(),"yyyymmdd_HHMMSS")).csv")
        s.stats.metrics_csv = open(mpath, "w")
        s.stats.metrics_csv_path = mpath
        println(s.stats.metrics_csv, "# GaiaSeis metrics  profile=$(s.profile.name)  link=\"$(replace(s.profile.link_description, '"' => '\''))\"  obs=$(s.profile.caster):$(s.profile.port)/$(s.profile.mountpoint)  tls=$(s.profile.use_tls)",
                s.profile.use_ssr ? "  ssr=$(s.profile.ssr_caster):$(s.profile.ssr_port)/$(s.profile.ssr_mountpoint)" : "",
                s.profile.use_eph ? "  eph=$(s.profile.eph_caster):$(s.profile.eph_port)/$(s.profile.eph_mountpoint)" : "")
        println(s.stats.metrics_csv, _METRICS_HEADER)
    catch err
        @warn "metrics CSV could not be opened" err
        s.stats.metrics_csv = nothing
    end

    decoder = RtcmDecoder()
    decoder_lock = ReentrantLock()
    s.decoder = decoder
    s.reader_task = @async _reader_loop(s, decoder, decoder_lock, :obs)
    if s.profile.use_ssr && !isempty(s.profile.ssr_caster)
        s.ssr_reader_task = @async _reader_loop(s, decoder, decoder_lock, :ssr)
    end
    if s.profile.use_eph && !isempty(s.profile.eph_caster)
        s.eph_reader_task = @async _reader_loop(s, decoder, decoder_lock, :eph)
    end
    _register_session!(s)
    # Background task that writes a full diagnostic dump to disk every 30 s.
    # Survives a GUI freeze — the latest snapshot is always on disk.
    @async _autodump_loop(s)
    return s
end

# Periodically save the diagnostic dump to logs/auto_debug_<profile>.txt so the
# user has something to send even if the GUI becomes unresponsive.
function _autodump_loop(s::NtripSession)
    log_dir = isabspath(s.profile.log_dir) ? s.profile.log_dir :
                                              joinpath(data_root(), s.profile.log_dir)
    mkpath(log_dir)
    path = joinpath(log_dir, "auto_debug_$(s.profile.name).txt")
    # GC pacing. PPPHVA rebuilds several untyped PStructs per epoch; at 10 Hz
    # the allocation rate outruns Julia's default heuristic GC and RSS climbs
    # ~5 GB/h until the OOM killer takes the process (observed 2026-09-08,
    # 28 GB after 5 h). A 1 Hz station does not leak (PAT0: flat at ~0.7 GB
    # over 14 h). Forcing a full collection on this existing 10 s loop keeps
    # RSS bounded without touching the hot path. Skippable via
    # GAIASEIS_GC_PACING=0 for debugging the underlying allocation.
    # Default OFF. The forced full collection was a crutch for the web-render
    # Cairo leak, which is now fixed at the source (Cairo.destroy per request).
    # With MALLOC_ARENA_MAX=2 the arena cap holds RSS flat on its own, and a
    # full GC.gc(true) on a ~900 MB heap is an ~88 ms stop-the-world pause —
    # nearly a whole 10 Hz epoch during which the obs reader is starved. That
    # stall, landing beside a plot redraw, is what tipped the SSR-at-10 Hz
    # pipeline into its backlog spiral. Set GAIASEIS_GC_PACING=1 to re-enable.
    gc_pace = get(ENV, "GAIASEIS_GC_PACING", "0") == "1"
    gc_ticks = 0
    while !s.stop_requested[]
        try
            txt = diagnostic_dump(s)
            open(path, "w") do io; write(io, txt); end
        catch err
            @debug "auto-debug dump failed" err
        end
        if gc_pace
            gc_ticks += 1
            # Memory needs BOTH levers, verified empirically:
            #  - MALLOC_ARENA_MAX=2 (launch.sh) stops glibc arena
            #    fragmentation. Sufficient on its own HEADLESS (RSS flat
            #    ~0.6 GB), but NOT with the GUI.
            #  - A full GC.gc(true) here reclaims the GUI's Gtk/Cairo/plot/
            #    web allocations. With arena cap + full GC the GUI run holds
            #    flat (~0.9 GB); with only a light GC.gc(false) it climbed to
            #    12 GB in 18 min. So the full collection is required.
            # Runs on this 10 s background task, and backpressure now absorbs
            # any epoch that arrives during the collection, so the earlier
            # obs-stall concern no longer applies.
            GC.gc(true)
            # current RSS (Sys.maxrss is a high-water mark, so it only rises)
        end
        # The RSS ceiling guard runs on every tick, pacing or not. Until 2026-09-11
        # it lived inside the `if gc_pace` block, so with pacing OFF (the 0.3
        # default) it never ran and a 9-h session grew to 28 GB and was OOM-killed.
        rss_mb = try
            Int(round(parse(Int, split(read("/proc/self/statm", String))[2]) *
                  4096 / 1_048_576))
        catch; -1; end
        @debug "GC pacing tick" full=(gc_ticks % 3 == 0) rss_mb=rss_mb
        # Last-resort guard: if RSS still climbs past a hard ceiling despite
        # pacing, stop THIS session cleanly (flush sinks, close the log)
        # rather than let the kernel OOM-kill the whole GUI — which also
        # takes down every other running profile. Default 20 GB; tune with
        # GAIASEIS_RSS_LIMIT_MB. 0 disables.
        rss_limit = try; parse(Int, get(ENV, "GAIASEIS_RSS_LIMIT_MB", "20000")); catch; 20000; end
        if rss_limit > 0 && rss_mb > rss_limit
            @error "GaiaSeis: RSS exceeded limit — stopping this session to avoid an OOM kill of the whole process. Restart it to resume." rss_mb=rss_mb limit_mb=rss_limit profile=s.profile.name
            try; flush_sinks!(s); catch; end
            s.stop_requested[] = true
            return
        end
        # 10-second cadence for the diagnostic dump.
        for _ in 1:10
            s.stop_requested[] && return
            sleep(1.0)
        end
    end
end

"""
    flush_session_data!(s::NtripSession; reset_logs::Bool = true)

Reset every rolling buffer the GUI / sinks read from, while leaving the
stream itself running. Intended for the GUI's "Flush data" button so the
operator can mark a new reference point (e.g. just before an instrument
move) and have all downstream plots / mseed / CSV start over from there.

Cleared:
- `stats.displacement_history`, `stats.residual_history`, `stats.dop_history`
  (used by every GUI tab + the σ̂/DOP plots).
- `stats.last_*` snapshots (so the right-side status panel shows "—" until
  the next epoch).
- The bridge's outlier-guard rolling-MAD buffer.

When `reset_logs` is true (default) we also:
- close + delete the miniSEED writers' current day-files so new sample
  numbering starts at sequence 1 in a fresh file (the writers themselves
  get recreated on the next accepted epoch).
- truncate the CSV sink file (keeping a fresh header line if any).
- truncate the bridge's per-session log file (`logs/<profile>_<ts>.txt`).
"""
function flush_session_data!(s::NtripSession; reset_logs::Bool = true)
    # ---- in-memory rolling buffers ----
    lock(s.stats.lock) do
        empty!(s.stats.displacement_history)
        empty!(s.stats.residual_history)
        empty!(s.stats.dop_history)
    end
    s.stats.bytes_received = 0
    s.stats.frames_total = 0
    s.stats.frames_crc_failed = 0
    s.stats.last_msg_type = 0
    empty!(s.stats.msg_counts); empty!(s.stats.msg_counts_by)
    s.stats.last_epoch_sod = NaN
    s.stats.last_epoch_nsat = 0
    s.stats.last_residual_m = NaN
    s.stats.last_position_dxyz = (NaN, NaN, NaN)
    s.stats.error_message = ""
    s.stats.reconnects_obs = 0
    s.stats.reconnects_ssr = 0
    s.stats.reconnects_eph = 0
    s.stats.last_stall_at = DateTime(0)
    s.stats.n_eph = 0
    s.stats.n_ssr_orb = 0
    s.stats.n_ssr_clk = 0
    s.stats.last_obs_byte_at = DateTime(0)
    s.stats.last_ssr_byte_at = DateTime(0)
    s.stats.last_eph_byte_at = DateTime(0)
    s.stats.last_obs_stream_sod = NaN
    s.stats.last_ssr_stream_sod = NaN
    s.stats.last_eph_stream_sod = NaN
    s.stats.gps_week            = 0
    s.stats.last_obs_stream_tow = NaN
    s.stats.input_epochs        = 0
    s.stats.input_missing       = 0
    s.stats.input_interval_s    = NaN
    s.stats.input_last_sod      = NaN
    s.stats.input_prev_sod      = NaN
    empty!(s.stats.input_gaps)
    s.stats.epochs_rebaselined  = 0
    # ---- bridge outlier guard ----
    if s.bridge_state !== nothing
        try
            empty!(s.bridge_state.dxyz_history)
            s.bridge_state.consec_outliers = 0
            s.bridge_state.last_xs = Float64[]
            s.bridge_state.last_sno = 0
            s.bridge_state.last_res = NaN
            # Cumulative outlier stats reset alongside the rolling buffers
            # so the Plot window's counter starts fresh after a flush.
            s.bridge_state.outlier_total = 0
            s.bridge_state.outlier_dev_sq_sum = 0.0
            s.bridge_state.qgate = QualGateState()
        catch err
            @debug "could not reset bridge state" err
        end
    end
    # ---- sinks ----
    if reset_logs
        # miniSEED: close writers, delete their current day-files, reset.
        if s.mseed_writers !== nothing
            for ch in (:N, :E, :Z)
                w = getfield(s.mseed_writers, ch)
                try; close_writer!(w); catch err; @debug "mseed close failed" err; end
                if w.current_year != 0
                    p = _mseed_path(w, w.current_year, w.current_doy)
                    try; isfile(p) && rm(p); catch err; @debug "mseed rm failed" err path=p; end
                end
            end
            s.mseed_writers = nothing
        end
        # CSV sink: truncate the file.
        if !isempty(s.profile.miniseed_csv_path)
            try
                open(s.profile.miniseed_csv_path, "w") do _ end
            catch err
                @debug "csv truncate failed" err
            end
        end
        # Per-session text log.
        if s.log_file !== nothing
            try; close(s.log_file); catch; end
            s.log_file = nothing
        end
    end
    return s
end

"""
    stop!(session)

Signal the reader task(s) to exit. Blocks until they finish (or returns
immediately if not running). Closes the log file and flushes any open
miniSEED writers.
"""
function stop!(s::NtripSession)
    s.stop_requested[] = true
    for t in (s.reader_task, s.ssr_reader_task, s.eph_reader_task)
        t === nothing && continue
        try; wait(t); catch; end
    end
    # Drain the sinks (last partial miniSEED record + log) and drop the
    # session from the shutdown registry — it is no longer at risk.
    flush_sinks!(s)
    _unregister_session!(s)
    if s.stats.metrics_csv !== nothing
        try; close(s.stats.metrics_csv); catch; end
        s.stats.metrics_csv = nothing
    end
    s.reader_task = nothing
    s.ssr_reader_task = nothing
    s.eph_reader_task = nothing
    s.stats.connected = false
    return s
end

# NtripProfile-like views that retarget `run_stream!` at the SSR / eph
# connection fields. We mirror only the transport-relevant fields — the
# bridge still reads `session.profile` directly for its options.
function _ssr_view(p::NtripProfile)
    NtripProfile(
        name        = p.name * ":SSR",
        caster      = p.ssr_caster,
        port        = p.ssr_port,
        mountpoint  = p.ssr_mountpoint,
        user        = p.ssr_user,
        password    = p.ssr_password,
        use_tls     = p.ssr_use_tls,
        send_gga    = false,
    )
end
function _eph_view(p::NtripProfile)
    NtripProfile(
        name        = p.name * ":EPH",
        caster      = p.eph_caster,
        port        = p.eph_port,
        mountpoint  = p.eph_mountpoint,
        user        = p.eph_user,
        password    = p.eph_password,
        use_tls     = p.eph_use_tls,
        send_gga    = false,
    )
end

function _reader_loop(s::NtripSession, decoder::RtcmDecoder,
                       decoder_lock::ReentrantLock, kind::Symbol)
    profile = kind === :ssr ? _ssr_view(s.profile) :
              kind === :eph ? _eph_view(s.profile) : s.profile
    label   = kind === :ssr ? "SSR" : kind === :eph ? "EPH" : "obs"
    # Supervise the connection rather than running it once. `run_stream!`
    # returns when the caster ends the stream and throws when it drops or
    # stalls; either way the stream is dead and only a fresh socket brings
    # it back — which is exactly what the operator was doing by hand with
    # Stop/Start. Retry until the session is actually asked to stop.
    delay = profile.reconnect_min_delay_sec
    while !s.stop_requested[]
        got_data = false
        try
            # The socket is read on its own thread. The mount-B caster drops
            # whole RTCM messages for a client that is slow to read, and a
            # slow client degrades delivery to the other clients too
            # (measured 2026-09-10: a client pausing 1.5 s every few seconds
            # kept 10 % of its frames and cut a fast client's GPS frames by
            # 40 %). Decoding, solving and the plot redraw all share thread 1,
            # so the read loop must not wait on them: chunks are queued here
            # and consumed on this task under the decoder lock as before.
            ch = Channel{Any}(8192)
            producer = Threads.@spawn begin
                try
                    run_stream!(profile, bytes -> put!(ch, copy(bytes));
                                stop_flag = s.stop_requested,
                                on_status = sym -> put!(ch, sym))
                    put!(ch, :eof)
                catch err
                    put!(ch, (:error, err))
                end
            end
            # Chunks that piled up while the consumer was busy are drained
            # into ONE batch before decoding. `_handle_bytes!` skips the
            # stale epochs of a batch (backpressure), so a data thread that
            # fell behind — an overloaded machine — jumps to the newest
            # epoch instead of processing a growing queue in order (that
            # produced a latency climbing to the queue's ~60 s capacity,
            # 2026-09-12). Status symbols are handled in sequence: draining
            # stops at the first one.
            pending = nothing
            while true
                item = pending === nothing ? take!(ch) : pending
                pending = nothing
                if item === :eof
                    break
                elseif item isa Tuple
                    throw(item[2])
                elseif item isa Symbol
                    if kind === :obs
                        s.stats.connected = (item === :connected)
                    end
                    item === :connected && _mark_stream_up!(s.stats, kind)
                else
                    got_data = true
                    batch = item
                    nmore = 0
                    while isready(ch) && nmore < 4096
                        nxt = take!(ch)
                        if nxt isa Vector{UInt8}
                            batch === item && (batch = copy(item))
                            append!(batch, nxt); nmore += 1
                        else
                            pending = nxt; break
                        end
                    end
                    lock(decoder_lock) do
                        _handle_bytes!(s, decoder, batch, kind)
                    end
                end
            end
            wait(producer)
            s.stop_requested[] || push!(s.stats.drop_log,
                "$(Dates.format(Dates.now(Dates.UTC), "HH:MM:SS"))Z [$label] caster closed the stream (EOF)")
            s.stop_requested[] ||
                @warn "NTRIP $label stream ended — reconnecting" caster=profile.caster
        catch err
            s.stats.error_message = "[$label] " * sprint(showerror, err)
            push!(s.stats.drop_log,
                "$(Dates.format(Dates.now(Dates.UTC), "HH:MM:SS"))Z [$label] " * first(sprint(showerror, err), 160))
            length(s.stats.drop_log) > 50 && popfirst!(s.stats.drop_log)
            occursin("stalled", sprint(showerror, err)) &&
                (s.stats.last_stall_at = Dates.now(Dates.UTC))
            s.stop_requested[] ||
                @warn "NTRIP $label stream dropped — reconnecting" err
        end
        s.stop_requested[] || _mark_stream_down!(s.stats, kind)
        s.stop_requested[] && break
        _bump_reconnects!(s.stats, kind)
        # A connection that delivered real data starts over at the minimum
        # delay; one that died without ever producing a byte backs off, so a
        # refusing or unreachable caster is not hammered once a second.
        delay = got_data ? profile.reconnect_min_delay_sec :
                           min(delay * 2, profile.reconnect_max_delay_sec)
        # Sleep in slices so Stop stays responsive during a long backoff.
        waited = 0.0
        while waited < delay && !s.stop_requested[]
            sleep(0.25)
            waited += 0.25
        end
    end
    if kind === :obs
        s.stats.connected = false
    end
end

# ---- Link metrics -----------------------------------------------------
_wall_utc_sod() = (u = Dates.now(Dates.UTC);
                   Dates.hour(u) * 3600 + Dates.minute(u) * 60 + Dates.second(u) + Dates.millisecond(u) / 1000)
# a − b for seconds-of-day, wrapped into (−43200, 43200].
function _sod_diff(a::Float64, b::Float64)
    d = a - b
    d > 43200 && (d -= 86400.0)
    d <= -43200 && (d += 86400.0)
    d
end
_stream_code(kind::Symbol) = kind === :obs ? 1.0 : kind === :ssr ? 2.0 : 3.0
# Outage bookkeeping: the reader loop calls down when a stream ends/drops and
# up when the next connection is established. One open outage per stream.
function _mark_stream_down!(st::SessionStats, kind::Symbol)
    k = _stream_code(kind)
    any(o -> o[3] == k && isnan(o[2]), st.outages) && return
    push!(st.outages, (_wall_utc_sod(), NaN, k))
    _cause_event!(:outage, 1, string(kind) * " stream dropped")
    length(st.outages) > 1000 && popfirst!(st.outages)
    return
end
function _mark_stream_up!(st::SessionStats, kind::Symbol)
    k = _stream_code(kind)
    for i in length(st.outages):-1:1
        o = st.outages[i]
        if o[3] == k && isnan(o[2])
            st.outages[i] = (o[1], _wall_utc_sod(), k)
            break
        end
    end
    return
end
# Process memory for the metrics CSV: RSS from /proc (cheap, but not every
# epoch) and the Julia live heap. The 2026-09-11 OOM (28 GB after 9 h) had
# no memory time series to look at — now every session records one.
const _RSS_CACHE = Ref((0.0, -1))   # (time, rss_mb)
function _rss_mb_cached()
    now = time()
    if now - _RSS_CACHE[][1] > 5.0
        mb = try; Int(round(parse(Int, split(read("/proc/self/statm", String))[2]) * 4096 / 1_048_576)); catch; -1; end
        _RSS_CACHE[] = (now, mb)
    end
    return _RSS_CACHE[][2]
end
# Called right after bridge_step! for the primary system's epoch.
const _METRICS_HEADER = "sod,wall_utc_sod,arrival_latency_s,solve_ms,mseed_latency_s,ssr_age_s,nsat,missing_cum,rebaselined_cum,backpressure_cum,outliers_cum,bytes_obs_cum,bytes_ssr_cum,bytes_eph_cum,rss_mb,gc_live_mb,live_stream_tasks,satflag_n,satflag_cum,satflag_maxz_mm,qgate_cum,ssr_msgs_cum,ssr_valid_sats,cpu_others_pct,cpu_self_pct,load1,mem_avail_mb"

# Forensics columns of the metrics CSV (plan item 8). SSR messages received so far
# (RTCM SSR families 1057-1068 GPS/GLONASS, 1240-1263 Galileo/QZSS/SBAS/BDS): a silent
# provider change of message set shows up as a rate change. NaN when nothing counted.
_is_ssr_msg(mt::Integer) = (1057 <= mt <= 1068) || (1240 <= mt <= 1263)
_ssr_msgs_total(st::SessionStats) = sum((n for (mt, n) in st.msg_counts if _is_ssr_msg(mt)); init = 0)

# "cpu_others,cpu_self,load1,mem_avail_mb" from the Health sampler (empty fields when it is not running).
function _health_csv_fields()
    h = isdefined(@__MODULE__, :_SYS_LATEST) ? _SYS_LATEST[] : nothing
    h === nothing && return "NaN,NaN,NaN,NaN"
    r(x) = isnan(x) ? "NaN" : string(round(x; digits = 1))
    return string(r(h.cpu_others), ',', r(h.cpu_self), ',', r(h.load1), ',', r(h.mem_avail_mb))
end

function _record_metrics!(s::NtripSession, sod::Float64, t_arr::Float64, solve_ms::Float64)
    st = s.stats
    epoch_utc = sod - GPS_UTC_LEAP_S
    arrival = _sod_diff(t_arr, epoch_utc)
    now = _wall_utc_sod()
    mseed_lat = st.mseed_last_flush_sod == sod ? _sod_diff(now, epoch_utc) : NaN
    ssr_age = isnan(st.last_ssr_stream_sod) ? NaN :
              _sod_diff(sod, mod(st.last_ssr_stream_sod, 86400.0))
    st.solve_ms_ema = isnan(st.solve_ms_ema) ? solve_ms : 0.98 * st.solve_ms_ema + 0.02 * solve_ms
    push!(st.metrics_history, (sod, now, arrival, solve_ms, mseed_lat, ssr_age, Float64(st.last_epoch_nsat)))
    _trim_history!(st.metrics_history)
    io = st.metrics_csv
    if io !== nothing
        try
            outl = s.bridge_state === nothing ? 0 : s.bridge_state.outlier_total
            sf = s.bridge_state === nothing ? nothing : s.bridge_state.satflag
            println(io, round(sod; digits = 1), ',', round(now; digits = 3), ',',
                    round(arrival; digits = 3), ',', round(solve_ms; digits = 1), ',',
                    round(mseed_lat; digits = 3), ',', round(ssr_age; digits = 1), ',',
                    st.last_epoch_nsat, ',', st.input_missing, ',', st.epochs_rebaselined, ',',
                    st.epochs_skipped_backpressure, ',', outl, ',',
                    st.bytes_obs, ',', st.bytes_ssr, ',', st.bytes_eph, ',',
                    _rss_mb_cached(), ',', round(Int, Base.gc_live_bytes() / 1e6), ',',
                    (isdefined(@__MODULE__, :_LIVE_TASKS) ? _LIVE_TASKS[] : 0), ',',
                    sf === nothing ? 0 : length(sf.prn), ',', sf === nothing ? 0 : sf.sat_flags, ',',
                    sf === nothing ? NaN : round(1000 * sf.maxz; digits = 1), ',',
                    s.bridge_state === nothing ? 0 : s.bridge_state.qgate.total, ',',
                    _ssr_msgs_total(st), ',',
                    s.bridge_state === nothing ? 0 : length(s.bridge_state.ssr_valid), ',',
                    _health_csv_fields())
            length(st.metrics_history) % 100 == 0 && flush(io)
        catch; end
    end
    return
end

function _bump_reconnects!(st::SessionStats, kind::Symbol)
    if     kind === :obs; st.reconnects_obs += 1
    elseif kind === :ssr; st.reconnects_ssr += 1
    else                  st.reconnects_eph += 1
    end
    return st
end

# True when an obs epoch's constellation is enabled for processing in this
# profile. Cheap gate used by backpressure/decimation to count only the
# epochs that would actually run the solve.
function _epoch_enabled(profile::NtripProfile, sys::Char)
    sys == 'G' ? profile.enable_gps :
    sys == 'R' ? profile.enable_glo :
    sys == 'E' ? profile.enable_gal :
    sys == 'C' ? profile.enable_bds : false
end

# The constellation whose epochs define "one measurement" for the
# completeness counters: GPS when enabled, else the first enabled system.
function _primary_sys(profile::NtripProfile)
    profile.enable_gps ? 'G' : profile.enable_gal ? 'E' :
    profile.enable_glo ? 'R' : profile.enable_bds ? 'C' : 'G'
end

# Count arrived and missing epochs from the SOD sequence of the primary
# system. The nominal interval is learned as the smallest positive step seen
# (10 Hz -> 0.1 s), a hole is any step > 1.5 intervals. Day wrap handled.
function _note_input_epoch!(st::SessionStats, sod::Float64)
    st.input_epochs += 1
    last = st.input_last_sod
    st.input_prev_sod = last
    st.input_last_sod = sod
    isnan(last) && return
    dt = sod - last
    dt < -43200 && (dt += 86400.0)
    dt <= 0.005 && return                       # duplicate / re-sent epoch
    iv = st.input_interval_s
    if isnan(iv) || dt < iv - 1e-6
        st.input_interval_s = round(dt; digits = 3)   # first step, or a finer rate than assumed
        return
    end
    if dt > 1.5 * iv
        nmiss = min(round(Int, dt / iv) - 1, 36_000)
        st.input_missing += nmiss
        lock(st.lock) do
            push!(st.input_gaps, (sod, nmiss))
            _trim_history!(st.input_gaps)
        end
        _cause_event!(:missing, nmiss, @sprintf("%d epochs missing before %.1f", nmiss, sod))
    end
    return
end

# Optional per-frame trace for stream forensics: set GAIASEIS_FRAME_TRACE to a
# file path and every received chunk and every emitted MSM epoch is logged
# with its wall-clock arrival (UTC seconds of day). Off unless the variable
# is set; the cost is one short line per chunk and per frame.
const _FRAME_TRACE = Ref{Union{IO,Nothing}}(nothing)
function _frame_trace_io()
    path = get(ENV, "GAIASEIS_FRAME_TRACE", "")
    isempty(path) && return nothing
    _FRAME_TRACE[] === nothing && (_FRAME_TRACE[] = open(path, "a"))
    return _FRAME_TRACE[]
end

# Seconds the newest received epoch may trail the wall clock before the
# session starts skipping older epochs to catch up (see _handle_bytes!).
const _CATCHUP_LATE_S = 1.5

# Catch-up on queue length (2026-10-21; before, ANY late batch was reduced to its
# newest epoch and the rest skipped, although the epochs were solvable). A late
# batch is solved in full when solving the whole backlog fits a time budget; only
# a backlog beyond it is shed. The budget is spent at the running per-epoch
# processing time, so a slow machine (ARM box, an overloaded CPU) still sheds
# early and the backlog spiral that backpressure exists to prevent cannot form.
const _CATCHUP_BUDGET_S = 1.0     # time the data thread may spend on one backlog
const _CATCHUP_MIN      = 10      # always solve at least this many (1 s at 10 Hz)
const _CATCHUP_MAX      = 300     # never more than this many epochs in one batch
const _CATCHUP_DEFAULT_MS = 40.0  # per-epoch time assumed before one is measured

function _catchup_limit(solve_ms_ema::Real)
    ms = (isfinite(solve_ms_ema) && solve_ms_ema > 0) ? solve_ms_ema : _CATCHUP_DEFAULT_MS
    return clamp(floor(Int, _CATCHUP_BUDGET_S * 1000 / ms), _CATCHUP_MIN, _CATCHUP_MAX)
end

# True when a late batch of `backlog` epochs must be shed (only the newest solved).
_shed_backlog(backlog::Integer, solve_ms_ema::Real) = backlog > _catchup_limit(solve_ms_ema)

# Epochs queued in a batch = the largest number of enabled epochs of any one
# constellation (each timestamp carries one frame per constellation).
function _backlog_epochs(events, profile::NtripProfile)
    cnt = Dict{Char,Int}()
    for ev in events
        ev isa EvEpoch && _epoch_enabled(profile, ev.sys) && (cnt[ev.sys] = get(cnt, ev.sys, 0) + 1)
    end
    return isempty(cnt) ? 0 : maximum(values(cnt))
end

function _handle_bytes!(s::NtripSession, decoder::RtcmDecoder, bytes, kind::Symbol)
    s.stats.bytes_received += length(bytes)
    # Per-stream timestamp — refreshed on every byte chunk so the GUI can
    # show "obs: 12:34:56 (0.4 s ago)" and flag stalled connections.
    now_utc = Dates.now(Dates.UTC)
    if     kind === :obs; s.stats.last_obs_byte_at = now_utc; s.stats.bytes_obs += length(bytes)
    elseif kind === :ssr; s.stats.last_ssr_byte_at = now_utc; s.stats.bytes_ssr += length(bytes)
    elseif kind === :eph; s.stats.last_eph_byte_at = now_utc; s.stats.bytes_eph += length(bytes)
    end
    events = feed_bytes!(decoder, view(bytes, 1:length(bytes)); stream = kind)
    trace = _frame_trace_io()
    if trace !== nothing
        tw = _wall_utc_sod()
        println(trace, tw, " chunk ", kind, " ", length(bytes))
        for ev in events
            ev isa EvEpoch && println(trace, tw, " frame ", kind, " ", ev.sys, " ", ev.epoch.sod, " ", length(ev.epoch.obs))
        end
        flush(trace)
    end
    s.stats.frames_total += length(events) +
                            (decoder.frames_crc_failed - s.stats.frames_crc_failed)
    s.stats.frames_crc_failed = decoder.frames_crc_failed
    s.stats.msg_counts = copy(decoder.msg_counts)
    s.stats.msg_counts_by = Dict(k => copy(v) for (k, v) in decoder.msg_counts_by)
    # Backpressure: which enabled-system EvEpoch is the LAST in this batch.
    # Under healthy 10 Hz a byte-chunk carries ~1 epoch; when the obs socket
    # has backed up (thread 1 fell behind), one feed yields many, and solving
    # every one keeps us behind forever. We solve only the newest enabled
    # epoch of the batch and skip the stale ones — the variometric filter
    # tolerates the larger time gap. Env GAIASEIS_BACKPRESSURE=0 disables.
    backpressure = get(ENV, "GAIASEIS_BACKPRESSURE", "1") != "0"
    last_enabled_epoch_idx = 0
    last_enabled_sod = NaN
    if backpressure
        for (idx, ev) in enumerate(events)
            if ev isa EvEpoch && _epoch_enabled(s.profile, ev.sys)
                last_enabled_epoch_idx = idx
                last_enabled_sod = _sod_gps(ev.sys, ev.epoch.sod)
            end
        end
        # Catch up only when genuinely behind: the newest epoch of the batch
        # is more than _CATCHUP_LATE_S behind the wall clock. A batch of two
        # epochs after a 100 ms hiccup (a plot redraw, a GC pause) is not a
        # backlog — both are solved. Without this test one epoch in six was
        # skipped on an idle machine (2026-09-12).
        if !isnan(last_enabled_sod)
            if _sod_diff(_wall_utc_sod(), last_enabled_sod - GPS_UTC_LEAP_S) < _CATCHUP_LATE_S
                backpressure = false
            else
                # Genuinely late. Solve the whole backlog when it fits the time
                # budget; shed only what exceeds it.
                backlog = _backlog_epochs(events, s.profile)
                if !_shed_backlog(backlog, s.stats.solve_ms_ema)
                    backpressure = false
                    s.stats.epochs_caught_up += max(backlog - 1, 0)
                end
            end
        end
    end

    for (idx, ev) in enumerate(events)
        if ev isa EvEpoch
            # Honour the actual RTCM number (1075/1077/1085/1087/…) so the
            # GUI's "last msg type" line reflects MSM5 vs MSM7 streams.
            s.stats.last_msg_type = ev.epoch.msg_type
            s.stats.last_obs_stream_sod = ev.epoch.sod
            ev.sys == _primary_sys(s.profile) && _note_input_epoch!(s.stats, ev.epoch.sod)
            # For GPS / Galileo / BeiDou MSM7, epoch_ms is the full
            # time-of-week in milliseconds — keep the unmodded value so
            # the GUI can recover the absolute day-of-week.
            if ev.sys == 'G' || ev.sys == 'E' || ev.sys == 'C'
                s.stats.last_obs_stream_tow = ev.epoch.epoch_ms * 1e-3
            end
            enabled = _epoch_enabled(s.profile, ev.sys)
            # Backpressure: an enabled epoch older than the newest one in
            # the same batch is backlog. It is still handed to the bridge —
            # its observations must land in data.obs so the epoch group
            # stays complete and the next solve differences against a full
            # epoch — but flagged stale so the bridge packs it without
            # solving. Frames at the newest timestamp are never stale.
            stale = backpressure && enabled && idx != last_enabled_epoch_idx &&
                    abs(_sod_wrap(_sod_gps(ev.sys, ev.epoch.sod) - last_enabled_sod)) > _group_tolerance(s)
            try
                t_arr = _wall_utc_sod()
                t0 = time()
                # Returns the GPS-scale SOD of the epoch group it solved, or
                # NaN when this frame only fed the group.
                solved_sod = bridge_step!(s, decoder, ev.epoch; stale = stale)
                if enabled && !isnan(solved_sod)
                    _record_metrics!(s, solved_sod, t_arr, (time() - t0) * 1000)
                end
            catch err
                @warn "bridge step failed" err
            end
        elseif ev isa EvSsrOrbit
            # SSR orbit-correction arrays carry a per-correction epoch_s.
            isempty(ev.corrections) || (s.stats.last_ssr_stream_sod = ev.corrections[end].epoch_s)
        elseif ev isa EvSsrClock
            isempty(ev.corrections) || (s.stats.last_ssr_stream_sod = ev.corrections[end].epoch_s)
        elseif ev isa EvEphemeris
            # row[39] = TOC as seconds-of-day in the constellation's time
            # scale (mod 86400). Skip when the decoder couldn't populate it.
            length(ev.record.row) >= 39 && !isnan(ev.record.row[39]) &&
                (s.stats.last_eph_stream_sod = ev.record.row[39])
            # row[2] = absolute GPS week (stashed by decode_1019); refresh
            # the session's week anchor whenever a GPS LNAV arrives so the
            # GUI can date-tag every other stream.
            if ev.record.sys == 'G' && length(ev.record.row) >= 2 &&
               !isnan(ev.record.row[2]) && ev.record.row[2] > 0
                s.stats.gps_week = Int(ev.record.row[2])
            end
        elseif ev isa EvStation || ev isa EvDescriptor
            # No timestamp on these — bridge picks them up at the next bridge_step!
        elseif ev isa EvOther
            s.stats.last_msg_type = ev.msg_type
        end
    end
end
