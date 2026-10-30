# Offline replay of a raw RTCM capture through the GaiaSeis platform with the
# GaiaVario engine plug-in: the same decoder, epoch grouping, bridge, quality
# gate and miniSEED writer as a live session, driven from a file instead of a
# caster. No credentials or network access are needed.
#
#   julia --project=. examples/replay_capture.jl <capture.bin> [--mode l1gf|single|dual|mean]
#                     [--minutes N] [--out solution.csv] [--mseed DIR]
#
# Capture format (written by the platform's raw logger, logs/rtcm_raw_<stamp>.bin):
# a sequence of records  Float64 wall time (Unix s)  UInt8 stream (0 = observations,
# 1 = ephemerides)  UInt32 length  bytes. The example asset upc10z_10min_20261029.bin
# (examples/fetch_example_data.sh) is ten minutes of a Topcon NET-G5 at 10 Hz with
# GPS, GLONASS, Galileo and BeiDou MSM7 and the broadcast ephemerides.
#
# Output CSV, one row per solved epoch group:
#   utc, sod_gps, dN, dE, dU, N, E, U, nsat_used, pdop, rms_m
# dN dE dU are the per-epoch displacement increments [m] the platform logs,
# plots and streams (the variometric solution: position change between two
# consecutive epochs; NaN when the quality gate blanked the epoch), N E U their
# running sum from the first solved epoch, pdop the PDOP of the satellites
# used and rms_m the weighted RMS of the post-fit residuals [m].
#
# --mseed DIR writes the same increments as three miniSEED channels (LNN, LNE,
# LNZ, network XX, station RPLAY, counts = metres x 1e7, header rate = the
# epoch rate learned from the stream) with the platform's own writer
# (src/miniseed.jl). The bridge's live sink is not used here because it stamps
# samples with the wall-clock date of the running session; the replay stamps
# them with the date of the capture.

using GaiaSeis, Dates, Printf
const G = GaiaSeis

# ---------------------------------------------------------------- arguments
function usage()
    println(stderr, "usage: julia --project=. examples/replay_capture.jl <capture.bin> [--mode l1gf|single|dual|mean] [--minutes N] [--out solution.csv] [--mseed DIR]")
    exit(1)
end
isempty(ARGS) && usage()
function parse_args(args)
    capture = ""; mode = "l1gf"; minutes = Inf; outpath = "solution.csv"; mseed_dir = ""
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--mode";        mode = args[i += 1]
        elseif a == "--minutes"; minutes = parse(Float64, args[i += 1])
        elseif a == "--out";     outpath = args[i += 1]
        elseif a == "--mseed";   mseed_dir = args[i += 1]
        elseif startswith(a, "--"); println(stderr, "unknown option $a"); usage()
        else capture = a
        end
        i += 1
    end
    return capture, mode, minutes, outpath, mseed_dir
end
capture, mode, minutes, outpath, mseed_dir = parse_args(ARGS)
(isempty(capture) || !isfile(capture)) && (println(stderr, "capture file not found: $capture"); usage())
mode in ("l1gf", "single", "dual", "mean") || (println(stderr, "unknown mode $mode"); usage())

# ---------------------------------------------------------------- session
# The engine plug-in is loaded from the active environment; a sibling checkout
# of GaiaVario.jl (as in the source tree) is offered as engine_path otherwise.
sibling = normpath(joinpath(@__DIR__, "..", "..", "GaiaVario.jl"))
antex = normpath(joinpath(@__DIR__, "..", "igs14_2163.atx"))
profile = G.NtripProfile(name = "REPLAY", caster = "replay", mountpoint = "replay",
                         engine = "gaiavario", engine_mode = mode,
                         engine_path = isdir(sibling) ? sibling : "",
                         antex_file = isfile(antex) ? antex : "",
                         elv_cutoff_deg = 10.0,
                         enable_gps = true, enable_glo = true, enable_gal = true, enable_bds = true,
                         use_ssr = false, use_eph = false,
                         miniseed_mseed_dir = "", miniseed_csv_path = "", datalink_host = "")
session = G.NtripSession(profile)
session.stats = G.SessionStats(started_at = Dates.now())
session.bridge_state = nothing
decoder = G.RtcmDecoder()
primary = G._primary_sys(profile)
leap = G.GPS_UTC_LEAP_S                      # GPS time - UTC

# UTC time of an epoch: the date comes from the capture's wall clock, the
# seconds of day from the observation epoch (GPS time scale for the primary
# system, 18 s ahead of UTC).
function epoch_utc(wall::Float64, sod::Float64)
    w = Dates.unix2datetime(wall)
    t = DateTime(Date(w)) + Dates.Millisecond(round(Int64, (sod - leap) * 1000))
    d = Dates.value(t - w)
    d >  43_200_000 && (t -= Dates.Day(1))
    d < -43_200_000 && (t += Dates.Day(1))
    return t
end

# ---------------------------------------------------------------- outputs
io = open(outpath, "w")
println(io, "# GaiaSeis replay of $(basename(capture))  engine=gaiavario mode=$mode  (increments dN dE dU in metres; N E U = running sum)")
println(io, "utc,sod_gps,dN,dE,dU,N,E,U,nsat_used,pdop,rms_m")

writers = nothing                            # miniSEED writers, created at the first finite epoch
function mseed_push!(ts::DateTime, N, E, U)
    global writers
    if writers === nothing
        iv = session.stats.input_interval_s
        rate = (isfinite(iv) && iv > 0) ? round(1.0 / iv; digits = 3) : 10.0
        mkpath(mseed_dir)
        mk(ch) = G.MiniSEEDWriter(mseed_dir, "XX", "RPLAY", "", ch, rate; flush_interval_sec = 10.0)
        writers = (N = mk("LNN"), E = mk("LNE"), Z = mk("LNZ"))
        println("miniSEED: $(mseed_dir) at $(rate) Hz (XX.RPLAY..LN?)")
    end
    cnt(x) = Int32(clamp(round(Int64, x * 1e7), typemin(Int32), typemax(Int32)))
    G.append_sample!(writers.N, ts, cnt(N)); G.append_sample!(writers.E, ts, cnt(E)); G.append_sample!(writers.Z, ts, cnt(U))
end

# ---------------------------------------------------------------- replay
t_first = NaN; t_wall = NaN
nrows = 0; nsolved = 0; nerr = 0
sumsq = zeros(3); sumsats = 0
cum = zeros(3)
t_start = time()
open(capture) do f
    while !eof(f)
        tw = read(f, Float64); st = read(f, UInt8); n = read(f, UInt32); buf = read(f, n)
        isnan(t_first) && (global t_first = tw)
        global t_wall = tw
        tw - t_first > minutes * 60 && break
        for ev in G.feed_bytes!(decoder, buf; stream = st == 0 ? :obs : :eph)
            ev isa G.EvEpoch || continue
            ev.sys == primary && G._note_input_epoch!(session.stats, ev.epoch.sod)
            sod = try
                G.bridge_step!(session, decoder, ev.epoch; stale = false)
            catch err
                global nerr += 1
                nerr <= 3 && @warn "bridge step failed" err
                NaN
            end
            isnan(sod) && continue                       # no epoch group finished on this frame
            global nrows += 1
            state = session.bridge_state
            xs = state.last_xs
            dneu = (NaN, NaN, NaN)
            if length(xs) >= 3 && !any(isnan, xs[1:3]) && !all(isnan, state.rec_pos)
                A = G._ecef2neu_matrix(state.rec_pos)
                dneu = (A[1,1]*xs[1] + A[1,2]*xs[2] + A[1,3]*xs[3],
                        A[2,1]*xs[1] + A[2,2]*xs[2] + A[2,3]*xs[3],
                        A[3,1]*xs[1] + A[3,2]*xs[2] + A[3,3]*xs[3])
            end
            dh = session.stats.dop_history
            pdop = (!isempty(dh) && dh[end][1] == sod) ? dh[end][4] : NaN
            rh = session.stats.residual_history
            rms = (!isempty(rh) && rh[end][1] == sod) ? rh[end][3] : NaN
            ts = epoch_utc(tw, sod)
            solved = all(isfinite, dneu)
            if solved
                global nsolved += 1
                cum .+= dneu
                sumsq .+= dneu .^ 2
                global sumsats += state.last_sno
                isempty(mseed_dir) || mseed_push!(ts, dneu...)
            end
            @printf(io, "%s,%.1f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%.2f,%.4f\n",
                    Dates.format(ts, "yyyy-mm-ddTHH:MM:SS.s"), sod, dneu[1], dneu[2], dneu[3],
                    solved ? cum[1] : NaN, solved ? cum[2] : NaN, solved ? cum[3] : NaN,
                    state.last_sno, pdop, rms)
        end
    end
end
close(io)
if writers !== nothing
    G.close_writer!(writers.N); G.close_writer!(writers.E); G.close_writer!(writers.Z)
end
elapsed = time() - t_start

# ---------------------------------------------------------------- summary
info = session.bridge_state === nothing ? "engine not started" : session.bridge_state.engine_info
rmsmm(i) = nsolved > 0 ? 1000 * sqrt(sumsq[i] / nsolved) : NaN
@printf("capture   : %s  %.1f min of data, %s\n", basename(capture), (t_wall - t_first) / 60, info)
@printf("epochs    : %d solved by the bridge, %d with a displacement (%.1f %%), %d step errors\n",
        nrows, nsolved, 100 * nsolved / max(nrows, 1), nerr)
@printf("increments: RMS dN %.2f  dE %.2f  dU %.2f mm per epoch\n", rmsmm(1), rmsmm(2), rmsmm(3))
@printf("satellites: %.1f used on average\n", nsolved > 0 ? sumsats / nsolved : NaN)
@printf("output    : %s%s  (%.1f s of processing)\n", outpath, isempty(mseed_dir) ? "" : " and miniSEED in $mseed_dir", elapsed)
