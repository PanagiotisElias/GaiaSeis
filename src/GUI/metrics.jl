# ---------------------------------------------------------------------------
# Metrics window + /metrics.json + /metrics.png — link latency, loss, delays.
#
# Everything here reads `session.stats.metrics_history` (filled by
# `_record_metrics!` in session.jl on every solved primary-system epoch),
# `input_gaps`, `outages` and the byte counters. Nothing is measured here;
# the window only summarises, plots and writes the summary to a file so
# that different connection types (caster, port, TLS, network path, message
# set) can be compared run against run. The per-epoch CSV
# (`<profile>_metrics_<ts>.csv`) is the raw material for
# `tools/metrics_compare.py`.
# ---------------------------------------------------------------------------

# Indices into the metrics tuple.
const _M_SOD = 1; const _M_WALL = 2; const _M_ARR = 3; const _M_SOLVE = 4
const _M_MSEED = 5; const _M_SSR = 6; const _M_NSAT = 7

# Last `span_s` seconds of metrics by wall clock (NaN-safe day wrap).
function _metrics_window(hist::Vector{NTuple{7,Float64}}, span_s::Float64)
    isempty(hist) && return hist
    span_s <= 0 && return hist
    newest = hist[end][_M_WALL]
    i = length(hist)
    while i > 1
        age = newest - hist[i-1][_M_WALL]
        age < 0 && (age += 86400.0)
        age > span_s && break
        i -= 1
    end
    return hist[i:end]
end

function _pctl(v::Vector{Float64}, p::Float64)
    isempty(v) && return NaN
    s = sort(v); k = clamp(round(Int, p * (length(s) - 1)) + 1, 1, length(s))
    return s[k]
end
_finite(v) = Float64[x for x in v if !isnan(x)]

# Numbers for one window: NamedTuple with everything the text/JSON need.
function _metrics_numbers(sess, span_s::Float64)
    st = sess.stats
    h = _metrics_window(st.metrics_history, span_s)
    arr = _finite([t[_M_ARR] for t in h]); solve = _finite([t[_M_SOLVE] for t in h])
    tot = _finite([t[_M_ARR] + t[_M_SOLVE] / 1000 for t in h])
    ms  = _finite([t[_M_MSEED] for t in h]); ssr = _finite([t[_M_SSR] for t in h])
    # miniSEED write part = on-disk latency − (arrival + solve), per epoch that was flushed
    wr  = _finite([t[_M_MSEED] - (t[_M_ARR] + t[_M_SOLVE] / 1000) for t in h])
    stat(v) = (n = length(v), med = _pctl(v, 0.5), p95 = _pctl(v, 0.95), max = isempty(v) ? NaN : maximum(v),
               mean = isempty(v) ? NaN : sum(v) / length(v))
    jitter = length(arr) > 2 ? sqrt(sum((arr .- sum(arr) / length(arr)).^2) / (length(arr) - 1)) : NaN
    # loss inside the window: holes whose first missing epoch lies in the window
    miss_win = 0
    if !isempty(h)
        t_lo = h[1][_M_SOD]
        for (gs, nm) in st.input_gaps
            d = gs - t_lo; d < -43200 && (d += 86400.0)
            d >= 0 && (miss_win += nm)
        end
    end
    n_epochs = length(h)
    # outages
    now = _wall_utc_sod()
    odur = Float64[]; open_out = 0
    for o in st.outages
        if isnan(o[2]); open_out += 1; push!(odur, max(_sod_diff(now, o[1]), 0.0))
        else push!(odur, max(_sod_diff(o[2], o[1]), 0.0)) end
    end
    dh = lock(() -> copy(st.mseed_delivery_history), st.lock)
    dlv = if isempty(dh) || isempty(h); Float64[]
          else
              t_lo = h[1][_M_WALL]
              _finite([d[2] for d in dh if (x = d[1] - t_lo; x < -43200 && (x += 86400.0); span_s <= 0 || x >= 0)])
          end
    return (span_s = span_s, n = n_epochs, delivery = stat(dlv),
            arrival = stat(arr), solve_ms = stat(solve), total = stat(tot), mseed = stat(ms), ssr_age = stat(ssr),
            write = stat(wr),
            jitter_s = jitter,
            missing_win = miss_win, missing_pct_win = 100.0 * miss_win / max(n_epochs + miss_win, 1),
            missing_total = st.input_missing, epochs_total = st.input_epochs,
            missing_pct_total = 100.0 * st.input_missing / max(st.input_epochs + st.input_missing, 1),
            outliers = sess.bridge_state === nothing ? 0 : sess.bridge_state.outlier_total,
            rebaselined = st.epochs_rebaselined, backpressure = st.epochs_skipped_backpressure,
            reconnects = (st.reconnects_obs, st.reconnects_ssr, st.reconnects_eph),
            outages = length(st.outages), outages_open = open_out,
            outage_total_s = sum(odur; init = 0.0), outage_max_s = isempty(odur) ? 0.0 : maximum(odur),
            bytes = (st.bytes_obs, st.bytes_ssr, st.bytes_eph),
            frames = st.frames_total, bad_crc = st.frames_crc_failed,
            interval_s = st.input_interval_s)
end

# Throughput needs two snapshots; the window keeps the previous one.
mutable struct _RateSnap; t::Float64; b::NTuple{3,Int}; rate::NTuple{3,Float64}; end
function _update_rate!(rs::_RateSnap, st)
    now = time(); b = (st.bytes_obs, st.bytes_ssr, st.bytes_eph)
    dt = now - rs.t
    if rs.t > 0 && dt >= 1.0
        rs.rate = ((b[1] - rs.b[1]) / dt, (b[2] - rs.b[2]) / dt, (b[3] - rs.b[3]) / dt)
        rs.t = now; rs.b = b
    elseif rs.t == 0
        rs.t = now; rs.b = b
    end
    rs.rate
end

_f(x, d = 3) = isnan(x) ? "   —  " : @sprintf("%*.*f", 6, d, x)
function _metrics_summary_text(sess, span_s::Float64; rate = (NaN, NaN, NaN))
    sess === nothing && return "no session"
    p = sess.profile; m = _metrics_numbers(sess, span_s); a = _metrics_numbers(sess, 0.0)
    io = IOBuffer()
    println(io, "GaiaSeis link metrics — ", p.name, "   ", Dates.format(Dates.now(Dates.UTC), "yyyy-mm-dd HH:MM:SS"), "Z")
    println(io, "link ", isempty(p.link_description) ? "(no link description in the profile)" : p.link_description)
    println(io, "obs  ", p.caster, ":", p.port, "/", p.mountpoint, p.use_tls ? " (TLS)" : "", "   ",
            p.use_ssr ? "ssr " * p.ssr_caster * ":" * string(p.ssr_port) * "/" * p.ssr_mountpoint : "no SSR", "   ",
            p.use_eph ? "eph " * p.eph_caster * ":" * string(p.eph_port) * "/" * p.eph_mountpoint : "no EPH")
    println(io, @sprintf("epoch interval %s s   mode %s   flush %g s   rate hint %g Hz", _f(m.interval_s, 3), p.process_mode, p.miniseed_flush_interval_sec, p.miniseed_sample_rate_hz))
    println(io)
    println(io, @sprintf("%-26s %8s %8s %8s %8s %6s   | %8s %8s %8s %6s", "", "median", "p95", "max", "mean", "n", "median", "p95", "max", "n"))
    println(io, @sprintf("%-26s %35s   | %s", "", "last $(round(Int, span_s)) s", "whole session"))
    row(name, w, s, unit) = println(io, @sprintf("%-26s %8s %8s %8s %8s %6d   | %8s %8s %8s %6d  %s", name, _f(w.med), _f(w.p95), _f(w.max), _f(w.mean), w.n, _f(s.med), _f(s.p95), _f(s.max), s.n, unit))
    row("arrival latency", m.arrival, a.arrival, "s   (wall UTC at receipt − epoch)")
    row("solve time", m.solve_ms, a.solve_ms, "ms")
    row("total delay to solution", m.total, a.total, "s")
    row("miniSEED write latency", m.mseed, a.mseed, "s   (record on disk − epoch)")
    row("miniSEED → live client", m.delivery, a.delivery, "s   (bytes sent to /mseed/live − epoch)")
    row("SSR correction age", m.ssr_age, a.ssr_age, "s")
    println(io, @sprintf("%-26s %8s   (std of arrival latency, last window)", "jitter", _f(m.jitter_s)))
    println(io)
    # Delay chain: the parts add up to the end-to-end "epoch → record on disk".
    # Medians of parts do not add exactly (median of a sum ≠ sum of medians);
    # the mean column does, up to epochs without a flushed record.
    sm, sa = m.solve_ms.med / 1000, m.solve_ms.mean / 1000
    println(io, "delay chain (last window)          median      mean")
    println(io, @sprintf("  receiver → GaiaSeis (arrival)   %8s  %8s  s", _f(m.arrival.med), _f(m.arrival.mean)))
    println(io, @sprintf("  + solve                         %8s  %8s  s", _f(sm), _f(sa)))
    println(io, @sprintf("  + miniSEED write                %8s  %8s  s", _f(m.write.med), _f(m.write.mean)))
    println(io, @sprintf("  = sum of parts                  %8s  %8s  s", _f(m.arrival.med + sm + m.write.med), _f(m.arrival.mean + sa + m.write.mean)))
    println(io, @sprintf("  measured epoch → record on disk %8s  %8s  s   (n=%d)", _f(m.mseed.med), _f(m.mseed.mean), m.mseed.n))
    println(io, @sprintf("  SSR correction age (parallel, not additive) %8s s", _f(m.ssr_age.med)))
    println(io)
    println(io, @sprintf("data loss  window: %d missing of %d (%.2f %%)   session: %d missing of %d (%.2f %%)",
            m.missing_win, m.n + m.missing_win, m.missing_pct_win, a.missing_total, a.epochs_total + a.missing_total, a.missing_pct_total))
    println(io, @sprintf("           outliers %d   re-baselined after long holes %d   backpressure skips %d", a.outliers, a.rebaselined, a.backpressure))
    println(io, @sprintf("streams    reconnects obs/ssr/eph %d/%d/%d   outages %d (open %d)  total %.1f s  longest %.1f s",
            a.reconnects[1], a.reconnects[2], a.reconnects[3], a.outages, a.outages_open, a.outage_total_s, a.outage_max_s))
    println(io, @sprintf("throughput obs %.1f kB/s  ssr %.1f kB/s  eph %.1f kB/s   (session bytes %d / %d / %d, frames %d, bad CRC %d)",
            rate[1] / 1000, rate[2] / 1000, rate[3] / 1000, a.bytes[1], a.bytes[2], a.bytes[3], a.frames, a.bad_crc))
    println(io, "csv        ", sess.stats.metrics_csv_path)
    println(io)
    println(io, "note: median = typical epoch; p95 = 95th percentile, i.e. 95 % of epochs were at or below this value and")
    println(io, "      5 % were worse — the figure a real-time consumer has to tolerate; max = the single worst epoch.")
    return String(take!(io))
end

function _metrics_json(sess)
    sess === nothing && return "{\"running\":false}"
    m = _metrics_numbers(sess, 60.0); a = _metrics_numbers(sess, 0.0)
    j(x) = isnan(x) ? "null" : string(round(x; digits = 4))
    st(name, s) = string("\"", name, "\":{\"median\":", j(s.med), ",\"p95\":", j(s.p95), ",\"max\":", j(s.max), ",\"mean\":", j(s.mean), ",\"n\":", s.n, "}")
    blk(x) = string("{", join([st("arrival_latency_s", x.arrival), st("solve_ms", x.solve_ms), st("total_delay_s", x.total),
                                st("mseed_write_s", x.write), st("mseed_latency_s", x.mseed), st("ssr_age_s", x.ssr_age),
                                st("mseed_delivery_s", x.delivery)], ","),
                    ",\"sum_of_parts_s\":{\"median\":", j(x.arrival.med + x.solve_ms.med / 1000 + x.write.med),
                    ",\"mean\":", j(x.arrival.mean + x.solve_ms.mean / 1000 + x.write.mean), "}",
                    ",\"jitter_s\":", j(x.jitter_s), ",\"missing\":", x.missing_win, ",\"missing_pct\":", j(x.missing_pct_win), ",\"epochs\":", x.n, "}")
    return string("{\"running\":", isrunning(sess) ? "true" : "false",
                  ",\"profile\":\"", _json_escape(sess.profile.name), "\"",
                  ",\"link\":\"", _json_escape(sess.profile.link_description), "\"",
                  ",\"last_60s\":", blk(m), ",\"session\":", blk(a),
                  ",\"missing_total\":", a.missing_total, ",\"epochs_total\":", a.epochs_total,
                  ",\"outliers\":", a.outliers, ",\"rebaselined\":", a.rebaselined, ",\"backpressure\":", a.backpressure,
                  ",\"reconnects\":[", join(a.reconnects, ","), "],\"outages\":", a.outages, ",\"outage_total_s\":", j(a.outage_total_s),
                  ",\"bytes\":[", join(a.bytes, ","), "],\"csv\":\"", _json_escape(sess.stats.metrics_csv_path), "\"}")
end

# ---- Drawing: three stacked panels over the selected span --------------
function _draw_metrics(cr, w::Float64, h::Float64, sess, settings::PlotSettings)
    Main.Gtk4.set_source_rgb(cr, 1.0, 1.0, 1.0); Main.Gtk4.rectangle(cr, 0, 0, w, h); Main.Gtk4.fill(cr)
    Main.Cairo.select_font_face(cr, "sans-serif", 0, 0); Main.Cairo.set_font_size(cr, 11.0)
    if sess === nothing || isempty(sess.stats.metrics_history)
        Main.Gtk4.set_source_rgb(cr, 0.5, 0.5, 0.5); Main.Gtk4.move_to(cr, 20, 30)
        Main.Cairo.show_text(cr, "(no metrics yet — start a stream)"); return
    end
    st = sess.stats
    hist = _metrics_window(st.metrics_history, settings.timespan_sec)
    length(hist) < 2 && return
    ml, mr, mt, mb, gap = 64.0, 12.0, 20.0, 30.0, 26.0
    ph = (h - mt - mb - 2gap) / 3; pw = w - ml - mr
    (ph < 20 || pw < 20) && return
    t0 = hist[1][_M_WALL]; tn = hist[end][_M_WALL]
    tn < t0 && (tn += 86400.0)
    tspan = max(tn - t0, 1.0)
    xof(t) = (d = t - t0; d < 0 && (d += 86400.0); ml + pw * d / tspan)
    function panel(idx, title, series, unit; bars = nothing, ymin_fixed = 0.0, extra = nothing)
        top = mt + (idx - 1) * (ph + gap); bot = top + ph
        vals = Float64[]
        for (_, ys, _) in series; append!(vals, _finite(ys)); end
        bars !== nothing && append!(vals, Float64[b[2] for b in bars])
        extra !== nothing && for (_, _, ys, _) in extra; append!(vals, _finite(ys)); end
        # y-range from the 99th percentile so one JIT/stall spike does not
        # flatten everything else; the spike is still visible as a clipped run.
        ymax = isempty(vals) ? 1.0 : max(_pctl(vals, 0.99) * 1.25, 1e-6); ymin = ymin_fixed
        yof(v) = bot - ph * (v - ymin) / (ymax - ymin)
        Main.Gtk4.set_source_rgb(cr, 0.93, 0.93, 0.93); Main.Gtk4.rectangle(cr, ml, top, pw, ph); Main.Gtk4.fill(cr)
        Main.Gtk4.set_source_rgb(cr, 0.75, 0.75, 0.75); Main.Gtk4.set_line_width(cr, 0.6)
        for k in 0:4
            y = top + ph * k / 4; Main.Gtk4.move_to(cr, ml, y); Main.Gtk4.line_to(cr, ml + pw, y); Main.Gtk4.stroke(cr)
            Main.Gtk4.set_source_rgb(cr, 0.3, 0.3, 0.3); Main.Gtk4.move_to(cr, 4, y + 4)
            yv = ymax - (ymax - ymin) * k / 4
            Main.Cairo.show_text(cr, yv >= 100 ? @sprintf("%.0f", yv) : @sprintf("%.3g", yv)); Main.Gtk4.set_source_rgb(cr, 0.75, 0.75, 0.75)
        end
        step = _nice_time_step(tspan); tt = ceil(t0 / step) * step
        while tt <= t0 + tspan
            x = xof(tt); Main.Gtk4.move_to(cr, x, top); Main.Gtk4.line_to(cr, x, bot); Main.Gtk4.stroke(cr)
            if idx == 3
                Main.Gtk4.set_source_rgb(cr, 0.3, 0.3, 0.3); Main.Gtk4.move_to(cr, x - 22, bot + 14)
                Main.Cairo.show_text(cr, _sod_to_hms(mod(tt, 86400.0))); Main.Gtk4.set_source_rgb(cr, 0.75, 0.75, 0.75)
            end
            tt += step
        end
        # outages as shaded bands (obs red, ssr orange, eph grey)
        for o in st.outages
            a = o[1]; b = isnan(o[2]) ? tn : o[2]
            da = a - t0; da < 0 && (da += 86400.0); db = b - t0; db < 0 && (db += 86400.0)
            (db < 0 || da > tspan) && continue
            c = o[3] == 1.0 ? (0.9, 0.3, 0.3) : o[3] == 2.0 ? (0.95, 0.65, 0.2) : (0.6, 0.6, 0.6)
            Main.Cairo.set_source_rgba(cr, c[1], c[2], c[3], 0.25)
            x1 = ml + pw * max(da, 0.0) / tspan; x2 = ml + pw * min(db, tspan) / tspan
            Main.Gtk4.rectangle(cr, x1, top, max(x2 - x1, 1.0), ph); Main.Gtk4.fill(cr)
        end
        if bars !== nothing
            Main.Gtk4.set_source_rgb(cr, 0.85, 0.2, 0.15)
            for (t, v, wdt) in bars
                x = xof(t); Main.Gtk4.rectangle(cr, x, yof(v), max(pw * wdt / tspan, 1.5), bot - yof(v)); Main.Gtk4.fill(cr)
            end
        end
        for (rgb, ys, lab) in series
            Main.Gtk4.set_source_rgb(cr, rgb...); Main.Gtk4.set_line_width(cr, 1.2); moving = false
            lod = _lod_indices(Float64[t[_M_WALL] for t in hist], ys, t0, tspan, pw)
            for i in lod
                v = ys[i]; if isnan(v); moving = false; continue; end
                x = xof(hist[i][_M_WALL]); y = max(yof(min(v, ymax)), top)
                moving ? Main.Gtk4.line_to(cr, x, y) : (Main.Gtk4.move_to(cr, x, y); moving = true)
            end
            Main.Gtk4.stroke(cr)
        end
        # series on their own time base (wall sod), e.g. miniSEED delivery
        if extra !== nothing
            for (rgb, ts, ys, _) in extra
                Main.Gtk4.set_source_rgb(cr, rgb...); Main.Gtk4.set_line_width(cr, 1.2); moving = false
                for i in eachindex(ts)
                    v = ys[i]; d = ts[i] - t0; d < 0 && (d += 86400.0)
                    if isnan(v) || d > tspan; moving = false; continue; end
                    x = ml + pw * d / tspan; y = max(yof(min(v, ymax)), top)
                    moving ? Main.Gtk4.line_to(cr, x, y) : (Main.Gtk4.move_to(cr, x, y); moving = true)
                end
                Main.Gtk4.stroke(cr)
            end
        end
        Main.Gtk4.set_source_rgb(cr, 0.15, 0.15, 0.15); Main.Gtk4.move_to(cr, ml + 6, top - 6)
        Main.Cairo.show_text(cr, title * "  [" * unit * "]")
        x = ml + pw - 6
        legend = collect(series)
        extra !== nothing && append!(legend, [(rgb, ys, lab) for (rgb, _, ys, lab) in extra])
        for (rgb, _, lab) in reverse(legend)
            ext = Main.Cairo.text_extents(cr, lab); x -= ext[3] + 18
            Main.Gtk4.set_source_rgb(cr, rgb...); Main.Gtk4.rectangle(cr, x, top - 14, 10, 3); Main.Gtk4.fill(cr)
            Main.Gtk4.set_source_rgb(cr, 0.15, 0.15, 0.15); Main.Gtk4.move_to(cr, x + 14, top - 6); Main.Cairo.show_text(cr, lab)
        end
    end
    arr = Float64[t[_M_ARR] for t in hist]; tot = Float64[t[_M_ARR] + t[_M_SOLVE] / 1000 for t in hist]
    msl = Float64[t[_M_MSEED] for t in hist]; slv = Float64[t[_M_SOLVE] for t in hist]; ssr = Float64[t[_M_SSR] for t in hist]
    # The first minute of a session is catch-up (connection, backlog, warm-up):
    # its latencies are not the link's and would set the y scale. Hidden from
    # the latency panel (statistics and the CSV keep them).
    if st.started_at != DateTime(0)
        ss = st.started_at - (Dates.now() - Dates.now(Dates.UTC))          # session start in UTC
        ss_sod = Dates.value(ss - DateTime(Dates.Date(ss))) / 1000
        for i in eachindex(hist)
            d = hist[i][_M_WALL] - ss_sod; d < -43200 && (d += 86400.0)
            if 0 <= d < 60.0
                arr[i] = NaN; tot[i] = NaN; msl[i] = NaN
            end
        end
    end
    dh = lock(() -> copy(st.mseed_delivery_history), st.lock)
    extra = isempty(dh) ? nothing : [((0.9, 0.55, 0.1), Float64[d[1] for d in dh], Float64[d[2] for d in dh], "miniSEED -> live client")]
    panel(1, "Latency vs epoch time (bands: stream outages)", [((0.1, 0.35, 0.85), arr, "arrival"), ((0.1, 0.6, 0.2), tot, "solution"), ((0.85, 0.2, 0.15), msl, "miniSEED on disk")], "s"; extra = extra)
    # missing epochs per 10 s bin, in wall time of the epoch after the hole
    iv = isnan(st.input_interval_s) ? 0.1 : st.input_interval_s
    bins = Dict{Float64,Float64}()
    for (gs, nm) in st.input_gaps
        # map SOD (GPS) to wall: use the newest sample's wall−sod offset
        off = hist[end][_M_WALL] - hist[end][_M_SOD]
        tw = gs + off; b = floor(tw / 10) * 10
        bins[b] = get(bins, b, 0.0) + nm
    end
    bars = [(b, v, 10.0) for (b, v) in bins]
    panel(2, "Missing epochs per 10 s (from the receiver/caster)", Tuple{NTuple{3,Float64},Vector{Float64},String}[], "epochs"; bars = bars)
    panel(3, "Solve time and SSR correction age", [((0.55, 0.2, 0.7), slv, "solve ms"), ((0.5, 0.5, 0.5), ssr, "SSR age s")], "ms | s")
    return
end

# ---- Help window: what every parameter and diagram means -----------------
const _METRICS_HELP = """
WHAT IS MEASURED
  Every solved epoch of the primary constellation (GPS unless disabled) gets one metrics record.
  All times are wall-clock UTC on this machine; the epoch time is GPS time converted to UTC (−18 s).

PARAMETERS
  arrival latency      Wall time when the epoch's RTCM frame was received − the epoch's own time stamp.
                       = receiver + caster + network. It is the delay GaiaSeis cannot change.
  solve time (ms)      Time spent computing the displacement for the epoch (decode of the batch, orbit/clock
                       modelling, variometric least squares, outlier guard). Normally 5-20 ms; the very
                       first epoch of a session takes seconds (just-in-time compilation) — ignore it.
  total delay          arrival latency + solve time: the age of the displacement when it is available.
  miniSEED write       On-disk latency − (arrival + solve): the sink's own share, i.e. the time a sample
  (part)               waits in the record buffer. Zero-ish with flush interval 0, up to the flush interval otherwise.
  miniSEED write       Wall time when the record holding the epoch reached the disk − the epoch time.
  latency              This is what a consumer of the miniSEED files or of /mseed/live experiences.
                       NaN for epochs whose record was not flushed yet (flush interval > 0).
  SSR correction age   Epoch time − time stamp of the newest SSR orbit/clock correction in hand.
                       Runs in parallel to the chain above (not additive); 5-15 s is normal for a 5-s SSR stream.
  jitter               Standard deviation of the arrival latency in the window. Large jitter with a small
                       median means bursts and stalls (typical for an overloaded receiver caster).
  delay chain          The parts added up (arrival + solve + write) next to the independently measured
                       epoch → record-on-disk latency. Medians of parts do not add exactly; means do.

STATISTICS  (each row: last window | whole session)
  median   the typical epoch (half the epochs were faster, half slower). Robust to spikes.
  p95      95th percentile: 95 % of the epochs were at or below this value, 5 % were worse.
           This is the number a real-time consumer must tolerate.
  max      the single worst epoch in the window.
  mean     the arithmetic average — pulled up by spikes; compare with the median to see how spiky the link is.
  n        number of epochs in the statistic.

DATA LOSS
  missing              Epochs that never arrived from the receiver/caster: holes in the epoch time sequence,
                       counted before any processing. Percent = missing / (received + missing).
  outliers             Epochs flagged by the MAD amplitude test (kept, not blanked since 2026-10-20; epochs blanked by the quality gate are the qgate_cum column of the CSV).
  re-baselined         Epochs after a hole longer than max_gap_epochs: no solution, the chain restarts.
  backpressure skips   Epochs GaiaSeis dropped because it fell behind (must stay 0; if not, the machine is overloaded).

STREAMS
  reconnects           obs / ssr / eph reconnections since Start.
  outages              Periods a stream was down: count, total seconds, longest. "open" = down right now.
  throughput           kB/s per stream over the last few seconds; session totals in bytes; frames and bad CRC.

DIAGRAMS  (x axis = wall-clock UTC of the epoch; span from the Span box)
  1  Latency            blue   = arrival latency
                        green  = total delay to solution (arrival + solve)
                        red    = epoch → record on disk (miniSEED)
                        Shaded bands = stream outages (red obs, orange SSR, grey eph).
                        A staircase rising then dropping = the caster stalled and then delivered a burst.
  2  Missing epochs     red bars = epochs missing from the input per 10 s (0 = perfect stream).
  3  Solve / SSR age    purple = solve time in ms; grey = SSR correction age in s.
  The y axis of each panel spans the 99th percentile of its data, so a single spike (e.g. the first-epoch
  compile) is clipped at the top instead of flattening everything else.

MINISEED TIME  (how a sample gets its time stamp, and where the delays are)
  1  The receiver time-tags the epoch in GPS time (e.g. 08:49:06.8 GPS). GPS time is 18 s ahead of UTC.
  2  GaiaSeis converts it to UTC when it writes the record: 08:48:48.8 UTC. Everything a consumer reads
     (record start time, sample times) is UTC. Files written before 2026-09-10 10:00 UTC are stamped in
     GPS time, i.e. 18 s too late — re-import them with the time corrected or discard them.
  3  A record holds one start time plus a fixed rate; sample i is implicitly at start + i/rate. Inside a
     record nothing waits: the sample's time is its epoch time, whatever the delay was in getting it.
  4  The record is written to disk when it is full (112 samples) or when flush_interval_sec has passed
     since its first sample — with flush 0 that is immediately, one record per epoch.
  5  "miniSEED write latency" = the wall-clock UTC moment the record reached the disk − the UTC time of
     the epoch. It is the total age of that sample for anyone tailing the file or /mseed/live.
  6  Missing epochs and epochs blanked by the quality gate are not written; the writer closes the record
     and starts a new one at the true time of the next sample (time tear), so consumers see a gap of
     k × 0.1 s — never a time-shifted sample.
  7  The session log's SOD column, the plot time axes and the metrics "sod" stay in GPS time
     (receiver time); only the miniSEED files, the miniSEED CSV (iso_utc) and the wall-clock columns are UTC.

THE MINISEED DELAYS IN DETAIL  (what adds up, what decides each part, what you can do about it)

  A sample's age when it becomes usable = (a) + (b) + (c) + (d) + (e):

  (a) receiver internal        The receiver measures the epoch, computes the observables and encodes the
      ~0.1-0.5 s               RTCM frame. Fixed by the receiver firmware and its output-rate settings;
                               not visible separately here, it is inside the arrival latency.
  (b) caster + network         From the receiver's output port through the caster to this machine's socket.
      ~0.2-1 s normally,       This is the bulk of the arrival latency. Stalls show as a rising staircase
      stalls to 10-15 s        in panel 1 (the data waits in a buffer, then arrives in a burst — every epoch
                               of the burst gets a large latency, and often some are missing at the end).
                               Decided by: receiver caster load (number of clients!), uplink quality,
                               relay casters in between, TLS handshakes on reconnect.
      arrival latency = (a)+(b) — median 0.7 s on UPA10Z with one client; p95 up to 10 s under stalls.
  (c) solve                    Decoding the batch, orbit/clock modelling, variometric least squares,
      5-20 ms                  outlier guard. Grows with satellites and constellations; the first epoch
                               after Start costs seconds (compilation) — ignore it in comparisons.
  (d) record-buffer wait       The sample sits in the writer's buffer until the record is closed:
      0 with flush 0           closed immediately (flush_interval_sec = 0, EEW setting), or when 112 samples
      up to flush_interval_sec are in, or when flush_interval_sec has elapsed since the record's FIRST
                               sample. With flush 5 the first sample of a record waits 5 s, the last ~0 s
                               (average ≈ half the interval). This is the "miniSEED write (part)" line.
                               A missing epoch closes the record early (time tear) — no extra wait.
  (e) disk / OS                write() + flush() to the file: tens of microseconds on a local disk; the
      ≈0 locally               data is visible to any local reader at once (page cache). On a network
                               file system (NFS/SMB) add its own commit delay.
  miniSEED write latency = (a)+(b)+(c)+(d)+(e)  — the red curve in panel 1; the "measured epoch →
                           record on disk" line in the delay chain. With flush 0 it equals the total
                           delay to solution within a millisecond.

  Then the consumer adds its own share, which GaiaSeis cannot see:
    ringserver MSeedScan     scans the directory at its own interval (typically 1 s) → +0-1 s, then SeedLink
                             delivers the 512-byte record at once.
    /mseed/live over HTTP    the record is pushed the moment it is written (chunked stream) → +network
                             RTT, as long as the consumer HOLDS the connection open (a poll loop that
                             re-opens the URL every second adds a full second and re-reads the file).
    /mseed/download or file  copies whatever is on disk when asked → + the poll interval.
    SeisComP / seis2k        their own buffering, sorting (scmssort), and event-detector windows.

  Worked example (UPA10Z, flush 0, one client, 08:49:06.8 GPS epoch):
    epoch (UTC)                       08:48:48.800
    frame received                    08:48:49.480   (arrival latency 0.68 s = a+b)
    solution ready                    08:48:49.487   (solve 7 ms)
    record on disk                    08:48:49.487   (write part 0.0 s, disk ≈0)      → mseed latency 0.687 s
    ringserver forwards               08:48:49.5-50.5 (its scan interval)
    seismologist's SeedLink client    ≈ 1-2 s after the ground actually moved.
  Same epoch with flush 5 s: the sample could wait until 08:48:54 → mseed latency up to 5.7 s.

  How to reduce it:  flush 0 (done for EEW); one client on the receiver caster; no relay caster in the
  path; hold /mseed/live open instead of polling; keep the solve small (GPS+GAL is fine, all four
  constellations cost more); do not run other CPU-heavy work on this machine (backpressure skips > 0
  means the solve is queueing behind the GUI or the web renderer).

  Reading the statistics:  compare the median (typical) with the p95 (what a consumer must tolerate);
  a link with median 0.7 s and p95 10 s is worse for EEW than one with median 1.2 s and p95 1.5 s.

COMPARING LINKS
  Fill in the profile's Link description, run each link for the same duration, then
  python3 tools/metrics_compare.py logs/<profile>_metrics_*.csv ...   prints the runs side by side.
  "Write summary to file" saves exactly this window's numbers with the link description.
"""

function _open_metrics_help(Gtk4)
    win = Gtk4.GtkWindow("GaiaSeis — Link metrics: what the numbers mean", 980, 720)
    Gtk4.set_gtk_property!(win, :modal, false)
    _apply_window_icon!(Gtk4, win)
    # Same construction as the About window: a GtkScrolledWindow takes its
    # single child via setindex! (`scrolled[] = view`); push! leaves it empty.
    scrolled = Gtk4.GtkScrolledWindow()
    Gtk4.set_gtk_property!(scrolled, :vexpand, true)
    Gtk4.set_gtk_property!(scrolled, :hexpand, true)
    buffer = Gtk4.GtkTextBuffer()
    view   = Gtk4.GtkTextView(buffer)
    Gtk4.set_gtk_property!(view, :monospace, true)
    Gtk4.set_gtk_property!(view, :editable, false)
    Gtk4.set_gtk_property!(view, :cursor_visible, false)
    Gtk4.set_gtk_property!(view, :wrap_mode, 0)
    for prop in (:left_margin, :right_margin, :top_margin, :bottom_margin); Gtk4.set_gtk_property!(view, prop, 10); end
    scrolled[] = view
    push!(win, scrolled)
    try
        Gtk4.set_gtk_property!(buffer, :text, _METRICS_HELP)
    catch
        try; Gtk4.G_.set_text(buffer, _METRICS_HELP, Cint(-1)); catch; end
    end
    Gtk4.show(win)
    return win
end

# ---- Window --------------------------------------------------------------
function _open_metrics_window(state, Gtk4)
    win = Gtk4.GtkWindow("GaiaSeis — Link metrics", 1000, 760)
    Gtk4.set_gtk_property!(win, :modal, false)
    _apply_window_icon!(Gtk4, win)
    settings = PlotSettings(); settings.timespan_sec = 300.0
    outer = Gtk4.GtkBox(:v); Gtk4.set_gtk_property!(outer, :spacing, 4); push!(win, outer)
    tb = Gtk4.GtkBox(:h); Gtk4.set_gtk_property!(tb, :spacing, 6)
    for prop in (:margin_top, :margin_bottom, :margin_start, :margin_end); Gtk4.set_gtk_property!(tb, prop, 6); end
    push!(outer, tb)
    push!(tb, Gtk4.GtkLabel("Span:"))
    cmb = Gtk4.GtkComboBoxText(); for s in ("Last 1 min", "Last 5 min", "Last 10 min", "Last 30 min"); push!(cmb, s); end
    Gtk4.set_gtk_property!(cmb, :active, 1); push!(tb, cmb)
    btn_write = Gtk4.GtkButton("Write summary to file"); push!(tb, btn_write)
    btn_pause = Gtk4.GtkToggleButton("Pause"); push!(tb, btn_pause)
    btn_help = Gtk4.GtkButton("Explain…"); push!(tb, btn_help)
    Gtk4.set_gtk_property!(btn_help, :tooltip_text, "What every parameter, statistic and diagram means")
    lbl_file = Gtk4.GtkLabel(""); Gtk4.set_gtk_property!(lbl_file, :hexpand, true); Gtk4.set_gtk_property!(lbl_file, :xalign, 1.0); push!(tb, lbl_file)
    lbl = Gtk4.GtkLabel(""); Gtk4.set_gtk_property!(lbl, :use_markup, true); Gtk4.set_gtk_property!(lbl, :xalign, 0.0)
    Gtk4.set_gtk_property!(lbl, :margin_start, 8); Gtk4.set_gtk_property!(lbl, :selectable, true)
    push!(outer, lbl)
    cv = Gtk4.GtkCanvas(600, 380); Gtk4.set_gtk_property!(cv, :hexpand, true); Gtk4.set_gtk_property!(cv, :vexpand, true); push!(outer, cv)
    rs = _RateSnap(0.0, (0, 0, 0), (NaN, NaN, NaN))
    Gtk4.draw(cv) do widget
        try
            cr = Gtk4.getgc(widget); w = Float64(Gtk4.width(widget)); h = Float64(Gtk4.height(widget))
            _draw_metrics(cr, w, h, state[:session], settings)
        catch err
            @warn "metrics draw failed" err
        end
    end
    esc(s) = replace(replace(replace(s, "&" => "&amp;"), "<" => "&lt;"), ">" => "&gt;")
    span_of() = (60.0, 300.0, 600.0, 1800.0)[clamp(Gtk4.get_gtk_property(cmb, :active, Int) + 1, 1, 4)]
    function refresh!()
        sess = state[:session]
        settings.timespan_sec = span_of()
        rate = sess === nothing ? (NaN, NaN, NaN) : _update_rate!(rs, sess.stats)
        Gtk4.set_gtk_property!(lbl, :label, "<tt><small>" * esc(_metrics_summary_text(sess, min(settings.timespan_sec, 600.0); rate = rate)) * "</small></tt>")
        Gtk4.draw(cv)
    end
    @gs_guarded Gtk4.signal_connect(cmb, "changed") do _; refresh!(); end
    @gs_guarded Gtk4.signal_connect(btn_help, "clicked") do _; _open_metrics_help(Gtk4); end
    @gs_guarded Gtk4.signal_connect(btn_write, "clicked") do _
        sess = state[:session]
        sess === nothing && return
        dir = isempty(sess.stats.metrics_csv_path) ? pwd() : dirname(sess.stats.metrics_csv_path)
        path = joinpath(dir, "$(_safe_filename(sess.profile.name))_metrics_summary_$(Dates.format(Dates.now(), "yyyymmdd_HHMMSS")).txt")
        try
            open(path, "w") do io
                print(io, _metrics_summary_text(sess, span_of(); rate = rs.rate))
                println(io); println(io, "----- 60 s window -----"); print(io, _metrics_summary_text(sess, 60.0; rate = rs.rate))
            end
            Gtk4.set_gtk_property!(lbl_file, :label, "written: " * path)
        catch err
            Gtk4.set_gtk_property!(lbl_file, :label, "write failed: " * sprint(showerror, err))
        end
    end
    closed = Ref(false)
    @gs_guarded Gtk4.signal_connect(win, "close-request") do _
        closed[] = true; return false
    end
    @gs_guarded true Gtk4.GLib.g_timeout_add(1000) do
        closed[] && return false
        Gtk4.get_gtk_property(btn_pause, :active, Bool) || refresh!()
        return true
    end
    refresh!()
    Gtk4.show(win)
    return win
end
