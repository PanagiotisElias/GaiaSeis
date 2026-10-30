# Shared, mutable state types used across the stack.

"""
NTRIP connection profile. Persisted as a TOML table; the GUI is just a form
over these fields.
"""
Base.@kwdef mutable struct NtripProfile
    name::String              = "default"
    caster::String            = ""          # hostname (no scheme)
    # Free-text description of the physical/network link behind this profile
    # ("fibre, direct to receiver caster", "4G router via NOA VPN", "BKG relay,
    # TLS"). Recorded in the metrics CSV header, the Metrics window summary,
    # /metrics.json and the summary file, so link types can be compared.
    link_description::String  = ""
    port::Int                 = 2101
    mountpoint::String        = ""
    user::String              = ""
    password::String          = ""
    use_tls::Bool             = false
    # Optional GGA NMEA upload for VRS mounts (lat/lon/height_m, WGS84)
    send_gga::Bool            = false
    gga_lat_deg::Float64      = 0.0
    gga_lon_deg::Float64      = 0.0
    gga_height_m::Float64     = 0.0
    # GNSSes to keep when bridging to PPPHVA
    enable_gps::Bool          = true
    enable_glo::Bool          = true
    enable_gal::Bool          = true
    enable_bds::Bool          = true
    # When a constellation's frame is missing for an epoch (the caster
    # drops messages under load), the epoch is solved anyway as long as the
    # primary constellation (GPS when enabled) arrived. true = also solve
    # when the primary itself is missing, on whatever arrived (2-3× noisier,
    # shows as spikes); false = skip such epochs and let the next complete
    # one difference across the hole.
    solve_incomplete_epochs::Bool = false
    # Output
    log_dir::String           = "logs"
    output_filename::String   = ""          # auto if empty
    # ---------- miniSEED feed (CSV sink) ----------
    # Optional path; when non-empty the bridge appends one CSV line per
    # accepted epoch in the form:
    #   iso_utc,sod,N_m,E_m,U_m,sigma_m,nsats,hdop,vdop,N_cnt,E_cnt,U_cnt
    # The last three columns are 32-bit integer counts at the standard
    # GNSSgram scale factor (1e7 → 0.1 µm resolution) so the Python
    # `seedlink_integration.py` agent can pack STEIM2 records and serve
    # them on the SeedLink port without any conversion of its own.
    miniseed_csv_path::String = ""
    # ---------- miniSEED feed (direct .mseed sink) ----------
    # When non-empty the bridge writes valid miniSEED v2 records (encoding
    # 3 = INT32, big-endian, 512-byte records) directly to per-channel files
    # under this directory. Filenames follow the SDS convention:
    #   <NET>.<STA>.<LOC>.<CHA>.D.<YYYY>.<DOY>
    # so `ringserver`/`slarchive`/`obspy` can ingest them with no further
    # repacking. Three channels are written per accepted epoch (LNN/LNE/LNZ
    # by default — North/East/Up displacement in counts).
    miniseed_mseed_dir::String = ""
    miniseed_network::String  = "CL"
    miniseed_station::String  = ""           # falls back to mountpoint when empty
    miniseed_location::String = ""
    # Channel naming. SEED uses 3 chars: band/instrument/orientation.
    # Defaults match the GNSSgram convention (LN<E|N|Z> = long-period
    # displacement; switch to LX* if you want raw velocity instead).
    miniseed_channel_prefix::String = "LN"
    miniseed_sample_rate_hz::Float64 = 1.0
    # Max wall-clock seconds before a partial record is flushed (so a slow
    # stream doesn't sit in an empty file for the full ~2-minute fill time
    # of a 512-byte/INT32 record at 1 Hz). 10 s is a sane default for
    # real-time seedlink consumption; raise it to reduce file fragmentation.
    miniseed_flush_interval_sec::Float64 = 10.0
    # Counts scale (multiplied by metres before rounding to Int32).  1e7
    # → 0.1 µm resolution, which matches the CRL pipeline.
    miniseed_scale::Float64   = 1.0e7
    # ---------- SeedLink via ringserver (DataLink push) ----------
    # When `datalink_host` is non-empty every miniSEED record the direct
    # sink flushes is also sent to a ringserver over DataLink (src/datalink.jl);
    # ringserver then serves it to SeedLink clients and keeps a disk ring.
    # Requires `miniseed_mseed_dir` (the push hangs off the file writer).
    # Blank host = off. ringserver's DataLink port defaults to 16000.
    datalink_host::String     = ""
    datalink_port::Int        = 16000
    # ---------- Displacement engine ----------
    # An engine plug-in registered through GaiaSeisEngineAPI ("gaiavario" is
    # the default), loaded from the active environment or from `engine_path`;
    # "ppphva" = the historical in-bridge path, available only where the
    # PPPHVA package is installed beside GaiaSeis.
    engine::String            = "gaiavario"
    engine_mode::String       = "l1gf"      # plug-in observable (gaiavario: l1gf | single | dual | mean)
    engine_path::String       = ""          # directory of the plug-in package when it is not installed
    engine_options::String    = ""          # extra engine options "key=value,key=value"
    # PPPHVA bridge config (RMode is forced to "RTS" for live streams)
    process_mode::String      = "DFV"       # "DFV" or "SFV"
    elv_cutoff_deg::Float64   = 10.0
    # Optional ANTEX calibration file (`.atx`). When set, PPPHVA's `readatx`
    # is called to populate satellite + receiver phase-centre offsets. An
    # empty string falls back to a zero-PCO stub (the bridge synthesises one).
    antex_file::String        = ""
    # Bridge-side amplitude flag (FLAG ONLY since 2026-10-20): after the LSQ
    # produces dXYZ, the bridge compares it against a rolling median of the
    # previous solutions; a component more than `outlier_mad_threshold` x MAD
    # away is counted and reported as a Causes case, but the epoch is KEPT (a
    # genuine strong-motion pulse looks exactly like this). Set `=0` to disable
    # the flag. Defaults 8 x MAD over 200 epochs; profiles saved earlier keep
    # their stored values.
    outlier_mad_threshold::Float64 = 8.0
    outlier_window::Int       = 200
    # Quality gate: an epoch is blanked (NaN) only for one of these faults.
    # A value <= 0 disables the corresponding check.
    # SSR use (only when use_ssr): a satellite's orbit and clock corrections must
    # both be younger than `ssr_max_age_s`; otherwise (missing, incomplete, stale)
    # it falls back to its broadcast orbit and clock when `ssr_fallback` is true,
    # instead of being dropped from the solve (one missing SSR constellation emptied
    # the solution for 18 h on 2026-10-08). ssr_max_age_s <= 0 = no age check;
    # ssr_fallback = false is the old behaviour (drop).
    keep_session_logs::Int     = 20    # archived session logs kept per profile (0 = keep all)
    ssr_max_age_s::Float64     = 60.0
    ssr_fallback::Bool         = true
    max_velocity_mps::Float64  = 5.0   # step per epoch above this speed x epoch interval
    min_sats_used::Int         = 8     # satellites in the final fit
    min_constellations::Int    = 2     # constellations in the fit (capped at the number enabled)
    max_pdop::Float64          = 5.0   # PDOP of the visible satellites
    max_fit_rms_m::Float64     = 0.1   # weighted RMS of the post-fit residuals [m]
    # Longest hole in the input (in epochs of the stream's own interval)
    # across which the variometric difference is still taken. A longer hole
    # re-baselines instead: the epoch after it gets no solution (NaN) and the
    # next epoch differences against it. Any residual per-epoch bias and the
    # model error grow with the interval, so differencing across 1-3 s holes
    # (UPA10Z caster, 2026-09-09) produced one-sided spikes. 0 = never
    # re-baseline (old behaviour).
    max_gap_epochs::Int       = 5
    # ---------- Stream health ----------
    # Seconds a stream may go without delivering a single byte before the
    # reader declares it stalled, drops the socket and reconnects. A caster
    # (or any NAT/firewall between) can silently stop forwarding without
    # ever sending FIN, in which case the blocking read never returns and
    # `eof(sock)` never becomes true — the connection sits ESTABLISHED and
    # mute forever. 0 disables the watchdog.
    stall_timeout_sec::Float64 = 30.0
    # Reconnect backoff. A drop retries after `min`, doubling up to `max`;
    # any connection that actually delivered bytes resets it to `min`.
    reconnect_min_delay_sec::Float64 = 1.0
    reconnect_max_delay_sec::Float64 = 30.0
    # ---------- Optional SSR products caster ----------
    # When `use_ssr` is true and `ssr_caster` is non-empty, the session opens a
    # second NTRIP connection to the SSR products caster (e.g. products.igs-ip.net)
    # in parallel with the observation stream. The decoded 1057/1058/1063/1064/
    # 1240/1241 corrections populate `data.ssr` and the bridge sets `options.RTC = 1`.
    use_ssr::Bool             = false
    ssr_caster::String        = ""
    ssr_port::Int             = 2101
    ssr_mountpoint::String    = ""
    ssr_user::String          = ""
    ssr_password::String      = ""
    ssr_use_tls::Bool         = false
    # ---------- Optional broadcast-ephemeris caster ----------
    # Most SSR mounts on products.igs-ip.net DO NOT carry broadcast ephemeris.
    # Configure a separate ephemeris mount here (e.g. BCEP00BKG0) to populate
    # 1019 / 1020 / 1045 alongside the obs and SSR streams.
    use_eph::Bool             = false
    eph_caster::String        = ""
    eph_port::Int             = 2101
    eph_mountpoint::String    = ""
    eph_user::String          = ""
    eph_password::String      = ""
    eph_use_tls::Bool         = false
end

"""
Live counters / status reported back to the GUI while the session runs.
Updated atomically; GUI polls.
"""
# GPS − UTC offset. Obs epochs (MSM TOW / SOD) are GPS time; wall-clock
# latencies are computed against UTC, so subtract this. 18 s since
# 2017-01-01; bump if a leap second is ever announced again.
const GPS_UTC_LEAP_S = 18.0

Base.@kwdef mutable struct SessionStats
    # Guards the rolling histories below (displacement/residual/dop/
    # skyplot/input_gaps): the bridge appends on thread 1, the web-view
    # render worker snapshots them from another thread.
    lock::ReentrantLock    = ReentrantLock()
    connected::Bool        = false
    bytes_received::Int    = 0
    frames_total::Int      = 0
    frames_crc_failed::Int = 0
    epochs_skipped_backpressure::Int = 0
    # Catch-up on queue length: epochs of a late batch that were solved (not
    # skipped) because the backlog fitted the time budget, and the running
    # average of the per-epoch processing time that sets that budget [ms].
    epochs_caught_up::Int = 0
    solve_ms_ema::Float64 = NaN
    last_msg_type::Int     = 0
    msg_counts::Dict{Int,Int} = Dict{Int,Int}()
    msg_counts_by::Dict{Symbol,Dict{Int,Int}} = Dict{Symbol,Dict{Int,Int}}()   # per stream
    last_epoch_sod::Float64 = NaN
    last_epoch_nsat::Int    = 0
    last_residual_m::Float64 = NaN
    last_position_dxyz::NTuple{3,Float64} = (NaN, NaN, NaN)
    error_message::String   = ""
    # One line per stream drop: UTC time, stream, reason. Shown in the
    # diagnostic dump so a hole in the data can be attributed.
    drop_log::Vector{String} = String[]
    started_at::DateTime    = DateTime(0)
    # Wall-clock UTC of the most recent byte from each of the three NTRIP
    # connections. `DateTime(0)` means "no data yet". The GUI shows them
    # alongside the live status panel so the operator can tell at a glance
    # whether any stream has stalled.
    last_obs_byte_at::DateTime = DateTime(0)
    last_ssr_byte_at::DateTime = DateTime(0)
    last_eph_byte_at::DateTime = DateTime(0)
    # In-stream timestamps decoded from the RTCM payload itself (second-of-
    # day in each constellation's time scale). For the obs stream this is
    # the MSM7 epoch SOD (already mirrored in `last_epoch_sod` for the
    # legacy display line); kept here too for symmetry. NaN when no message
    # of that kind has been seen yet.
    last_obs_stream_sod::Float64 = NaN
    last_ssr_stream_sod::Float64 = NaN
    last_eph_stream_sod::Float64 = NaN
    # Absolute (un-wrapped) GPS week number from the latest 1019 message,
    # 0 = unknown. Combined with `last_obs_stream_tow` this gives the true
    # date of the captured data — independent of the receiver's wall clock,
    # so replays show the original-capture date rather than today.
    gps_week::Int                = 0
    # Full GPS time-of-week (seconds, 0..604800) from the latest MSM7 obs
    # frame. NaN when no GPS obs has arrived. Used together with `gps_week`
    # to fully time-tag the obs stream.
    last_obs_stream_tow::Float64 = NaN
    # Filter prerequisites (set by the bridge on every epoch so the GUI can
    # explain to the user why no displacement is being produced yet)
    # Input completeness (receiver/caster side). Counted on the primary
    # enabled constellation's MSM epochs BEFORE solving, from jumps in the
    # epoch SOD, so it measures what never arrived — independent of the
    # backpressure and outlier handling further down. `input_gaps` holds
    # (SOD of the first epoch after the hole, epochs missing), trimmed to the
    # display window so the plots can mark every hole.
    input_epochs::Int              = 0
    input_missing::Int             = 0
    input_interval_s::Float64      = NaN     # learned from the stream (min Δt)
    input_last_sod::Float64        = NaN
    input_prev_sod::Float64        = NaN     # the primary-system epoch before input_last_sod
    input_gaps::Vector{Tuple{Float64,Int}} = Tuple{Float64,Int}[]
    # Epochs after a hole longer than `max_gap_epochs` that were re-baselined
    # instead of differenced (logged NaN).
    epochs_rebaselined::Int        = 0
    # ---- Link / latency metrics (Metrics window, /metrics.json, CSV) ----
    # One tuple per solved primary-system epoch:
    #   (sod, wall_utc_sod, arrival_latency_s, solve_ms, mseed_latency_s,
    #    ssr_age_s, nsat)
    # arrival = wall UTC at frame receipt − epoch time (GPS→UTC applied);
    # mseed   = wall UTC when the record hit the disk − epoch time (NaN when
    #           nothing was flushed for this epoch); ssr_age = epoch − newest
    #           SSR clock/orbit epoch. Trimmed to the display window.
    metrics_history::Vector{NTuple{7,Float64}} = NTuple{7,Float64}[]
    metrics_csv::Union{IOStream,Nothing}      = nothing
    metrics_csv_path::String                   = ""
    bytes_obs::Int = 0
    bytes_ssr::Int = 0
    bytes_eph::Int = 0
    mseed_last_flush_sod::Float64 = NaN
    # (wall UTC sod, latency s): epoch time of the newest flushed record vs
    # the moment its bytes were written to a /mseed/live client — what a
    # puller experiences end to end. Kept under `lock`.
    mseed_delivery_history::Vector{NTuple{2,Float64}} = NTuple{2,Float64}[]
    # Stream outages as (wall_utc_sod_down, wall_utc_sod_up, kind) with
    # kind 1 = obs, 2 = ssr, 3 = eph; an outage still open has up = NaN.
    outages::Vector{NTuple{3,Float64}} = NTuple{3,Float64}[]
    have_rec_pos::Bool      = false
    have_ephemeris::Bool    = false
    have_ssr::Bool          = false
    n_eph::Int              = 0
    n_ssr_orb::Int          = 0
    n_ssr_clk::Int          = 0
    # Per-stream reconnect tallies + when the watchdog last fired, so a
    # flapping caster is visible in the status panel and the debug dump
    # instead of only showing up as a silent gap in the data.
    reconnects_obs::Int     = 0
    reconnects_ssr::Int     = 0
    reconnects_eph::Int     = 0
    last_stall_at::DateTime = DateTime(0)
    # Skyplot trails: (system, PRN) -> rolling [(az_deg, elv_deg)] sampled
    # once per accepted epoch, so the skyplot can draw where each satellite
    # came from rather than only where it is now.
    skyplot_tracks::Dict{Tuple{Symbol,Int},Vector{NTuple{2,Float64}}} =
        Dict{Tuple{Symbol,Int},Vector{NTuple{2,Float64}}}()
    # Rolling history of accepted displacements in the local NEU frame,
    # used by the GUI's live time-series plot.  Each entry is
    # `(sod_sec, N_m, E_m, U_m)`; oldest at the front. Capped at
    # `DISPLACEMENT_HISTORY_MAX` entries — sized so the Plot window's
    # longest Span option (= 30 min) has data at typical high-rate
    # streams (≤ 20 Hz).
    displacement_history::Vector{NTuple{4,Float64}} = NTuple{4,Float64}[]
    # Rolling history of the post-fit residual σ̂ (metres) — one entry per
    # accepted epoch: `(sod_sec, sigma_m)`. Same cap as displacement_history.
    # Since 2026-10-30 five columns: `(sod_sec, engine_sigma_m, rms_w_m, rms_u_m, sigma_va_m)`:
    # the engine's own figure, the weighted and unweighted post-fit RMS of the
    # satellites kept, and a smoothed sigma (300/30-epoch window) (see _sigma_va_update!).
    residual_history::Vector{NTuple{5,Float64}}    = NTuple{5,Float64}[]
    resid_sigma_va::Float64 = NaN      # running smoothed sigma of the weighted RMS
    resid_sigma_n::Int = 0             # epochs that entered it
    # Rolling history of geometry metrics per accepted epoch:
    # `(sod_sec, nsats, GDOP, PDOP, HDOP, VDOP)`. DOPs are NaN if fewer than
    # 4 satellites are visible (the geometry matrix is rank-deficient).
    dop_history::Vector{NTuple{6,Float64}}         = NTuple{6,Float64}[]
end

# Rolling-history cap. Sized for the Plot window's longest Span option
# (= 30 min) at typical seismogeodesy stream rates:
#   1 Hz → 1800 samples, 10 Hz → 18 000, 20 Hz → 36 000.
# Three tuples of ≤ 6 Float64 each, so ~150 entries/KB → ~36 000 entries
# = ~250 KB per session: negligible. Before this was 600, which capped
# every Span longer than 1 min at 10 Hz to the same (1-minute) window —
# that's the bug the Plot-window Span dropdown was hitting.
# Display history is bounded to a 20-minute window (below), trimmed by the
# SOD timestamp stored with each sample so it is correct at any rate. This
# hard sample cap is only a backstop against a SOD day-rollover confusing the
# time trim (20 min at 20 Hz = 24000).
const DISPLACEMENT_HISTORY_MAX = 36_000
# Wall-clock span of the plot / display buffers, in seconds. Keep 20 minutes.
const DISPLAY_WINDOW_SEC = 1800.0

"""
A running NTRIP session. Hold one per profile you want streaming.
"""
mutable struct NtripSession
    profile::NtripProfile
    stats::SessionStats
    stop_requested::Threads.Atomic{Bool}
    reader_task::Union{Task,Nothing}        # observation stream
    ssr_reader_task::Union{Task,Nothing}    # SSR products stream (nothing if disabled)
    eph_reader_task::Union{Task,Nothing}    # broadcast-ephemeris stream (nothing if disabled)
    decoder::Any                            # shared RtcmDecoder (set by start!)
    bridge_state::Any                       # filled by bridge.jl when first epoch arrives
    log_file::Union{IOStream,Nothing}
    # Direct miniSEED writers (one per channel: N, E, Z). Created lazily by
    # the bridge the first time `miniseed_mseed_dir` is set and a sample is
    # ready to write; `nothing` while inactive.
    mseed_writers::Any
    # DataLink client pushing the same records to a ringserver (SeedLink
    # service); created with the writers when `datalink_host` is set.
    datalink::Any
    function NtripSession(profile::NtripProfile)
        new(profile, SessionStats(), Threads.Atomic{Bool}(false),
            nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing)
    end
end

function isrunning(s::NtripSession)
    for t in (s.reader_task, s.ssr_reader_task, s.eph_reader_task)
        t === nothing && continue
        istaskdone(t) || return true
    end
    return false
end
