# Replay of a shaking-table GNSS log through the GaiaSeis bridge with the
# GaiaVario engine, compared with the table accelerometer. Driven by run.sh:
#
#   julia --project=. examples/shaking_table/replay.jl DUMP NAV.rnx HEADER.txt ACCEL.mseed OUT_PREFIX DATE T0_UTC T1_UTC "TITLE"
#
# DUMP     observation dump of the receiver's RINEX log (crx_to_dump.py), read
#          with the GaiaVario tools' obs_dump.jl into the platform's MsmEpoch
#          objects, i.e. the observations enter through the adapters used for RTCM
# NAV.rnx  daily broadcast ephemerides (RINEX 3), scheduled by time of clock
# HEADER   RINEX header of the log (APPROX POSITION XYZ, ANT # / TYPE, REC # / TYPE / VERS)
# ACCEL    table accelerometer, float64 miniSEED (HNE, HNN, HNZ in m/s^2)
# DATE     day of the log (yyyy-mm-dd); T0/T1 window in UTC seconds of day
# TITLE    the input motion, e.g. "Samos 2020 (HL.TNSA)", for the figure and the summary
#
# Outputs: OUT_PREFIX_solution.csv (per-epoch rows as in examples/replay_capture.jl),
# OUT_PREFIX_displacement.csv (10 Hz grid: GNSS and accelerometer displacement,
# band-passed), OUT_PREFIX.png (or .svg when Cairo cannot be loaded) and a summary.

using GaiaSeis, Dates, Printf
const G = GaiaSeis

length(ARGS) == 9 || (println(stderr, "usage: replay.jl DUMP NAV HEADER ACCEL OUT_PREFIX DATE T0_UTC T1_UTC TITLE"); exit(1))
dump_path, nav_path, header_path, accel_path, prefix = ARGS[1:5]
date = Date(ARGS[6]); t0u = parse(Float64, ARGS[7]); t1u = parse(Float64, ARGS[8]); title = ARGS[9]
const LEAP = G.GPS_UTC_LEAP_S
const HP_HZ = 0.1; const LP_HZ = 2.0           # band of the comparison (zero-phase)
const FS = 10.0
const MARGIN = 30.0                            # seconds solved beyond the window so that the filter edges stay outside it
t_run = time()

# ---------------------------------------------------------------- engine and GaiaVario tools
sibling = normpath(joinpath(@__DIR__, "..", "..", "..", "GaiaVario.jl"))
gv_dir = get(ENV, "GAIAVARIO_DIR", isdir(sibling) ? sibling : "")
isempty(gv_dir) || (gv_dir = abspath(expanduser(gv_dir)))
antex = normpath(joinpath(@__DIR__, "..", "..", "igs14_2163.atx"))
profile = G.NtripProfile(name = "TABLE", caster = "replay", mountpoint = "replay",
                         engine = "gaiavario", engine_mode = "l1gf", engine_path = gv_dir,
                         antex_file = isfile(antex) ? antex : "", elv_cutoff_deg = 10.0,
                         enable_gps = true, enable_glo = true, enable_gal = true, enable_bds = true,
                         use_ssr = false, use_eph = false,
                         miniseed_mseed_dir = "", miniseed_csv_path = "", datalink_host = "")
G._load_engine!(profile)                       # `using GaiaVario` in Main
const GV = Main.GaiaVario
tools = joinpath(isempty(gv_dir) ? pkgdir(GV) : gv_dir, "tools")
isfile(joinpath(tools, "obs_dump.jl")) || error("GaiaVario tools not found in $tools (set GAIAVARIO_DIR)")
include(joinpath(tools, "live_common.jl"))     # epoch_time
include(joinpath(tools, "rinex_nav_rows.jl"))  # rinex_nav_rows, NavSchedule, advance!
include(joinpath(tools, "obs_dump.jl"))        # read_obs_dump

# ---------------------------------------------------------------- station, time, ephemerides
hdr = readlines(header_path)
field(label) = (i = findfirst(l -> occursin(label, l), hdr); i === nothing ? "" : hdr[i][1:min(60, end)])
X, Y, Z = parse.(Float64, split(field("APPROX POSITION XYZ")))
ant = rstrip(field("ANT # / TYPE")[21:40]); rec = rstrip(field("REC # / TYPE / VERS")[21:40])
days = (date - Date(1980, 1, 6)).value
week = div(days, 7); day_tow = mod(days, 7) * 86400.0
tsolve0 = day_tow + t0u - MARGIN + LEAP        # first epoch reported
tw0 = tsolve0 - 60.0                           # first epoch handled (engine warm-up)
tw1 = day_tow + t1u + MARGIN + LEAP

recs = rinex_nav_rows(nav_path)
sched = NavSchedule(recs)
glo_k = Dict{Int,Int}(r[2] => Int(round(r[4][2])) for r in recs if r[1] == 'R')
println("station $(strip(field("MARKER NAME")[1:20])): $rec, $ant; $(length(recs)) broadcast records; GPS week $week")

session = G.NtripSession(profile)
session.stats = G.SessionStats(started_at = Dates.now())
session.bridge_state = nothing
decoder = G.RtcmDecoder()
decoder.station = G.StationCoord(1, X, Y, Z, NaN)
decoder.descriptor = G.StationDescriptor(1, ant, "", rec, "", "")
primary = G._primary_sys(profile)

# ---------------------------------------------------------------- replay
io = open(prefix * "_solution.csv", "w")
println(io, "# GaiaSeis replay of $(basename(dump_path))  engine=gaiavario mode=l1gf  (increments dN dE dU in metres; N E U = running sum)")
println(io, "utc,sod_gps,dN,dE,dU,N,E,U,nsat_used,pdop,rms_m")
rows = NTuple{4,Float64}[]                     # (utc sod, dN, dE, dU) of the reported epochs
nrows = 0; nsolved = 0; nerr = 0; sumsats = 0; sumsq = zeros(3); cum = zeros(3)
last_t = -Inf
for ep in read_obs_dump(dump_path, week, glo_k)
    t = epoch_time(ep.sys, ep.epoch_ms, week).tow
    (isfinite(t) && tw0 <= t <= tw1) || continue
    if t > last_t                              # ephemerides whose time of clock has been reached
        for (sys, prn, toc, row) in advance!(sched, GV.GpsTime(week, t))
            decoder.eph[(sys, prn)] = G.EphemerisRecord(sys, prn, copy(row), true)
        end
        global last_t = t
    end
    ep.sys == primary && G._note_input_epoch!(session.stats, ep.sod)
    sod = try
        G.bridge_step!(session, decoder, ep; stale = false)
    catch err
        global nerr += 1; nerr <= 3 && @warn "bridge step failed" err; NaN
    end
    (isnan(sod) || t < tsolve0) && continue
    global nrows += 1
    state = session.bridge_state
    xs = state.last_xs
    dneu = (NaN, NaN, NaN)
    if length(xs) >= 3 && !any(isnan, xs[1:3])
        A = G._ecef2neu_matrix(state.rec_pos)
        dneu = (A[1,1]*xs[1] + A[1,2]*xs[2] + A[1,3]*xs[3], A[2,1]*xs[1] + A[2,2]*xs[2] + A[2,3]*xs[3],
                A[3,1]*xs[1] + A[3,2]*xs[2] + A[3,3]*xs[3])
    end
    dh = session.stats.dop_history; pdop = (!isempty(dh) && dh[end][1] == sod) ? dh[end][4] : NaN
    rh = session.stats.residual_history; rms = (!isempty(rh) && rh[end][1] == sod) ? rh[end][3] : NaN
    solved = all(isfinite, dneu)
    if solved
        global nsolved += 1; cum .+= dneu; sumsq .+= dneu .^ 2; global sumsats += state.last_sno
    end
    utc = DateTime(date) + Dates.Millisecond(round(Int64, (sod - LEAP) * 1000))
    push!(rows, (sod - LEAP, dneu...))
    @printf(io, "%s,%.1f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%.2f,%.4f\n", Dates.format(utc, "yyyy-mm-ddTHH:MM:SS.s"), sod,
            dneu[1], dneu[2], dneu[3], solved ? cum[1] : NaN, solved ? cum[2] : NaN, solved ? cum[3] : NaN, state.last_sno, pdop, rms)
end
close(io)
t_replay = time() - t_run

# ---------------------------------------------------------------- displacement on a 10 Hz grid, band-passed
gext = collect(t0u - MARGIN:1/FS:t1u + MARGIN)  # filtered on the extended grid, reported on [t0u, t1u]
inc = zeros(length(gext), 3); have_ext = falses(length(gext))
for (t, dn, de, du) in rows
    k = round(Int, (t - gext[1]) * FS) + 1
    (1 <= k <= length(gext) && isfinite(dn)) || continue
    inc[k, :] .= (dn, de, du); have_ext[k] = true
end
sel = [t0u <= t <= t1u for t in gext]
grid = gext[sel]; have = have_ext[sel]; ng = length(grid)

# Zero-phase band-pass in the frequency domain (fourth-order Butterworth
# magnitudes, no phase), the same operator for both series; `integrate` = 2
# multiplies by 1/(i w)^2, i.e. the accelerometer is integrated twice inside the
# same pass-band. The mean of the first five seconds is removed first.
function fft!(a::Vector{ComplexF64})                 # iterative radix-2, length a power of two
    n = length(a); j = 1
    for i in 1:n-1
        if i < j; a[i], a[j] = a[j], a[i]; end
        m = n >> 1
        while m >= 1 && j > m; j -= m; m >>= 1; end
        j += m
    end
    len = 2
    while len <= n
        w = cis(-2pi / len)
        for s in 1:len:n
            wk = 1.0 + 0.0im
            for k in 0:len÷2-1
                u = a[s+k]; v = a[s+k+len÷2] * wk
                a[s+k] = u + v; a[s+k+len÷2] = u - v
                wk *= w
            end
        end
        len <<= 1
    end
    return a
end
function bandpass(x::Vector{Float64}, fs::Float64; integrate::Int = 0)
    n = length(x); N = 2 * nextpow(2, n)
    m0 = sum(x[1:min(n, round(Int, 5fs))]) / min(n, round(Int, 5fs))
    X = zeros(ComplexF64, N); X[1:n] .= x .- m0
    fft!(X)
    for k in 0:N-1
        f = (k <= N ÷ 2 ? k : k - N) * fs / N
        h = (f / HP_HZ)^4 / (1 + (f / HP_HZ)^4) / (1 + (f / LP_HZ)^4)
        integrate > 0 && (h = f == 0 ? 0.0 : h * real((im * 2pi * f)^(-integrate)))
        X[k+1] *= h
    end
    fft!(conj!(X))                                   # inverse transform through the conjugate
    return [real(X[i]) / N for i in 1:n]
end

gnss = hcat([bandpass(cumsum(inc[:, c]), FS)[sel] for c in 1:3]...)      # m, N E U

# ---------------------------------------------------------------- table accelerometer (float64 miniSEED)
function read_mseed_f64(path)
    data = read(path); out = Dict{String,Vector{Tuple{Float64,Float64,Vector{Float64}}}}()
    be(T, b, o) = ntoh(reinterpret(T, b[o:o+sizeof(T)-1])[1])
    for off in 1:512:length(data)-511
        r = @view data[off:off+511]
        r[7] in UInt8['D', 'R', 'Q', 'M'] || continue
        cha = strip(String(r[16:18]))
        yr = be(UInt16, r, 21); doy = be(UInt16, r, 23); hh = r[25]; mm = r[26]; ss = r[27]; frac = be(UInt16, r, 29)
        ns = be(UInt16, r, 31); sf = be(Int16, r, 33); sm = be(Int16, r, 35)
        doff = be(UInt16, r, 45); boff = be(UInt16, r, 47)
        enc = -1; micro = 0
        while boff != 0
            bt = be(UInt16, r, boff + 1); nxt = be(UInt16, r, boff + 3)
            bt == 1000 && (enc = r[boff + 5]); bt == 1001 && (micro = reinterpret(Int8, r[boff + 6]))
            boff = nxt
        end
        enc == 5 || error("$path: encoding $enc is not float64")
        rate = (sf > 0 ? Float64(sf) : 1 / -sf) * (sm > 0 ? sm : 1 / -sm)
        t0 = hh * 3600.0 + mm * 60.0 + ss + frac * 1e-4 + micro * 1e-6      # UTC seconds of day
        (Date(Int(yr)) + Day(doy - 1)) == date || continue
        x = [ntoh(reinterpret(Float64, data[off+doff+8(i-1):off+doff+8i-1])[1]) for i in 1:ns]
        push!(get!(out, cha, Tuple{Float64,Float64,Vector{Float64}}[]), (t0, rate, x))
    end
    return out
end
acc = read_mseed_f64(accel_path)
function accel_series(cha, ta, tb)                                      # samples of [ta, tb] on the file's own rate
    recs = sort(acc[cha]; by = r -> r[1]); rate = recs[1][2]
    n = round(Int, (tb - ta) * rate) + 1; x = fill(NaN, n)
    for (t0, _, s) in recs
        for (i, v) in enumerate(s)
            k = round(Int, (t0 + (i - 1) / rate - ta) * rate) + 1
            1 <= k <= n && (x[k] = v)
        end
    end
    any(isnan, x) && error("accelerometer gap in the window")
    return rate, x
end
function accel_disp(cha)                             # displacement of the table on the GNSS grid
    rate, a = accel_series(cha, t0u - 90, t1u + 90)
    d = bandpass(a, rate; integrate = 2)
    return [d[round(Int, (t - (t0u - 90)) * rate) + 1] for t in grid]
end
cha_of(c) = (k = findfirst(k -> endswith(k, c), collect(keys(acc))); k === nothing ? error("no $c channel") : collect(keys(acc))[k])
table = hcat(accel_disp(cha_of("N")), accel_disp(cha_of("E")), accel_disp(cha_of("Z")))

# ---------------------------------------------------------------- statistics
hms(s) = Dates.format(DateTime(date) + Dates.Millisecond(round(Int64, 1000s)), "HH:MM:SS.s")
env = sqrt.(table[:, 1] .^ 2 .+ table[:, 2] .^ 2)
sm = [sum(env[max(1, i - 100):min(ng, i + 100)] .^ 2) / (min(ng, i + 100) - max(1, i - 100) + 1) for i in 1:ng]
tpk = grid[argmax(sm)]
strong = [tpk - 25 <= t <= tpk + 35 for t in grid]
peak(x) = (i = argmax(abs.(x)); (1000 * x[i], grid[i]))
function corr(a, b)
    ma = sum(a) / length(a); mb = sum(b) / length(b)
    sum((a .- ma) .* (b .- mb)) / sqrt(sum((a .- ma) .^ 2) * sum((b .- mb) .^ 2))
end
pg = [peak(gnss[:, c]) for c in 1:3]; pt = [peak(table[:, c]) for c in 1:3]
hg = peak(sqrt.(gnss[:, 1] .^ 2 .+ gnss[:, 2] .^ 2)); ht = peak(sqrt.(table[:, 1] .^ 2 .+ table[:, 2] .^ 2))
cc = [corr(gnss[strong, c], table[strong, c]) for c in 1:3]
rmse = [1000 * sqrt(sum((gnss[strong, c] .- table[strong, c]) .^ 2) / count(strong)) for c in 1:3]
quiet = [t0u + 10 <= t <= tpk - 40 for t in grid]
noise = [1000 * sqrt(sum(gnss[quiet, c] .^ 2) / count(quiet)) for c in 1:3]
tnoise = [1000 * sqrt(sum(table[quiet, c] .^ 2) / count(quiet)) for c in 1:3]

open(prefix * "_displacement.csv", "w") do f
    println(f, "# displacement [mm] on a $(FS) Hz grid, band $(HP_HZ)-$(LP_HZ) Hz zero-phase; GNSS = GaiaVario l1gf increments summed; table = accelerometer integrated twice")
    println(f, "utc_sod,gnss_N,gnss_E,gnss_U,table_N,table_E,table_U,gnss_epoch")
    for i in 1:ng
        @printf(f, "%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d\n", grid[i], 1000gnss[i, 1], 1000gnss[i, 2], 1000gnss[i, 3],
                1000table[i, 1], 1000table[i, 2], 1000table[i, 3], have[i])
    end
end

# ---------------------------------------------------------------- figure (Cairo from the platform's own environment; SVG otherwise)
W, H = 1400, 900
cairo = try
    Base.require(Base.PkgId(Base.UUID("159f3aea-2a34-519c-b102-8c37f9878175"), "Cairo"))
catch
    nothing
end
# A drawing context with the few Cairo calls used below, or an SVG writer with the same names.
mutable struct SvgCtx; buf::IOBuffer; rgb::NTuple{3,Float64}; lw::Float64; fs::Float64; path::Vector{String}; end
if cairo === nothing
    cr = SvgCtx(IOBuffer(), (0, 0, 0), 1.0, 12.0, String[])
    print(cr.buf, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$W\" height=\"$H\" font-family=\"sans-serif\">\n")
    col(c) = @sprintf("rgb(%d,%d,%d)", round(Int, 255c.rgb[1]), round(Int, 255c.rgb[2]), round(Int, 255c.rgb[3]))
    set_source_rgb(c, r, g, b) = (c.rgb = (r, g, b))
    set_line_width(c, w) = (c.lw = w)
    set_font_size(c, s) = (c.fs = s)
    move_to(c, x, y) = push!(c.path, @sprintf("M%.1f %.1f", x, y))
    line_to(c, x, y) = push!(c.path, @sprintf("L%.1f %.1f", x, y))
    stroke(c) = (print(c.buf, "<path d=\"", join(c.path, " "), "\" fill=\"none\" stroke=\"", col(c), "\" stroke-width=\"$(c.lw)\"/>\n"); empty!(c.path))
    rectangle(c, x, y, w, h) = push!(c.path, @sprintf("M%.1f %.1f L%.1f %.1f L%.1f %.1f L%.1f %.1f Z", x, y, x + w, y, x + w, y + h, x, y + h))
    fillpath(c) = (print(c.buf, "<path d=\"", join(c.path, " "), "\" fill=\"", col(c), "\"/>\n"); empty!(c.path))
    show_text(c, s) = (m = match(r"M([\d.]+) ([\d.]+)", c.path[end]); print(c.buf, "<text x=\"$(m[1])\" y=\"$(m[2])\" font-size=\"$(c.fs)\" fill=\"", col(c), "\">", replace(s, "<" => "&lt;", "&" => "&amp;"), "</text>\n"); empty!(c.path))
    finish(c, path) = (print(c.buf, "</svg>\n"); write(path, take!(c.buf)))
    figpath = prefix * ".svg"
else
    C = cairo
    surf = C.CairoARGBSurface(W, H); cr = C.CairoContext(surf)
    set_source_rgb(c, r, g, b) = C.set_source_rgb(c, r, g, b); set_line_width(c, w) = C.set_line_width(c, w)
    set_font_size(c, s) = C.set_font_size(c, s); move_to(c, x, y) = C.move_to(c, x, y); line_to(c, x, y) = C.line_to(c, x, y)
    stroke(c) = C.stroke(c); rectangle(c, x, y, w, h) = C.rectangle(c, x, y, w, h); fillpath(c) = C.fill(c)
    show_text(c, s) = C.show_text(c, s); finish(c, path) = C.write_to_png(surf, path)
    C.select_font_face(cr, "sans-serif", 0, 0)
    figpath = prefix * ".png"
end

set_source_rgb(cr, 1, 1, 1); rectangle(cr, 0, 0, W, H); fillpath(cr)
left, right, top, ph, gap = 80, W - 30, 50, 240, 30
set_source_rgb(cr, 0, 0, 0); set_font_size(cr, 15); move_to(cr, left, 24)
show_text(cr, "$title on the Timisoara shaking table, TM0J13ROU (Topcon NET-G5, 10 Hz): " *
              "GaiaSeis + GaiaVario l1gf (blue) vs table accelerometer (black), $(HP_HZ)-$(LP_HZ) Hz")
for (ci, name) in enumerate(("North", "East", "Up"))
    y0 = top + (ci - 1) * (ph + gap); ym = y0 + ph / 2
    lim = max(1.0, 1.15 * maximum(abs, vcat(gnss[:, ci], table[:, ci])) * 1000)
    set_source_rgb(cr, 0.55, 0.55, 0.55); set_line_width(cr, 1); rectangle(cr, left, y0, right - left, ph); stroke(cr)
    set_source_rgb(cr, 0.85, 0.85, 0.85); move_to(cr, left, ym); line_to(cr, right, ym); stroke(cr)
    xs(t) = left + (right - left) * (t - t0u) / (t1u - t0u)
    for t in ceil(t0u / 60) * 60:60:t1u          # minute ticks
        set_source_rgb(cr, 0.85, 0.85, 0.85); move_to(cr, xs(t), y0); line_to(cr, xs(t), y0 + ph); stroke(cr)
        set_source_rgb(cr, 0.3, 0.3, 0.3); set_font_size(cr, 11); move_to(cr, xs(t) - 22, y0 + ph + 14); show_text(cr, hms(t)[1:8])
    end
    set_source_rgb(cr, 0.3, 0.3, 0.3); set_font_size(cr, 11)
    move_to(cr, 8, y0 + 12); show_text(cr, @sprintf("+%.0f mm", lim)); move_to(cr, 8, y0 + ph - 2); show_text(cr, @sprintf("-%.0f mm", lim))
    move_to(cr, 8, ym + 4); show_text(cr, name)
    function trace(x, r, g, b, w)
        set_source_rgb(cr, r, g, b); set_line_width(cr, w)
        move_to(cr, xs(grid[1]), ym - ph / 2 * clamp(1000x[1] / lim, -1, 1))
        for i in 2:ng; line_to(cr, xs(grid[i]), ym - ph / 2 * clamp(1000x[i] / lim, -1, 1)); end
        stroke(cr)
    end
    trace(table[:, ci], 0, 0, 0, 1.6); trace(gnss[:, ci], 0.12, 0.37, 0.75, 1.0)
    set_source_rgb(cr, 0.12, 0.37, 0.75); set_font_size(cr, 12); move_to(cr, left + 8, y0 + 16)
    show_text(cr, @sprintf("GNSS peak %.1f mm, table peak %.1f mm; strong motion (60 s): r = %.3f, RMSE %.1f mm", abs(pg[ci][1]), abs(pt[ci][1]), cc[ci], rmse[ci]))
end
set_source_rgb(cr, 0.3, 0.3, 0.3); set_font_size(cr, 12); move_to(cr, left, H - 16)
show_text(cr, @sprintf("UTC %s to %s on %s; strong motion %s to %s; %d of %d epochs solved; table axes taken as N/E (no rotation fitted)",
                       hms(t0u)[1:8], hms(t1u)[1:8], date, hms(tpk - 25)[1:8], hms(tpk + 35)[1:8], nsolved, nrows))
finish(cr, figpath)

# ---------------------------------------------------------------- summary
info = session.bridge_state === nothing ? "engine not started" : session.bridge_state.engine_info
rmsmm(i) = nsolved > 0 ? 1000 * sqrt(sumsq[i] / nsolved) : NaN
println()
@printf("%s on the shaking table, TM0J13ROU (%s): %s through the GaiaSeis bridge\n", title, rec, info)
@printf("epochs    : %d solved of %d in %s-%s UTC (%.1f %%), %.1f satellites used, RMS increments %.2f/%.2f/%.2f mm, %d step errors\n",
        nsolved, nrows, hms(t0u - MARGIN)[1:8], hms(t1u + MARGIN)[1:8], 100nsolved / max(nrows, 1), sumsats / max(nsolved, 1), rmsmm(1), rmsmm(2), rmsmm(3), nerr)
@printf("GNSS peak : N %6.1f mm at %s   E %6.1f mm at %s   U %6.1f mm at %s   horizontal %.1f mm at %s\n",
        pg[1][1], hms(pg[1][2]), pg[2][1], hms(pg[2][2]), pg[3][1], hms(pg[3][2]), hg[1], hms(hg[2]))
@printf("table peak: N %6.1f mm at %s   E %6.1f mm at %s   U %6.1f mm at %s   horizontal %.1f mm at %s\n",
        pt[1][1], hms(pt[1][2]), pt[2][1], hms(pt[2][2]), pt[3][1], hms(pt[3][2]), ht[1], hms(ht[2]))
@printf("agreement : correlation N %.3f  E %.3f  U %.3f, RMSE %.1f/%.1f/%.1f mm over the 60 s of strong motion (%s-%s)\n",
        cc[1], cc[2], cc[3], rmse[1], rmse[2], rmse[3], hms(tpk - 25)[1:8], hms(tpk + 35)[1:8])
@printf("quiet     : displacement RMS before the event, GNSS %.2f/%.2f/%.2f mm, table %.2f/%.2f/%.2f mm (%s-%s)\n",
        noise[1], noise[2], noise[3], tnoise[1], tnoise[2], tnoise[3], hms(t0u + 10)[1:8], hms(tpk - 40)[1:8])
@printf("outputs   : %s_solution.csv, %s_displacement.csv, %s  (replay %.0f s, total %.0f s)\n", prefix, prefix, figpath, t_replay, time() - t_run)
