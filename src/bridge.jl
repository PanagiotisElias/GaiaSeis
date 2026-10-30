# Bridge from decoded RTCM events to PPPHVA's per-epoch pipeline.
#
# PPPHVA was written for a RINEX file: it builds a `data` PStruct, opens the
# obs file, then for each epoch calls vds_preproces → vds_model → vds_filter.
# We mimic that here without ever touching disk:
#
#   1. On first MSM7 epoch arrival, synthesize a `data.inf` PStruct that
#      looks enough like rnxhead's output to satisfy the downstream code:
#         - inf.time.first  : reference epoch from the GNSS time of week
#         - inf.time.int    : derived from epoch-to-epoch spacing (1, 5, 30 s)
#         - inf.time.system : "GPS"
#         - inf.time.doy    : day-of-year of inf.time.first
#         - inf.time.leap   : current leap-second offset
#         - inf.rec.pos     : ECEF from the 1005/1006 station message
#         - inf.ant.type    : best-effort; if unknown, "GENERIC"
#         - inf.ant.hen     : [0,0,0]
#         - inf.seq.gps / .glo / .gal / .bds : signal code list derived from MSM
#         - inf.nob.*       : count of obs codes per system
#   2. On every subsequent MSM7 "last message of epoch" event, pack the
#      observations into data.obs.gps[code_idx, prn] etc., and call
#      vds_preproces → vds_model → vds_filter just like vds_process does.
#
# We rely on broadcast ephemeris being decoded from the same stream (msgs
# 1019/1020/1045). The bridge runs in `RMode="RTS"`, with `options.RTC`
# flipped to 1 the first time an SSR orbit *and* clock correction arrives —
# at that point `data.ssr.orb.*` / `data.ssr.clk.*` are populated in the
# same column layout `PPPHVA.readssra` returns, and `calcsatnav` automatically
# picks the SSR-corrected branch.


# Small inline median — keeps Statistics out of GaiaSeis's deps.
function _median(v::AbstractVector)
    n = length(v)
    n == 0 && return NaN
    s = sort(v)
    isodd(n) ? s[(n+1)>>1] : 0.5*(s[n>>1] + s[(n>>1)+1])
end

# PPPHVA holds the GPT3 grid path in a `Ref{String}` whose value is reset by
# Julia's precompile cache, so we have to (re)apply it every time PPPHVA is
# loaded — see `_init_ppphva!` in pstruct.jl (no-op without PPPHVA).
function _autodetect_gpt3_grid!()
    _phva_loaded() || return ""
    candidates = String[
        # sibling PPPH_VA repo layout (typical install)
        joinpath(app_root(), "..", "PPPH_VA", "PPPH_VA_final", "3.Modelling", "GMF", "gpt3_5.grd"),
        # staged beside the program (bundle / compiled-app layout)
        joinpath(app_root(), "data", "gpt3_5.grd"),
        # next to the PPPHVA package itself
        joinpath(dirname(pathof(_phva())), "..", "data", "gpt3_5.grd"),
        joinpath(dirname(pathof(_phva())), "Modelling", "GMF", "gpt3_5.grd"),
        # env-var override
        get(ENV, "PPPHVA_GPT3_GRID", ""),
    ]
    for p in candidates
        isempty(p) && continue
        ap = abspath(p)
        if isfile(ap)
            _phva()._set_gpt3_5_grid_path!(ap)
            @info "PPPHVA: gpt3_5.grd located" path=ap
            return ap
        end
    end
    @warn "PPPHVA: gpt3_5.grd not found — set PPPHVA_GPT3_GRID env var or call PPPHVA._set_gpt3_5_grid_path!(...) manually before starting a session"
    return ""
end

# WGS-84 geodetic (lat°, lon°, h_m) → ECEF (X, Y, Z) in metres. Used as a
# fallback receiver position when the observation mount doesn't broadcast a
# 1005/1006 station record.
function _plh_to_ecef(lat_deg::Float64, lon_deg::Float64, h_m::Float64)
    a  = 6378137.0
    f  = 1 / 298.257223563
    e2 = 2f - f^2
    φ  = deg2rad(lat_deg)
    λ  = deg2rad(lon_deg)
    N  = a / sqrt(1 - e2*sin(φ)^2)
    x  = (N + h_m) * cos(φ) * cos(λ)
    y  = (N + h_m) * cos(φ) * sin(λ)
    z  = (N * (1 - e2) + h_m) * sin(φ)
    return x, y, z
end

"""
Holds the synthesized PPPHVA `data` PStruct, the options, and the rolling state
needed to feed the variometric filter epoch after epoch.
"""
# One receiver epoch being assembled from per-constellation MSM frames.
# `stage` holds the packed obs matrix of each enabled system that has
# reported for this timestamp; the PPPHVA `data.obs` is only built from it
# when the group is finished (see _assemble_obs!).
mutable struct EpochGroup
    sod::Float64                          # GPS-scale second-of-day
    sys::Set{Char}                        # systems staged so far
    stage::Dict{Char,Matrix{Float64}}
    frames::Vector{MsmEpoch}              # the frames themselves (engine plug-ins read these)
    nobs::Int                             # (sat, signal) cells staged
    stale::Bool                           # backlog: assemble only, never solve
    done::Bool
end
EpochGroup(sod::Float64, stale::Bool) =
    EpochGroup(sod, Set{Char}(), Dict{Char,Matrix{Float64}}(), MsmEpoch[], 0, stale, false)

# ---- Satellite-level residual flagging (flag only; nothing is blanked) ----
# The engine's per-satellite post-fit residuals (PPPHVA `dg`, fifth value of
# vds_filter) are standardised by the satellite weight; a satellite is flagged
# when it sits more than SATFLAG_K robust sigmas from the epoch's median, with
# a floor on the scale so a quiet epoch does not flag noise. A real ground
# motion moves every satellite coherently and leaves the residuals small; a
# bad ephemeris or a cycle slip shows up on single satellites.
const SATFLAG_K        = 5.0       # robust-sigma multiple
const SATFLAG_FLOOR_M  = 0.005     # minimum scale [m]
const SATFLAG_MIN_SATS = 6         # fewer satellites: MAD is not meaningful

mutable struct SatFlagState
    prn::Vector{Int}               # flagged PRNs of the latest epoch
    z::Vector{Float64}             # their standardised residuals [m]
    nused::Int                     # satellites in the latest fit
    maxz::Float64                  # largest |z - median| of the latest epoch [m]
    epochs::Int                    # epochs evaluated
    epochs_flagged::Int            # epochs with at least one flagged satellite
    sat_flags::Int                 # satellite flags raised
    engine_removed::Int            # satellites the engine's own gate dropped
    by_sys::Dict{Char,Int}         # flags per constellation
end
SatFlagState() = SatFlagState(Int[], Float64[], 0, NaN, 0, 0, 0, 0,
                              Dict('G' => 0, 'R' => 0, 'E' => 0, 'C' => 0))

# PPPHVA satellite number -> constellation letter and in-constellation PRN.
@inline _prn_sys(prn::Integer) = prn < 33 ? 'G' : prn < 59 ? 'R' : prn < 95 ? 'E' : 'C'
@inline _prn_local(prn::Integer) = prn < 33 ? prn : prn < 59 ? prn - 32 : prn < 95 ? prn - 58 : prn - 94
_prn_label(prn::Integer) = @sprintf("%c%02d", _prn_sys(prn), _prn_local(prn))

# Pure evaluation: returns (flagged PRNs, their z, max |z - median|, nused).
function _satflag_eval(dg; k::Real = SATFLAG_K, floor_m::Real = SATFLAG_FLOOR_M,
                       min_sats::Integer = SATFLAG_MIN_SATS)
    n = length(dg.prn)
    n < min_sats && return (Int[], Float64[], NaN, n)
    z = dg.res .* sqrt.(max.(dg.w, 0.0))
    m = _median(z)
    s = max(_median(abs.(z .- m)) * 1.4826, floor_m)
    dev = abs.(z .- m)
    idx = findall(>(k * s), dev)
    return (dg.prn[idx], z[idx], maximum(dev), n)
end

# Record the latest epoch's result and the cumulative counters.
function _satflag_update!(sf::SatFlagState, dg)
    prn, z, maxz, n = _satflag_eval(dg)
    sf.prn = prn; sf.z = z; sf.maxz = maxz; sf.nused = n
    sf.engine_removed += length(dg.removed)
    n < SATFLAG_MIN_SATS && return sf
    sf.epochs += 1
    if !isempty(prn)
        sf.epochs_flagged += 1
        sf.sat_flags += length(prn)
        for p in prn
            sf.by_sys[_prn_sys(p)] += 1
        end
    end
    return sf
end

# "E14 +61mm, C07 -55mm" (at most four satellites, largest first).
function _satflag_note(sf::SatFlagState)
    o = sortperm(abs.(sf.z); rev = true)
    parts = [@sprintf("%s %+.0fmm", _prn_label(sf.prn[i]), 1000 * sf.z[i]) for i in first(o, 4)]
    length(o) > 4 && push!(parts, "+$(length(o) - 4) more")
    return join(parts, ", ")
end

# No evaluation this epoch (hole, warm-up, no fit): clear the latest result.
function _satflag_clear!(sf::SatFlagState)
    empty!(sf.prn); empty!(sf.z); sf.nused = 0; sf.maxz = NaN
    return sf
end

# Counters of the quality gate (see _quality_gate! below).
mutable struct QualGateState
    total::Int                     # epochs blanked by the gate
    by::Dict{Symbol,Int}           # per reason: :sats :consts :pdop :fit :step
    last::String                   # note of the latest blanking
end
QualGateState() = QualGateState(0, Dict(:sats => 0, :consts => 0, :pdop => 0, :fit => 0, :step => 0), "")

mutable struct BridgeState
    data::Any              # PPPHVA.PStruct
    options::Any
    fi::Int                # epoch counter (0 = uninitialized)
    rec_pos::NTuple{3,Float64}
    # Per-system → ordered list of RTCM codes ("1C", "2W", ...) → column index in data.obs.SYS
    code_index::Dict{Symbol, Dict{String,Int}}
    # NavAccumulator keyed by (sys, prn)
    nav_rows::Dict{Tuple{Char,Int},Vector{Float64}}
    last_epoch_sod::Float64
    # latest filter outputs
    last_xs::Vector{Float64}
    last_sno::Int
    last_res::Float64
    # Rolling history of dXYZ used by the outlier guard
    dxyz_history::Vector{NTuple{3,Float64}}
    # Number of consecutive epochs the guard has rejected. If this
    # grows past `outlier_window`, we assume the receiver actually
    # moved (or the buffer's MAD baseline is no longer representative)
    # and reset the rolling history so new samples are accepted.
    consec_outliers::Int
    # ---- Cumulative outlier statistics (read by the Plot window) ----
    # `outlier_total` counts every epoch the guard has rejected since the
    # last `flush_session_data!`. `outlier_dev_sq_sum` accumulates the
    # squared Euclidean magnitude (meters²) of each rejected epoch's
    # deviation from the rolling median, so the GUI can display
    #   σ_outliers = sqrt(outlier_dev_sq_sum / outlier_total)
    # in mm — a quick "how big are my outliers, on average?" indicator.
    outlier_total::Int
    outlier_dev_sq_sum::Float64
    # ---- Epoch grouping (multi-constellation) ----
    # Each constellation arrives in its own MSM frame. The variometric
    # filter must see every enabled system at the SAME timestamp in both
    # data.obs and data.pobs, so per-system frames are staged per group and
    # the solve runs once per timestamp. `cur` is the newest group; `held`
    # is the previous one when it is still missing a system: an incomplete
    # group waits one more epoch before it is finished with what it has
    # (a frame lost or delayed upstream must not derail the pairing).
    cur::Union{EpochGroup,Nothing}
    held::Union{EpochGroup,Nothing}
    seen_sys::Set{Char}       # enabled systems that have emitted at least once
    late_frames::Int          # frames older than both open groups (dropped)
    missing_streak::Dict{Char,Int}   # consecutive finished groups a seen system was absent from
    incomplete_groups::Int    # groups finished with a system missing
    # Filtered epochs still to withhold. The first difference after the
    # baseline pairs a model built while the satellite set was still
    # settling (a 20 m dXYZ on the first epoch of every session,
    # 2026-09-10), and the first after SSR corrections switch on differences
    # SSR-corrected against broadcast positions. Neither is a displacement.
    warmup::Int
    ssr_version_applied::Int  # decoder.ssr_version the current data.ssr was built from
    satflag::SatFlagState     # per-satellite residual flags (latest epoch + counters)
    qgate::QualGateState      # epochs blanked by the quality gate
    # Ephemeris consistency inside the variometric pair: signature (hash of the
    # record row) of each satellite's ephemeris as used by the previous epoch's
    # model, and counters of the changes seen / pmodel rebuilds done.
    nav_sig::Dict{Tuple{Char,Int},UInt}
    eph_changes::Int
    eph_rebuilds::Int
    # What the last solved epoch actually used (alarms and /status.json):
    # satellites in the final fit, the constellations among them ("GREC"
    # order), and per enabled constellation the number of consecutive solved
    # epochs it was absent from the fit.
    sats_used::Int
    cons_used::String
    cons_absent::Dict{Char,Int}
    # SSR validity (see _refresh_ssr!): satellites whose orbit AND clock
    # corrections are present and young enough, and per constellation
    # (valid, known) counts over the satellites with a broadcast ephemeris.
    ssr_valid::Set{Tuple{Char,Int}}
    ssr_cons::Dict{Char,Tuple{Int,Int}}
    ssr_max_age::Float64
    # ---- Engine plug-in (profile.engine != "ppphva"; see engine_api.jl) ----
    engine::Any                              # GaiaSeisEngineAPI.AbstractEngine or nothing
    engine_nav_sig::Dict{Tuple{Char,Int},UInt}   # hash of each record already fed to the engine
    engine_prev_t::Float64                   # GPS seconds of the last epoch handed to the engine (hole detection)
    engine_info::String
    last_dg::Any                             # per-satellite residuals of the last fit (prn, res, w, removed), either engine
end

# Which constellations the last fit used, and how long an enabled one has been
# missing from it (alarm "No Galileo in the solve for 14 s"). Epochs without a
# fit (empty `dg`) change nothing.
function _cons_update!(state::BridgeState, dg)
    isempty(dg.prn) && return
    present = Set(_prn_sys(p) for p in dg.prn)
    state.sats_used = length(dg.prn)
    state.cons_used = join(c for c in "GREC" if c in present)
    sysopt = state.options.system
    enabled = Dict('G' => sysopt.gps == 1, 'R' => sysopt.glo == 1, 'E' => sysopt.gal == 1, 'C' => sysopt.bds == 1)
    for c in "GREC"
        state.cons_absent[c] = (enabled[c] && !(c in present)) ? state.cons_absent[c] + 1 : 0
    end
    return
end

# Best-effort default before a 1005 arrives: zero-vector. The filter result is
# meaningless until coords are known, so the bridge gates filtering on this.
function _empty_bridge(profile::NtripProfile)
    # A profile that names the historical in-bridge engine needs the PPPHVA
    # package (not distributed with GaiaSeis): fail here, at session start,
    # with the install hint rather than at the first epoch.
    _engine_is_plugin(profile) || _phva()
    options = _phva_loaded() ? _phva().default_options_dfv() : _pstruct()
    options.ProcessMode = profile.process_mode
    options.RMode = "RTS"
    options.RTC = 0
    options.elvangle = profile.elv_cutoff_deg
    options.ssr_fallback = profile.ssr_fallback ? 1 : 0
    options.system.gps = profile.enable_gps ? 1 : 0
    options.system.glo = profile.enable_glo ? 1 : 0
    options.system.gal = profile.enable_gal ? 1 : 0
    options.system.bds = profile.enable_bds ? 1 : 0
    BridgeState(_pstruct(), options, 0,
                (NaN, NaN, NaN),
                Dict(:gps => Dict{String,Int}(), :glo => Dict{String,Int}(),
                     :gal => Dict{String,Int}(), :bds => Dict{String,Int}()),
                Dict{Tuple{Char,Int},Vector{Float64}}(),
                NaN, Float64[], 0, NaN,
                NTuple{3,Float64}[], 0,
                0, 0.0,   # outlier_total, outlier_dev_sq_sum
                nothing, nothing, Set{Char}(), 0, Dict{Char,Int}(), 0,   # epoch groups
                2, 0,   # warmup, ssr_version_applied
                SatFlagState(), QualGateState(),
                Dict{Tuple{Char,Int},UInt}(), 0, 0,
                0, "", Dict('G' => 0, 'R' => 0, 'E' => 0, 'C' => 0),
                Set{Tuple{Char,Int}}(), Dict{Char,Tuple{Int,Int}}(),
                profile.ssr_fallback ? profile.ssr_max_age_s : 0.0,
                nothing, Dict{Tuple{Char,Int},UInt}(), NaN, "", nothing)
end

# Bridge-side quality gate and amplitude flag (rewritten 2026-10-20; before
# that a rolling-MAD test blanked any epoch more than `outlier_mad_threshold`
# MAD from the median, which would have blanked genuine strong shaking: see
# docs/MANUAL.md section 5.7).
#
# 1. `_quality_gate!` BLANKS an epoch (dXYZ -> NaN, logged as NaN) only for a
#    fault: too few satellites or constellations in the fit, PDOP too high,
#    post-fit residual RMS too large, or a step no ground motion can make
#    (profile.max_velocity_mps x epoch interval). A threshold <= 0 disables
#    its check.
# 2. `_outlier_guard!` is the old MAD test, now FLAG ONLY: the epoch is kept,
#    counted (outlier_total) and reported as a Causes `:outlier` case. Every
#    kept epoch enters the rolling history, so the baseline follows a coherent
#    excursion instead of rejecting it for a window and resetting.
# Pure check: returns (reason, note); reason == :ok when the epoch passes.
function _qualgate_check(dg, cur, p::NtripProfile, dt::Real, n_enabled::Integer, pdop::Real)
    n = length(dg.prn)
    if p.min_sats_used > 0 && n < p.min_sats_used
        return (:sats, @sprintf("%d sats < %d", n, p.min_sats_used))
    end
    if p.min_constellations > 0
        need = min(p.min_constellations, n_enabled)
        ncon = length(unique(_prn_sys.(dg.prn)))
        ncon < need && return (:consts, @sprintf("%d constellations < %d", ncon, need))
    end
    if p.max_pdop > 0 && isfinite(pdop) && pdop > p.max_pdop
        return (:pdop, @sprintf("PDOP %.1f > %.1f", pdop, p.max_pdop))
    end
    if p.max_fit_rms_m > 0
        sw = sum(dg.w)
        rms = sw > 0 ? sqrt(sum(dg.w .* dg.res .^ 2) / sw) : NaN
        isfinite(rms) && rms > p.max_fit_rms_m &&
            return (:fit, @sprintf("fit RMS %.0f mm > %.0f mm", 1000rms, 1000p.max_fit_rms_m))
    end
    if p.max_velocity_mps > 0
        step = sqrt(cur[1]^2 + cur[2]^2 + cur[3]^2)
        lim = p.max_velocity_mps * dt
        step > lim && return (:step, @sprintf("step %.2f m > %.2f m", step, lim))
    end
    return (:ok, "")
end

# Blanks the epoch when the gate fails; returns true when it did.
function _quality_gate!(state::BridgeState, profile::NtripProfile, dg, dt::Real; pdop_hint::Real = NaN)
    length(state.last_xs) < 3 && return false
    cur = (state.last_xs[1], state.last_xs[2], state.last_xs[3])
    any(isnan, cur) && return false
    pdop = Float64(pdop_hint)
    if profile.max_pdop > 0 && !isfinite(pdop)
        try; pdop = _compute_dop(state; used = Set(dg.prn))[3]; catch; end
    end
    n_enabled = count((profile.enable_gps, profile.enable_glo, profile.enable_gal, profile.enable_bds))
    reason, note = _qualgate_check(dg, cur, profile, dt, n_enabled, pdop)
    reason === :ok && return false
    qg = state.qgate
    qg.total += 1; qg.by[reason] += 1; qg.last = note
    _cause_event!(:qualgate, 1, note)
    state.last_xs = fill(NaN, length(state.last_xs))
    return true
end

function _outlier_guard!(state::BridgeState, profile::NtripProfile)
    isempty(state.last_xs) && return
    thr = profile.outlier_mad_threshold
    win = profile.outlier_window
    thr <= 0 && return
    length(state.last_xs) < 3 && return
    cur = (state.last_xs[1], state.last_xs[2], state.last_xs[3])
    any(isnan, cur) && return
    flagged = false
    if length(state.dxyz_history) >= 4
        hx = [t[1] for t in state.dxyz_history]
        hy = [t[2] for t in state.dxyz_history]
        hz = [t[3] for t in state.dxyz_history]
        mx = _median(hx); my = _median(hy); mz = _median(hz)
        sx = max(_median(abs.(hx .- mx)) * 1.4826, 1e-4)
        sy = max(_median(abs.(hy .- my)) * 1.4826, 1e-4)
        sz = max(_median(abs.(hz .- mz)) * 1.4826, 1e-4)
        if abs(cur[1]-mx) > thr*sx || abs(cur[2]-my) > thr*sy || abs(cur[3]-mz) > thr*sz
            flagged = true
            # Cumulative bookkeeping for the Plot window's "Outliers: N (σ=X mm)"
            # indicator: Euclidean distance from the rolling median [m].
            dx = cur[1] - mx; dy = cur[2] - my; dz = cur[3] - mz
            state.outlier_total += 1
            state.outlier_dev_sq_sum += dx*dx + dy*dy + dz*dz
            _cause_event!(:outlier, 1, @sprintf("|dXYZ| %.0f mm from the median (flagged, kept)", 1000 * sqrt(dx*dx + dy*dy + dz*dz)))
        end
    end
    state.consec_outliers = flagged ? state.consec_outliers + 1 : 0
    push!(state.dxyz_history, cur)
    length(state.dxyz_history) > win && popfirst!(state.dxyz_history)
    return
end

# Trim a rolling history of `(sod, …)` tuples to the DISPLAY_WINDOW_SEC
# wall-clock window, using the SOD stored in each sample so the span is a real
# 20 minutes at any rate (10 Hz -> 12000, 1 Hz -> 1200 samples). A hard sample
# cap is the backstop if a SOD day-rollover makes the time delta unreliable.
@inline function _trim_history!(h::Vector)
    isempty(h) && return
    newest = h[end][1]
    @inbounds while length(h) > 1
        age = newest - h[1][1]
        age < 0 && (age += 86400.0)      # SOD wrapped past midnight
        age <= DISPLAY_WINDOW_SEC && break
        popfirst!(h)
    end
    while length(h) > DISPLACEMENT_HISTORY_MAX
        popfirst!(h)
    end
end

function _sys_field(sys::Char)
    sys == 'G' && return :gps
    sys == 'R' && return :glo
    sys == 'E' && return :gal
    sys == 'C' && return :bds
    return :gps
end
_sys_size(sys::Char) = sys == 'G' ? 32 : sys == 'R' ? 26 : sys == 'E' ? 36 : 61

"""
Synthesize the PPPHVA `inf` header on first usable epoch.
"""
function _init_inf!(state::BridgeState, decoder::RtcmDecoder, ep::MsmEpoch)
    data = state.data
    inf = _pstruct()
    # Derive a wall-clock 'first epoch' tuple from `now()` plus the epoch SOD.
    # We don't need real GPS-time alignment — the variometric filter cares
    # about epoch-to-epoch spacing, sun/moon for tides, and tropospheric MJD.
    now_utc = Dates.now(UTC)
    yr  = Dates.year(now_utc); mo = Dates.month(now_utc); dy = Dates.day(now_utc)
    sod = ep.sod
    hr = Int(div(sod, 3600)); mn = Int(div(mod(sod, 3600), 60)); sc = sod - hr*3600 - mn*60
    inf.time = _pstruct()
    inf.time.first  = [yr, mo, dy, hr, mn, sc]
    inf.time.system = "GPS"
    inf.time.int    = 1.0    # may be revised after second epoch arrives
    inf.time.last   = 86400
    if _phva_loaded()
        inf.time.doy  = _phva().clcdoy(yr, mo, dy)
        inf.time.leap = _phva().leapsec((_phva().cal2jul(yr, mo, dy, 0)[2]))
    else
        inf.time.doy  = Dates.dayofyear(Dates.Date(yr, mo, dy))
        inf.time.leap = Int(GPS_UTC_LEAP_S)
    end
    # Receiver / antenna (station ECEF from latest 1005/1006, otherwise zeros)
    if decoder.station !== nothing
        state.rec_pos = (decoder.station.x, decoder.station.y, decoder.station.z)
    end
    inf.rec = _pstruct()
    inf.rec.pos    = collect(state.rec_pos)
    inf.rec.type   = "NTRIP"
    inf.rec.number = ""
    inf.rec.version = ""
    inf.ant = _pstruct()
    inf.ant.type   = "GENERIC"
    inf.ant.number = ""
    inf.ant.hen    = [0.0, 0.0, 0.0]
    # Observation code lists are built incrementally — start empty
    inf.seq = _pstruct()
    inf.seq.gps = String[]; inf.seq.glo = String[]
    inf.seq.gal = String[]; inf.seq.bds = String[]
    inf.nob = _pstruct()
    inf.nob.gps = 0; inf.nob.glo = 0; inf.nob.gal = 0; inf.nob.bds = 0
    inf.sat = _pstruct(); inf.sat.system = "M"
    inf.rinex = _pstruct(); inf.rinex.type = "O"
    data.inf = inf
    # ATX is queried by sfvmodel/dfvmodel for satapc; default to a zero-PCO
    # stub. `_load_antex!` overwrites this with a real ATX parse if the
    # profile specifies one.
    atx = _pstruct()
    atx.sat = _pstruct()
    atx.sat.gps = zeros(32, 3, 2); atx.sat.glo = zeros(26, 3, 2)
    atx.sat.gal = zeros(36, 3, 5); atx.sat.bds = zeros(61, 3, 4)
    atx.rcv = _pstruct()
    atx.rcv.neu = zeros(1, 3, 8)
    atx.rcv.nad = Vector{Any}(nothing, 8); atx.rcv.adp = Vector{Any}(nothing, 8)
    atx.rcv.daz = zeros(4)
    data.atx = atx
end

# Push the RTCM 1033 receiver/antenna descriptor into `data.inf.ant.type`
# and `inf.rec.type` so PPPHVA's `readatx` can match the correct entries.
function _apply_descriptor!(state::BridgeState, decoder::RtcmDecoder)
    desc = decoder.descriptor
    desc === nothing && return
    isempty(desc.antenna_descriptor) || (state.data.inf.ant.type = desc.antenna_descriptor)
    isempty(desc.receiver_type)     || (state.data.inf.rec.type = desc.receiver_type)
    @info "RTCM 1033 descriptor applied" antenna=state.data.inf.ant.type receiver=state.data.inf.rec.type
end

# Replace the zero-PCO ATX stub with the real calibration parsed from the
# IGS-style `.atx` file pointed to by `profile.antex_file`. Idempotent;
# no-op if the path is empty or the file doesn't exist.
function _load_antex!(state::BridgeState, profile::NtripProfile)
    path = profile.antex_file
    isempty(path) && return
    if !isfile(path)
        @warn "ANTEX file not found — keeping zero-PCO stub" antex_file=path
        return
    end
    # Engine plug-ins receive the path in `Station.antex`; only the in-bridge
    # PPPHVA path parses it here.
    _phva_loaded() || return
    try
        atx = _phva().readatx(path, state.data.inf)
        state.data.atx = atx
        @info "ANTEX loaded" antex_file=path receiver_antenna=state.data.inf.ant.type
    catch err
        @warn "ANTEX parse failed — keeping zero-PCO stub" antex_file=path err
    end
end

# Make sure the seq.SYS list contains a column for `code` (e.g. "C1C", "L1C").
function _ensure_code_index!(state::BridgeState, sys::Char,
                              code::String, kind::Char)
    fld = _sys_field(sys)
    inf_seq = getproperty(state.data.inf.seq, fld)
    full = string(kind, code)   # "C1C", "L1C", etc.
    cmap = state.code_index[fld]
    if !haskey(cmap, full)
        push!(inf_seq, full)
        cmap[full] = length(inf_seq)
        setproperty!(state.data.inf.nob, fld, length(inf_seq))
    end
    return cmap[full]
end

# Register every observation code of an MSM epoch in inf.seq.<sys> /
# code_index so the matrix row layout is known (also done for systems the
# profile has not enabled, so the diagnostics show what the stream carries).
function _register_codes!(state::BridgeState, ep::MsmEpoch)
    for o in ep.obs
        isempty(o.rinex_code) && continue
        _ensure_code_index!(state, ep.sys, o.rinex_code, 'C')   # pseudorange
        _ensure_code_index!(state, ep.sys, o.rinex_code, 'L')   # carrier
    end
end

"""
Pack an aggregated MSM epoch of one system into PPPHVA's
`[code_row, prn]` matrix form (NaN where no observation).
"""
function _pack_matrix!(state::BridgeState, ep::MsmEpoch)
    sysc = ep.sys
    sysf = _sys_field(sysc)
    _register_codes!(state, ep)
    nrows = length(getproperty(state.data.inf.seq, sysf))
    ncols = _sys_size(sysc)
    mat = fill(NaN, nrows, ncols)
    for o in ep.obs
        isempty(o.rinex_code) && continue
        o.prn <= ncols || continue          # BDS C62/C63 exceed PPPHVA's 61 slots
        cidx_pr = state.code_index[sysf]["C" * o.rinex_code]
        cidx_ph = state.code_index[sysf]["L" * o.rinex_code]
        if !isnan(o.pseudorange_m); mat[cidx_pr, o.prn] = o.pseudorange_m; end
        if !isnan(o.carrier_m);     mat[cidx_ph, o.prn] = o.carrier_m;     end
    end
    return mat
end

# Defensive access pattern; PStruct.haskey returns false when unset.
hasfield_p_safe(p, k::Symbol) = _is_pstruct(p) && haskey(p, k)

"""
Merge accumulated EphemerisRecord entries into data.nav (a PStruct mirroring
readbrod's output).
"""
function _refresh_nav!(state::BridgeState, decoder::RtcmDecoder, current_sod::Float64)
    sig = Dict{Tuple{Char,Int},UInt}()
    nav = _pstruct()
    nav.gps = fill(NaN, 32, 39); nav.glo = fill(NaN, 26, 39)
    nav.gal = fill(NaN, 36, 39); nav.bds = fill(NaN, 61, 39)
    nav.ep = current_sod
    for ((sys, prn), rec) in decoder.eph
        sig[(sys, prn)] = hash(rec.row)
        if sys == 'G' && prn <= 32
            nav.gps[prn, :] .= rec.row
        elseif sys == 'R' && prn <= 26
            nav.glo[prn, :] .= rec.row
        elseif sys == 'E' && prn <= 36
            nav.gal[prn, :] .= rec.row
        elseif sys == 'C' && prn <= 61
            # BeiDou GEOs (C01-C05, C59-C63) need the GEO orbit rotation that
            # PPPHVA's _orb_cal does not apply (calcsatnav skips C01-C05 on
            # its own); leave them NaN so they are never used.
            (prn <= 5 || prn >= 59) && continue
            nav.bds[prn, :] .= rec.row
        end
    end
    nav.binf = _pstruct()
    state.data.nav = nav
    return sig
end

# Satellites whose ephemeris record differs from the one the previous epoch's
# model was built with ("G05", "E14", ...). A satellite that had no record
# before is not a change: it was not in the previous model either.
function _nav_changed(prev::Dict{Tuple{Char,Int},UInt}, now::Dict{Tuple{Char,Int},UInt})
    ch = String[]
    for (k, h) in now
        ph = get(prev, k, nothing)
        ph === nothing && continue
        ph != h && push!(ch, @sprintf("%c%02d", k[1], k[2]))
    end
    return sort!(ch)
end

"""
Snapshot the most recent SSR orbit/clock corrections from the decoder into a
`data.ssr` PStruct shaped exactly like `PPPHVA.readssra` produces:

```
ssr.orb.gps[prn, 1] = epoch_s
ssr.orb.gps[prn, 2] = iod_eph
ssr.orb.gps[prn, 3] = delta_radial   (m)
ssr.orb.gps[prn, 4] = delta_along    (m)
ssr.orb.gps[prn, 5] = delta_cross    (m)
ssr.orb.gps[prn, 6] = delta_radial_rate (m/s)
ssr.orb.gps[prn, 7] = delta_along_rate  (m/s)
ssr.orb.gps[prn, 8] = delta_cross_rate  (m/s)

ssr.clk.gps[prn, 1] = epoch_s
ssr.clk.gps[prn, 2] = iod_eph
ssr.clk.gps[prn, 3] = c0  (m)
ssr.clk.gps[prn, 4] = c1  (m/s)
ssr.clk.gps[prn, 5] = c2  (m/s²)
```

`ssr.iop = 1` once both orbit and clock data are present (the flag PPPHVA's
`vds_process` looks at when deciding whether the SSR table is usable).
"""
# SSR messages stamp their epoch as GPS/GST time-of-week seconds, while
# PPPHVA evaluates the corrections at `data.obs.ep`, a second-of-day, as
# `C0 + C1·(t − t0)` and `δO + δȮ·(t − t0)`. Left as-is the difference is
# ~345 000 s and the rate terms turn into tens of metres per satellite,
# re-jumping at every 5 s SSR update (the periodic single-satellite spikes
# of 2026-09-10). Express the SSR epoch in the same scale as `sod`,
# unwrapped across midnight.
function _ssr_epoch_sod(epoch_s::Float64, sod::Float64, sys::Char = 'G')
    # GLONASS SSR (1063/1064) stamps DF386: seconds of day in UTC(SU)+3h.
    sys == 'R' && (epoch_s = epoch_s - 3*3600.0 + GPS_UTC_LEAP_S)
    e = mod(epoch_s, 86400.0)
    e - sod >  43200.0 && (e -= 86400.0)
    e - sod < -43200.0 && (e += 86400.0)
    return e
end

function _refresh_ssr!(state::BridgeState, decoder::RtcmDecoder, sod::Float64)
    isempty(decoder.ssr_orb) && isempty(decoder.ssr_clk) && return false

    ssr = _pstruct()
    orb = _pstruct()
    clk = _pstruct()
    orb.gps = fill(NaN, 32, 8); orb.glo = fill(NaN, 26, 8)
    orb.gal = fill(NaN, 36, 8); orb.bds = fill(NaN, 61, 8)
    clk.gps = fill(NaN, 32, 5); clk.glo = fill(NaN, 26, 5)
    clk.gal = fill(NaN, 36, 5); clk.bds = fill(NaN, 61, 5)
    for ((sys, prn), c) in decoder.ssr_orb
        arr = sys == 'G' ? orb.gps : sys == 'R' ? orb.glo : sys == 'E' ? orb.gal : orb.bds
        max_prn = size(arr, 1)
        prn <= max_prn || continue
        arr[prn, 1] = _ssr_epoch_sod(c.epoch_s, sod, sys)
        arr[prn, 2] = c.iode
        arr[prn, 3] = c.delta_radial
        arr[prn, 4] = c.delta_along
        arr[prn, 5] = c.delta_cross
        arr[prn, 6] = c.delta_radial_rate
        arr[prn, 7] = c.delta_along_rate
        arr[prn, 8] = c.delta_cross_rate
    end
    for ((sys, prn), c) in decoder.ssr_clk
        arr = sys == 'G' ? clk.gps : sys == 'R' ? clk.glo : sys == 'E' ? clk.gal : clk.bds
        max_prn = size(arr, 1)
        prn <= max_prn || continue
        arr[prn, 1] = _ssr_epoch_sod(c.epoch_s, sod, sys)
        arr[prn, 2] = c.iod_ssr
        arr[prn, 3] = c.c0
        arr[prn, 4] = c.c1
        arr[prn, 5] = c.c2
    end
    # Per-satellite validity: both corrections present and, with an age limit,
    # younger than it. Unusable satellites get NaN rows, which calcsatnav turns
    # into a broadcast-only satellite (ssr_fallback) or drops (old behaviour).
    valid = Set{Tuple{Char,Int}}()
    for key in keys(decoder.ssr_orb)
        haskey(decoder.ssr_clk, key) || continue
        o = decoder.ssr_orb[key]; c = decoder.ssr_clk[key]
        ok = true
        if state.ssr_max_age > 0
            ok = abs(_sod_diff(sod, _ssr_epoch_sod(o.epoch_s, sod, key[1]))) <= state.ssr_max_age &&
                 abs(_sod_diff(sod, _ssr_epoch_sod(c.epoch_s, sod, key[1]))) <= state.ssr_max_age
        end
        ok && push!(valid, key)
    end
    for (src, arrs) in ((decoder.ssr_orb, orb), (decoder.ssr_clk, clk))
        for ((sys, prn), _) in src
            (sys, prn) in valid && continue
            arr = sys == 'G' ? arrs.gps : sys == 'R' ? arrs.glo : sys == 'E' ? arrs.gal : arrs.bds
            prn <= size(arr, 1) && (arr[prn, :] .= NaN)
        end
    end
    known = Dict('G' => 0, 'R' => 0, 'E' => 0, 'C' => 0); nvalid = copy(known)
    for (sys, prn) in keys(decoder.eph)
        haskey(known, sys) || continue
        known[sys] += 1
        (sys, prn) in valid && (nvalid[sys] += 1)
    end
    state.ssr_cons = Dict(c => (nvalid[c], known[c]) for c in "GREC")
    valid_changed = valid != state.ssr_valid
    state.ssr_valid = valid
    ssr.orb = orb
    ssr.clk = clk
    ssr.ion = _pstruct()
    ssr.iop = (!isempty(decoder.ssr_orb) && !isempty(decoder.ssr_clk)) ? 1 : 0
    state.data.ssr = ssr

    # Once both orbit and clock have arrived, switch the filter into SSR-corrected mode.
    if ssr.iop == 1 && state.options.RTC != 1
        state.options.RTC = 1
        state.warmup = max(state.warmup, 2)
        @info "SSR corrections active — switching PPPHVA to RTS+RTC mode" n_orb=length(decoder.ssr_orb) n_clk=length(decoder.ssr_clk)
    end
    return valid_changed
end

"""
    bridge_step!(session, decoder, epoch)

Called by the session loop on every fully-assembled MSM7 epoch event. Updates
the PPPHVA state, runs preproces/model/filter when enough data is present,
and writes a row to the log file.
"""

# True if `data.obs.<sysf>` is a non-empty matrix (at least one observation
# code registered as a row). PPPHVA's calcsatnav indexes obs as
# `view(arr, obsp_idx, :)` and crashes when arr has zero rows.
function _obs_has_rows(state::BridgeState, sysf::Symbol)
    hasfield_p_safe(state.data, :obs) || return false
    obs = state.data.obs
    hasfield_p_safe(obs, sysf) || return false
    arr = getproperty(obs, sysf)
    return size(arr, 1) > 0
end

# Decide if a constellation has the observation codes PPPHVA needs:
# - any mode → at least one C/L pair on the primary frequency.
# - DFV     → additionally a C/L pair on the secondary frequency.
# Mirrors dfvotype's per-system priority. Reads inf.seq.<sys> and checks for
# code prefixes ("C1", "L1", "C2", "L2", "C5", "L7", ...).
function _sys_eligible(state::BridgeState, sysf::Symbol, profile_enabled::Bool,
                       is_dfv::Bool)
    profile_enabled || return false
    seq = getproperty(state.data.inf.seq, sysf)
    isempty(seq) && return false
    f1, f2 = sysf === :gps ? ('1', '2') :
             sysf === :glo ? ('1', '2') :
             sysf === :gal ? ('1', '5') :
                              ('2', '6')
    has_pair(f::Char) = any(c -> startswith(c, "C" * f), seq) &&
                        any(c -> startswith(c, "L" * f), seq)
    has_pair(f1) || return false
    if is_dfv
        # Galileo and BeiDou allow E5b/B2b as a secondary-band fallback.
        f2_alt = sysf === :gal || sysf === :bds ? '7' : nothing
        return has_pair(f2) || (f2_alt !== nothing && has_pair(f2_alt))
    end
    return true
end

function bridge_step!(session::NtripSession, decoder::RtcmDecoder, ep::MsmEpoch;
                      stale::Bool = false)
    state = session.bridge_state
    if state === nothing
        state = _empty_bridge(session.profile)
        session.bridge_state = state
    end
    if !hasfield_p_safe(state.data, :inf)
        _init_inf!(state, decoder, ep)
        _apply_descriptor!(state, decoder)
        _load_antex!(state, session.profile)
    end
    # If a 1033 frame arrives later (after _init_inf!), update the antenna
    # type and re-parse the ANTEX file once so receiver PCO matches the
    # actual hardware.
    if decoder.descriptor !== nothing &&
       !isempty(decoder.descriptor.antenna_descriptor) &&
       state.data.inf.ant.type != decoder.descriptor.antenna_descriptor
        _apply_descriptor!(state, decoder)
        _load_antex!(state, session.profile)
    end
    # Update receiver position if a station message has arrived since,
    # or seed it from the profile's GGA lat/lon/height when the mount doesn't
    # send 1005/1006 (common for non-VRS station mounts).
    if decoder.station !== nothing
        state.rec_pos = (decoder.station.x, decoder.station.y, decoder.station.z)
        state.data.inf.rec.pos = collect(state.rec_pos)
    elseif all(isnan, state.rec_pos) && (session.profile.gga_lat_deg != 0 ||
                                          session.profile.gga_lon_deg != 0 ||
                                          session.profile.gga_height_m != 0)
        x, y, z = _plh_to_ecef(session.profile.gga_lat_deg,
                                session.profile.gga_lon_deg,
                                session.profile.gga_height_m)
        state.rec_pos = (x, y, z)
        state.data.inf.rec.pos = [x, y, z]
        @info "bridge: seeded receiver ECEF from profile GGA fields" lat=session.profile.gga_lat_deg lon=session.profile.gga_lon_deg h=session.profile.gga_height_m xyz=(x,y,z)
    end
    # ---- Per-system frame ingest ------------------------------------------
    # Every constellation arrives in its own MSM frame. The variometric
    # filter differences data.obs against data.pobs, so BOTH must hold every
    # enabled system at a single timestamp. Solving on each frame with the
    # other systems carried forward gave one system a zero time-difference
    # and the other a full-interval one (a ±12 m dXYZ flipping sign every
    # epoch with GPS+Galileo, 2026-09-10). Frames are therefore staged per
    # epoch group and the solve runs once per timestamp, in timestamp order.
    if !_epoch_enabled(session.profile, ep.sys)
        _register_codes!(state, ep)      # keep inf.seq.<sys> current for the diagnostics
        state.last_epoch_sod = ep.sod
        return NaN
    end
    push!(state.seen_sys, ep.sys)
    state.last_epoch_sod = ep.sod

    solved_sod = NaN
    S = _sod_gps(ep.sys, ep.sod)
    tol = _group_tolerance(session)
    same(g) = g !== nothing && abs(_sod_wrap(S - g.sod)) <= tol
    if same(state.held)
        # The late frame the hold was waiting for.
        g = state.held
        _stage!(g, state, ep)
        if _group_complete(state, g, session.profile)
            state.held = nothing
            solved_sod = _finish_group!(session, decoder, state, g)
        end
    elseif same(state.cur)
        _stage!(state.cur, state, ep)
        solved_sod = _maybe_finish_cur!(session, decoder, state)
    elseif state.cur === nothing || _sod_wrap(S - state.cur.sod) > tol
        # Newer timestamp. A held group has had its extra epoch: finish it
        # with what arrived (missing systems blank). The current group, if
        # still open, becomes the held one.
        if state.held !== nothing
            _finish_group!(session, decoder, state, state.held)
            state.held = nothing
        end
        state.held = (state.cur !== nothing && !state.cur.done) ? state.cur : nothing
        state.cur = EpochGroup(S, stale)
        _stage!(state.cur, state, ep)
        solved_sod = _maybe_finish_cur!(session, decoder, state)
    else
        # Older than both open groups: too late to pair with anything.
        state.late_frames += 1
    end
    return solved_sod
end

function _stage!(g::EpochGroup, state::BridgeState, ep::MsmEpoch)
    g.stage[ep.sys] = _pack_matrix!(state, ep)
    push!(g.frames, ep)
    push!(g.sys, ep.sys)
    g.nobs += length(ep.obs)
end

# Finish the current group when every enabled system that has ever reported
# is in. The very first group (fi == 0) is never finished here: seen_sys
# cannot yet know which systems the stream carries, so it waits until a
# newer timestamp pushes it out. An older held group is finished first so
# solves stay in timestamp order.
function _maybe_finish_cur!(session::NtripSession, decoder::RtcmDecoder, state::BridgeState)
    g = state.cur
    (state.fi > 0 && !g.done && _group_complete(state, g, session.profile)) || return NaN
    if state.held !== nothing
        _finish_group!(session, decoder, state, state.held)
        state.held = nothing
    end
    return _finish_group!(session, decoder, state, g)
end

# Assemble the group into data.obs and, unless it is backlog, run the solve.
# Returns the solved GPS-scale SOD, or NaN.
function _finish_group!(session::NtripSession, decoder::RtcmDecoder, state::BridgeState, g::EpochGroup)
    g.done && return NaN
    g.done = true
    # A system that stops reporting (receiver dropped it, or the mount no
    # longer carries it) must not keep every later group waiting for the
    # hold: after three finished groups without it, stop expecting it. It
    # is re-added by its next frame (bridge_step! pushes into seen_sys).
    complete = true
    for c in collect(state.seen_sys)
        _epoch_enabled(session.profile, c) || continue
        if c in g.sys
            state.missing_streak[c] = 0
        else
            complete = false
            n = get(state.missing_streak, c, 0) + 1
            state.missing_streak[c] = n
            n >= 3 && delete!(state.seen_sys, c)
        end
    end
    # An incomplete group (one constellation's frame never arrived — the
    # mount-B caster drops whole messages under load, BeiDou first) is still
    # solved when the primary constellation (GPS when enabled) is present:
    # losing BeiDou for an epoch leaves 25 of 32 satellites and costs
    # nothing visible. It is skipped when the primary itself is missing —
    # a solve on the remaining minor constellation was 2-3× noisier and
    # showed as spikes, and the blanked system also costs the next epoch
    # its differences. data.obs then keeps the last complete epoch so the
    # next group differences over two intervals with every satellite.
    # Profile option `solve_incomplete_epochs` forces the solve even then.
    if !complete
        state.incomplete_groups += 1
        primary_present = _primary_sys(session.profile) in g.sys
        (primary_present || session.profile.solve_incomplete_epochs) || return NaN
        _cause_event!(:partial, 1, "missing " * join(sort([string(c) for c in state.seen_sys if !(c in g.sys)]), ","))
    end
    _assemble_obs!(state, g, session.profile)
    if g.stale
        session.stats.epochs_skipped_backpressure += 1
        _cause_event!(:skips, 1, @sprintf("epoch %.1f dropped by catch-up", g.sod))
        return NaN
    end
    _solve_group!(session, decoder, state, g.sod, g.nobs; group = g)
    return g.sod
end

# Build PPPHVA's data.obs from a group's staged matrices. The previous
# data.obs becomes data.pobs (the filter differences against it). Enabled
# systems that have reported before but are missing from this group get an
# all-NaN matrix so nothing stale leaks into the difference; systems the
# profile has not enabled keep a 0-row placeholder. `obs.ep` is the group's
# own GPS-scale time — PPPHVA takes the receive time for satellite positions
# from it (calcsatnav: trc = data.obs.ep).
function _assemble_obs!(state::BridgeState, g::EpochGroup, profile::NtripProfile)
    if state.fi > 0 && hasfield_p_safe(state.data, :obs)
        state.data.pobs = state.data.obs
    end
    obs = _pstruct()
    for c in ('G', 'R', 'E', 'C')
        sysf  = _sys_field(c)
        nrows = length(getproperty(state.data.inf.seq, sysf))
        ncols = _sys_size(c)
        if _epoch_enabled(profile, c) && c in state.seen_sys
            m = get(g.stage, c, nothing)
            if m === nothing
                m = fill(NaN, nrows, ncols)
            elseif size(m, 1) < nrows        # a code was registered after staging
                m = vcat(m, fill(NaN, nrows - size(m, 1), ncols))
            end
            setproperty!(obs, sysf, m)
        else
            setproperty!(obs, sysf, fill(NaN, 0, ncols))
        end
    end
    obs.ep = g.sod
    state.data.obs = obs
    _harmonise_pobs!(state)
end

# Decoder SOD of `sys` expressed in the GPS time scale so frames of different
# constellations can be matched to one epoch. Galileo (GST) is aligned with
# GPST; GLONASS SOD is UTC (the decoder already removed the +3 h); BeiDou's
# BDT trails GPST by 14 s.
function _sod_gps(sys::Char, sod::Float64)
    sys == 'R' && return mod(sod + GPS_UTC_LEAP_S, 86400.0)
    sys == 'C' && return mod(sod + 14.0, 86400.0)
    return sod
end
_sod_wrap(d::Float64) = d > 43200 ? d - 86400.0 : d <= -43200 ? d + 86400.0 : d

# Half the learned epoch interval (50 ms before it is known): two frames
# closer than this belong to the same epoch.
function _group_tolerance(session::NtripSession)
    iv = session.stats.input_interval_s
    return (isnan(iv) || iv <= 0) ? 0.05 : 0.5 * iv
end

# Every enabled system that has ever emitted is present in the group.
function _group_complete(state::BridgeState, g::EpochGroup, profile::NtripProfile)
    for c in state.seen_sys
        _epoch_enabled(profile, c) || continue
        c in g.sys || return false
    end
    return true
end

# Harmonise pobs shape with the freshly packed obs. PPPHVA's dfvcs/sfvcs
# subtract `obs.<sys>[r, PRN] - pobs.<sys>[r, PRN]` for every satellite
# flagged in obs.st, but pobs.<sys> still reflects the *previous* epoch.
# If a system gained rows this epoch (first arrival of its data, or a new
# observation code was registered), pobs.<sys> would still be the 0-row
# placeholder and the indexed lookup explodes with a BoundsError. Filling
# the missing slots with NaN makes dfvcs see `NaN - NaN`, which
# short-circuits any cycle-slip flag.
function _harmonise_pobs!(state::BridgeState)
    if hasfield_p_safe(state.data, :pobs)
        pobs = state.data.pobs
        for sysf in (:gps, :glo, :gal, :bds)
            hasfield_p_safe(state.data.obs, sysf) || continue
            ofield = getproperty(state.data.obs, sysf)
            if hasfield_p_safe(pobs, sysf)
                pfield = getproperty(pobs, sysf)
                size(pfield) == size(ofield) && continue
            end
            setproperty!(pobs, sysf, fill(NaN, size(ofield, 1), size(ofield, 2)))
        end
        # Carry forward scalar/auxiliary fields so dfvsats has something to
        # iterate (st gets recomputed every preproces, but a non-existent
        # field would still error during the access path).
        if !hasfield_p_safe(pobs, :ep)
            pobs.ep = state.data.obs.ep
        end
    end
end

# Run the heavy refreshes + the variometric pipeline for one completed epoch
# group. `sod` is the group's GPS-scale second-of-day. Everything that used
# to run per MSM frame (nav/SSR refresh, eligibility, filter, stats, log and
# miniSEED sinks) lives here so it happens exactly once per epoch.
function _solve_group!(session::NtripSession, decoder::RtcmDecoder, state::BridgeState,
                       sod::Float64, nobs::Int; group::Union{EpochGroup,Nothing} = nothing)
    nav_sig = _refresh_nav!(state, decoder, sod)
    nav_changed = _nav_changed(state.nav_sig, nav_sig)
    ssr_valid_changed = _refresh_ssr!(state, decoder, sod)
    ssr_changed = decoder.ssr_version != state.ssr_version_applied || ssr_valid_changed
    state.ssr_version_applied = decoder.ssr_version

    # Re-derive `options.system.*` each epoch from
    #     profile-enabled  AND  required obs codes registered
    # so PPPHVA never tries to process a constellation with empty inf.seq.<sys>
    # or, in DFV mode, with only a single frequency observed.
    p = session.profile
    is_dfv = p.process_mode == "DFV"
    state.options.system.gps = (_sys_eligible(state, :gps, p.enable_gps, is_dfv) &&
                                 _obs_has_rows(state, :gps)) ? 1 : 0
    state.options.system.glo = (_sys_eligible(state, :glo, p.enable_glo, is_dfv) &&
                                 _obs_has_rows(state, :glo)) ? 1 : 0
    state.options.system.gal = (_sys_eligible(state, :gal, p.enable_gal, is_dfv) &&
                                 _obs_has_rows(state, :gal)) ? 1 : 0
    state.options.system.bds = (_sys_eligible(state, :bds, p.enable_bds, is_dfv) &&
                                 _obs_has_rows(state, :bds)) ? 1 : 0

    # Surface the prerequisites in stats so the GUI can show what's missing.
    have_pos    = !all(isnan, state.rec_pos)
    have_eph    = !isempty(decoder.eph)
    have_ssr    = state.options.RTC == 1
    session.stats.last_epoch_sod = sod
    session.stats.last_epoch_nsat = nobs
    session.stats.have_rec_pos    = have_pos
    session.stats.have_ephemeris  = have_eph
    session.stats.have_ssr        = have_ssr
    session.stats.n_eph           = length(decoder.eph)
    session.stats.n_ssr_orb       = length(decoder.ssr_orb)
    session.stats.n_ssr_clk       = length(decoder.ssr_clk)

    # We need (a) a station ECEF, (b) at least one ephemeris before filtering.
    if !have_pos || !have_eph
        return
    end

    # Replicate vds_process's two-stage handling (fi=0 sets baseline; fi≥1 filters)
    options = state.options
    try
        if _engine_is_plugin(session.profile) && group !== nothing
            _plugin_solve!(session, decoder, state, group, sod, nav_sig)
            state.nav_sig = nav_sig
            state.fi += 1
        elseif state.fi == 0
            state.data, options = _phva().vds_preproces(state.data, options, 0)
            model, state.data = _phva().vds_model(state.data, options, 0)
            state.data.model = model
            state.nav_sig = nav_sig
            state.data.psV = NaN
            state.fi = 1
        else
            # data.pobs and data.obs were set by _assemble_obs!.
            # The variometric difference model(t) − pmodel(t−1) must use ONE
            # SSR realisation on both sides. When a new SSR orbit/clock set
            # arrived since the previous epoch, pmodel was built with the old
            # one and the difference would carry the correction jump (5-mm
            # vertical excursions every 5 s, 2026-09-10). Rebuild pmodel from
            # pobs with the new corrections first. Wind-up continuity is kept
            # by calling vds_model with fi = 1 (fi = 0 would reset it).
            #
            # The same holds for the broadcast ephemeris: when a satellite's
            # record changed between the two epochs (GPS/BeiDou on the hour,
            # Galileo every 10 minutes, ...) the two models would use different
            # orbits and the orbit step shows up as a displacement. pmodel is
            # rebuilt with the current records so BOTH epochs use the same one;
            # no satellite is lost (plan item 1, 2026-10-20).
            if !isempty(nav_changed)
                state.eph_changes += length(nav_changed)
                _cause_event!(:ephswitch, 1, first(join(nav_changed, " "), 60))
            end
            if ((ssr_changed && state.options.RTC == 1) || !isempty(nav_changed)) &&
               hasfield_p_safe(state.data, :pobs) && hasfield_p_safe(state.data, :model)
                !isempty(nav_changed) && (state.eph_rebuilds += 1)
                try
                    saved_obs = state.data.obs
                    state.data.obs = state.data.pobs
                    d2, o2 = _phva().vds_preproces(state.data, options, 0)
                    pm, d2 = _phva().vds_model(d2, o2, 1)
                    state.data = d2
                    state.data.obs = saved_obs
                    state.data.model = pm
                catch err
                    @debug "pmodel rebuild after SSR update failed" err
                end
            end
            state.data, options = _phva().vds_preproces(state.data, options, state.fi)
            state.data.pmodel = state.data.model
            model, state.data = _phva().vds_model(state.data, options, state.fi)
            state.data.model = model
            state.nav_sig = nav_sig
            # Hole too long to difference across? (interval learned from the
            # stream; see NtripProfile.max_gap_epochs). The model above is
            # still computed so the NEXT epoch differences against this one.
            # The reference is the previous epoch of the PRIMARY system
            # (stats.input_prev_sod, set by _note_input_epoch! just before
            # this call) — NOT state.last_epoch_sod, which is updated by
            # every constellation's MSM frame: BeiDou epochs carry BDT
            # (14 s behind GPS) and would make every GPS epoch look like a
            # 14-s hole (that bug blanked 97 % of a session on 2026-09-10).
            prev_sod = session.stats.input_prev_sod
            gap_s = sod - prev_sod
            gap_s < -43200 && (gap_s += 86400.0)
            iv = session.stats.input_interval_s
            mg = session.profile.max_gap_epochs
            if mg > 0 && !isnan(prev_sod) && !isnan(iv) && iv > 0 && gap_s > (mg + 0.5) * iv
                state.last_xs = fill(NaN, max(length(state.last_xs), 3))
                _satflag_clear!(state.satflag)
                session.stats.epochs_rebaselined += 1
                _cause_event!(:rebaseline, 1, @sprintf("hole of %.1f s before epoch %.1f", gap_s, sod))
            else
                xk, _res, sats, sV, dg = _phva().vds_filter(state.data, options, state.fi)
                state.data.psV = sV
                state.last_xs = collect(xk)
                state.last_sno = sats.sno
                # The filter doesn't return a scalar residual; use σ̂ (sV) as a proxy.
                state.last_res = sV
                if state.warmup > 0
                    # Warm-up epoch (see BridgeState.warmup): the model chain is
                    # advanced but the displacement is withheld and kept out
                    # of the outlier guard's history.
                    state.warmup -= 1
                    _satflag_clear!(state.satflag)
                    state.last_xs = fill(NaN, length(state.last_xs))
                    session.stats.epochs_rebaselined += 1
                    _cause_event!(:rebaseline, 1, "warm-up epoch withheld")
                else
                    # Bridge-side outlier guard: if dXYZ is an obvious outlier relative
                    # to the recent history, blank it out for this epoch. PPPHVA's own
                    # outlier rejection runs only when std(Vk) > 2.5·sV (the MATLAB
                    # original's gate) which lets single-satellite slips through.
                    state.last_dg = dg
                    _satflag_update!(state.satflag, dg)
                    _cons_update!(state, dg)
                    isempty(state.satflag.prn) || _cause_event!(:satflag, 1, _satflag_note(state.satflag))
                    iv = session.stats.input_interval_s
                    dt = (isfinite(iv) && iv > 0) ? iv : 0.1
                    _quality_gate!(state, session.profile, dg, dt) ||
                        _outlier_guard!(state, session.profile)
                end
            end
            state.fi += 1
        end
    catch err
        # Rate-limit the warning to once every 10 epochs so the terminal
        # doesn't flood when a persistent error keeps firing.
        if state.fi % 10 == 0 || state.fi == 1
            @warn "$(_engine_is_plugin(session.profile) ? session.profile.engine : "PPPHVA") step failed at sod=$(sod)  fi=$(state.fi)  err=$(sprint(showerror, err))"
        end
    end
    # Yield to the Gtk event loop so the window stays responsive when the
    # bridge is keeping up with a 1-Hz stream — Julia's task scheduler is
    # cooperative and won't preempt us between sockets.
    yield()
    state.options = options
    # Stats + log line
    session.stats.last_epoch_sod = sod
    session.stats.last_epoch_nsat = nobs
    if !isempty(state.last_xs)
        session.stats.last_residual_m = state.last_res
        dx = state.last_xs[1]; dy = state.last_xs[2]; dz = state.last_xs[3]
        session.stats.last_position_dxyz = (dx, dy, dz)
        if !any(isnan, (dx, dy, dz)) && sqrt(dx*dx + dy*dy + dz*dz) > 0.05
            _cause_event!(:spike, 1, @sprintf("|dXYZ| %.0f mm at epoch %.1f, %d sats", 1000 * sqrt(dx*dx + dy*dy + dz*dz), sod, state.last_sno))
        end
        # Convert ECEF dXYZ to local NEU and push to the rolling history that
        # the GUI's time-series plot reads. Outliers (rejected upstream) leave
        # last_xs as NaN, so they don't pollute the plot.
        if !any(isnan, (dx, dy, dz)) && !all(isnan, state.rec_pos)
            try
                A = _ecef2neu_matrix(state.rec_pos)
                N = A[1,1]*dx + A[1,2]*dy + A[1,3]*dz
                E = A[2,1]*dx + A[2,2]*dy + A[2,3]*dz
                U = A[3,1]*dx + A[3,2]*dy + A[3,3]*dz
                lock(session.stats.lock) do
                    push!(session.stats.displacement_history, (sod, N, E, U))
                    _trim_history!(session.stats.displacement_history)
                end
            catch err
                @debug "NEU conversion failed" err
            end
        end
        # Push the residual statistics (one entry per accepted epoch): the
        # engine's own sigma, the weighted and unweighted post-fit RMS of the
        # satellites kept, and the smoothed sigma (300/30-epoch window) of the weighted RMS.
        rms_w, rms_u, _ = _resid_rms(state.last_dg)
        sva = _sigma_va_update!(session.stats, rms_w)
        lock(session.stats.lock) do
            push!(session.stats.residual_history, (sod, state.last_res, rms_w, rms_u, sva))
            _trim_history!(session.stats.residual_history)
        end
        # Compute geometry metrics from the per-epoch elevation/azimuth grid
        # PPPHVA already populated in data.loc.<sys>, and push.
        nsats_now = 0; hdop_now = NaN; vdop_now = NaN
        try; lock(() -> _push_skyplot_tracks!(session, state), session.stats.lock); catch err
            @debug "skyplot track push failed" err
        end
        try
            nsats, gdop, pdop, hdop, vdop = _compute_dop(state)
            nsats_now = nsats; hdop_now = hdop; vdop_now = vdop
            lock(session.stats.lock) do
                push!(session.stats.dop_history,
                      (sod, Float64(nsats), gdop, pdop, hdop, vdop))
                _trim_history!(session.stats.dop_history)
            end
        catch err
            @debug "DOP computation failed" err
        end
        # miniSEED CSV sink — one line per accepted epoch.
        _write_miniseed_csv(session, sod, nsats_now, hdop_now, vdop_now)
        # Direct miniSEED .mseed sink (three channels: N/E/Z).
        _write_miniseed_mseed(session, sod)
        _log_epoch(session, sod)
    end
    return
end

# Direct miniSEED feed. Lazily creates one MiniSEEDWriter per channel the
# first time a usable displacement reaches us; subsequent accepted epochs
# each push one sample to each writer. Writers buffer up to
# `MSEED_SAMPLES_PER_REC` (112) samples before flushing a 512-byte record.
# The miniSEED header rate MUST equal the epoch rate of the solution: the
# writer never resamples, one solved epoch = one sample, and a wrong header
# makes every consumer stretch or squeeze the time axis (a 1 Hz header on
# 0.1 s epochs = 10x). The true rate is known by now from the stream
# (`input_interval_s`, learned before the first displacement exists); if the
# profile disagrees by more than 10 % the learned rate wins, loudly.
function _mseed_rate(session::NtripSession)
    p = session.profile
    iv = session.stats.input_interval_s
    (isnan(iv) || iv <= 0) && return p.miniseed_sample_rate_hz
    learned = round(1.0 / iv; digits = 3)
    if abs(learned - p.miniseed_sample_rate_hz) > 0.1 * learned
        @warn "miniseed_sample_rate_hz in the profile does not match the stream — using the stream rate for the miniSEED headers" profile_hz=p.miniseed_sample_rate_hz stream_hz=learned profile=p.name
        session.stats.error_message = @sprintf("miniSEED rate corrected: profile %.3g Hz, stream %.3g Hz — fix miniseed_sample_rate_hz", p.miniseed_sample_rate_hz, learned)
        return learned
    end
    return p.miniseed_sample_rate_hz
end

# Seconds to subtract from a decoder SOD of `sys` to get UTC seconds-of-day.
_sod_utc_offset(sys::Char) = (sys == 'G' || sys == 'E') ? GPS_UTC_LEAP_S :
                             sys == 'C' ? GPS_UTC_LEAP_S - 14.0 : 0.0
# UTC DateTime of an epoch given its decoder SOD (date taken from the wall
# clock, which is within a second of the epoch in real time).
function _epoch_utc(sod::Float64, sys::Char)
    base = Dates.now(Dates.UTC)
    midnight = DateTime(Dates.year(base), Dates.month(base), Dates.day(base))
    ts = midnight + Dates.Millisecond(round(Int64, (sod - _sod_utc_offset(sys)) * 1000))
    # wall clock just past midnight but the epoch is still yesterday (or the reverse)
    d = Dates.value(ts - base)
    d >  43_200_000 && (ts -= Dates.Day(1))
    d < -43_200_000 && (ts += Dates.Day(1))
    return ts
end

function _write_miniseed_mseed(session::NtripSession, sod::Float64)
    p = session.profile
    isempty(p.miniseed_mseed_dir) && return

    # Latest accepted displacement for this epoch — skip when the bridge
    # didn't push anything (outlier / failure) so the sample timeline stays
    # aligned with the accepted-epoch counter.
    isempty(session.stats.displacement_history) && return
    t, N, E, U = session.stats.displacement_history[end]
    t == sod || return
    (isnan(N) || isnan(E) || isnan(U)) && return

    # Lazily create the three writers on first use.
    if session.mseed_writers === nothing
        station = isempty(p.miniseed_station) ? p.mountpoint : p.miniseed_station
        prefix  = isempty(p.miniseed_channel_prefix) ? "LN" : p.miniseed_channel_prefix
        chN = prefix * "N"; chE = prefix * "E"; chZ = prefix * "Z"
        try
            rate = _mseed_rate(session)
            # SeedLink service: tee every flushed record to a ringserver over
            # DataLink when the profile names a host. The client connects
            # lazily on the first record and reconnects by itself.
            tee = nothing
            if !isempty(p.datalink_host)
                session.datalink === nothing &&
                    (session.datalink = DataLinkClient(p.datalink_host, p.datalink_port))
                dl = session.datalink
                net = p.miniseed_network; loc = p.miniseed_location
                tee = ch -> (rec, t0, t1) -> push_record!(dl, rec, net, station, loc, ch, t0, t1)
                @info "DataLink push enabled" host=p.datalink_host port=p.datalink_port
            end
            mk(ch) = MiniSEEDWriter(p.miniseed_mseed_dir, p.miniseed_network,
                                    station, p.miniseed_location, ch, rate;
                                    flush_interval_sec = p.miniseed_flush_interval_sec,
                                    on_record = tee === nothing ? nothing : tee(ch))
            wN = mk(chN); wE = mk(chE); wZ = mk(chZ)
            session.mseed_writers = (N = wN, E = wE, Z = wZ)
            @info "miniSEED feed enabled" dir=p.miniseed_mseed_dir station=station channels=(chN, chE, chZ)
        catch err
            @warn "Could not create miniSEED writers — disabling feed" err
            session.mseed_writers = nothing
            return
        end
    end

    # Use wall-clock UTC for the sample timestamp (the bridge runs in
    # near-real-time). SOD-only timestamps from the obs stream don't carry
    # the date, so we derive year/DOY from `now(UTC)` and patch the
    # seconds-of-day in from the epoch. This avoids a date-rollover bug
    # when the obs stream loops through midnight.
    base = Dates.now(Dates.UTC)
    # Replace base's intra-day time with `sod` seconds — converted to UTC.
    # The decoder's SOD is the constellation's own time scale (GPS/Galileo
    # time = UTC + 18 s, BDT = UTC + 4 s, GLONASS already UTC after the
    # decoder's −3 h). miniSEED consumers expect UTC; until 2026-09-10 the
    # records were stamped in GPS time, i.e. 18 s ahead of UTC.
    midnight = DateTime(Dates.year(base), Dates.month(base), Dates.day(base))
    ts = midnight + Dates.Millisecond(round(Int64, (sod - _sod_utc_offset(_primary_sys(p))) * 1000))
    # If the obs clock jumped backwards relative to wall-clock UTC (e.g.,
    # the stream is replaying a file), fall back to wall-clock so the
    # writer's monotonic time guarantee survives.
    abs(Dates.value(ts - base)) > 86_400_000 && (ts = base)

    scale = p.miniseed_scale
    function to_cnt(x::Float64)
        v = round(Int64, x * scale)
        Int32(clamp(v, Int64(typemin(Int32)), Int64(typemax(Int32))))
    end
    try
        ws = session.mseed_writers
        append_sample!(ws.N, ts, to_cnt(N))
        append_sample!(ws.E, ts, to_cnt(E))
        append_sample!(ws.Z, ts, to_cnt(U))
        # Metrics: an empty buffer after append means a record just hit the
        # disk for this epoch (always true with flush interval 0).
        isempty(ws.Z.buffer) && (session.stats.mseed_last_flush_sod = sod)
    catch err
        @debug "miniSEED append failed" err
    end
    return
end

# Append one CSV row for the seedlink/miniSEED feeder. Reads the latest NEU
# from `displacement_history`; if the bridge rejected this epoch as an
# outlier we still emit a row with NaNs in the position columns so the
# downstream sample counter doesn't drift. Each open is short-lived (open →
# write → close) so an external tail-and-pack process can read the file
# without locking issues; for high-rate feeds this should be promoted to a
# persistent IO handle.
function _write_miniseed_csv(session::NtripSession, sod::Float64,
                              nsats::Int, hdop::Float64, vdop::Float64)
    path = session.profile.miniseed_csv_path
    isempty(path) && return
    try
        mkpath(dirname(path))
        # Latest accepted displacement (NaN if outlier-guarded out this epoch).
        Nm = NaN; Em = NaN; Um = NaN; sigma = NaN
        if !isempty(session.stats.displacement_history)
            t, N, E, U = session.stats.displacement_history[end]
            if t == sod
                Nm = N; Em = E; Um = U
            end
        end
        if !isempty(session.stats.residual_history)
            t, s = session.stats.residual_history[end]
            t == sod && (sigma = s)
        end
        scale = session.profile.miniseed_scale
        to_cnt(x) = isnan(x) ? typemin(Int32) : Int32(clamp(round(Int64, x * scale),
                                                             typemin(Int32), typemax(Int32)))
        Ncnt = to_cnt(Nm); Ecnt = to_cnt(Em); Ucnt = to_cnt(Um)

        # ISO timestamp from now() — the bridge runs in near-real-time, so
        # epoch SOD ≈ wall clock UTC seconds-of-day. Downstream miniSEED
        # records prefer an explicit ISO string for the first-sample time.
        # Epoch time in UTC (not the wall clock, which is the receipt time).
        iso = Dates.format(_epoch_utc(sod, _primary_sys(session.profile)), "yyyy-mm-ddTHH:MM:SS.sss") * "Z"

        # First write: emit a header line if the file doesn't exist yet.
        write_header = !isfile(path)
        open(path, "a") do io
            if write_header
                println(io, "iso_utc,sod,N_m,E_m,U_m,sigma_m,nsats,hdop,vdop,N_cnt,E_cnt,U_cnt")
            end
            println(io, @sprintf(
                "%s,%.3f,%.6f,%.6f,%.6f,%.6f,%d,%.3f,%.3f,%d,%d,%d",
                iso, sod, Nm, Em, Um, sigma,
                nsats, hdop, vdop, Ncnt, Ecnt, Ucnt))
        end
    catch err
        @debug "miniSEED CSV write failed" err path
    end
    return
end

# Compute the geometric dilution-of-precision metrics from the sat
# azimuth/elevation table PPPHVA fills in `state.data.loc.<sys>` (degrees,
# NaN for unseen sats). Returns `(nsats, GDOP, PDOP, HDOP, VDOP)` — DOPs are
# NaN when fewer than 4 sats are visible (matrix singular) or any
# normal-equations inversion fails.
# Append this epoch's azimuth/elevation for every visible satellite to the
# per-PRN trail the skyplot draws. Same `state.data.loc.<sys>` table
# `_compute_dop` reads (degrees, NaN for unseen sats).
# Samples are taken on movement (see the 0.02 deg gate below), not per
# epoch, so this is ~2.5 s per sample regardless of stream rate --
# 1800 samples is a bit over an hour of trail. ~30 sats x 1800 x 16 B
# is under a megabyte.
const SKYPLOT_TRACK_MAX = 1800

function _push_skyplot_tracks!(session::NtripSession, state::BridgeState)
    hasfield_p_safe(state.data, :loc) || return
    loc = state.data.loc
    tracks = session.stats.skyplot_tracks
    seen = Set{Tuple{Symbol,Int}}()
    for sysf in (:gps, :glo, :gal, :bds)
        hasfield_p_safe(loc, sysf) || continue
        arr = getproperty(loc, sysf)
        size(arr, 1) == 0 && continue
        for prn in 1:size(arr, 1)
            az_deg  = arr[prn, 1]
            elv_deg = arr[prn, 2]
            (isnan(az_deg) || isnan(elv_deg) || elv_deg <= 0.0) && continue
            key = (sysf, prn)
            push!(seen, key)
            tr = get!(() -> NTuple{2,Float64}[], tracks, key)
            # Skip a sample that has not moved perceptibly — at 10 Hz the
            # trail would otherwise be 10x denser for no visual gain.
            if isempty(tr) || abs(tr[end][1] - az_deg) > 0.02 ||
                              abs(tr[end][2] - elv_deg) > 0.02
                push!(tr, (az_deg, elv_deg))
                length(tr) > SKYPLOT_TRACK_MAX && popfirst!(tr)
            end
        end
    end
    # Drop trails for satellites that have set, so the dict cannot grow
    # without bound across a long session.
    for key in collect(keys(tracks))
        key in seen || delete!(tracks, key)
    end
    return
end

# `used` (a set of PPPHVA satellite numbers, e.g. dg.prn) restricts the geometry to the
# satellites of the fit; nothing = all visible satellites above the horizon.
const _SAT_OFFSET = (gps = 0, glo = 32, gal = 58, bds = 94)
function _compute_dop(state::BridgeState; used = nothing)
    nsats = 0
    sumE2 = 0.0; sumN2 = 0.0; sumU2 = 0.0
    sumEN = 0.0; sumEU = 0.0; sumNU = 0.0
    sumE  = 0.0; sumN  = 0.0; sumU  = 0.0
    if !hasfield_p_safe(state.data, :loc)
        return (0, NaN, NaN, NaN, NaN)
    end
    loc = state.data.loc
    for sysf in (:gps, :glo, :gal, :bds)
        hasfield_p_safe(loc, sysf) || continue
        arr = getproperty(loc, sysf)
        size(arr, 1) == 0 && continue
        off = _SAT_OFFSET[sysf]
        for prn in 1:size(arr, 1)
            used === nothing || (off + prn) in used || continue
            az_deg  = arr[prn, 1]
            elv_deg = arr[prn, 2]
            (isnan(az_deg) || isnan(elv_deg) || elv_deg <= 0.0) && continue
            az  = az_deg  * π/180
            elv = elv_deg * π/180
            # NEU unit line-of-sight vector to the satellite.
            losE = cos(elv) * sin(az)
            losN = cos(elv) * cos(az)
            losU = sin(elv)
            # G^T G accumulators (the 4th column of G is all ones for the
            # receiver clock partial → sum_ones = nsats, sum_los* = -∑LOS).
            sumE2 += losE*losE; sumN2 += losN*losN; sumU2 += losU*losU
            sumEN += losE*losN; sumEU += losE*losU; sumNU += losN*losU
            sumE  += losE;      sumN  += losN;      sumU  += losU
            nsats += 1
        end
    end
    nsats < 4 && return (nsats, NaN, NaN, NaN, NaN)
    M = [sumE2  sumEN  sumEU  sumE;
         sumEN  sumN2  sumNU  sumN;
         sumEU  sumNU  sumU2  sumU;
         sumE   sumN   sumU   Float64(nsats)]
    Q = try
        inv(M)
    catch
        return (nsats, NaN, NaN, NaN, NaN)
    end
    hdop = sqrt(max(Q[1,1] + Q[2,2], 0.0))
    vdop = sqrt(max(Q[3,3], 0.0))
    pdop = sqrt(max(Q[1,1] + Q[2,2] + Q[3,3], 0.0))
    gdop = sqrt(max(Q[1,1] + Q[2,2] + Q[3,3] + Q[4,4], 0.0))
    return (nsats, gdop, pdop, hdop, vdop)
end

# Build the 3×3 rotation matrix that converts an ECEF displacement vector
# into the local topocentric (N, E, U) frame anchored at `rec_xyz`.
function _ecef2neu_matrix(rec_xyz::NTuple{3,Float64})
    a  = 6378137.0
    f  = 1/298.257223563
    e2 = 2f - f^2
    x, y, z = rec_xyz
    lon = atan(y, x)
    p   = sqrt(x^2 + y^2)
    φ   = atan(z/(p*(1 - e2)))
    for _ in 1:30
        N  = a/sqrt(1 - e2*sin(φ)^2)
        h  = p/cos(φ) - N
        φ_ = atan((z/p)/(1 - (N/(N+h))*e2))
        abs(φ_ - φ) < 1e-12 && (φ = φ_; break)
        φ = φ_
    end
    sφ, cφ = sin(φ), cos(φ)
    sλ, cλ = sin(lon), cos(lon)
    # rows: [N; E; U]
    return @inbounds Float64[
        -sφ*cλ  -sφ*sλ   cφ;
        -sλ      cλ      0;
         cφ*cλ   cφ*sλ   sφ
    ]
end

function _log_epoch(session::NtripSession, sod::Float64)
    session.log_file === nothing && return
    state = session.bridge_state
    xs = state.last_xs
    pad = (i) -> i <= length(xs) ? xs[i] : NaN
    # post-fit residuals of the satellites kept: weighted RMS (the engine's own
    # unit-weight figure) and unweighted RMS (comparable across engines)
    rms_w, rms_u, nused = (length(xs) >= 3 && !any(isnan, xs[1:3])) ? _resid_rms(state.last_dg) : (NaN, NaN, 0)
    Printf.@printf(session.log_file,
        "%9.3f %3d %12.6f %12.6f %12.6f %12.6f %12.6f %12.6f %3d %9.4f %9.4f\n",
        sod, state.last_sno,
        pad(1), pad(2), pad(3), pad(4), pad(5), pad(6), nused, rms_w, rms_u)
    flush(session.log_file)
end

# ---------------------------------------------------------------------------
# Engine plug-in path (profile.engine != "ppphva"). Mirrors the PPPHVA branch
# of _solve_group!: feeds new ephemerides, hands the group's frames to the
# engine, then runs the same warm-up, hole, flag and gate logic on its result
# so logs, Causes, /status.json and the outputs are identical in form.
function _plugin_solve!(session::NtripSession, decoder::RtcmDecoder, state::BridgeState,
                        g::EpochGroup, sod::Float64, nav_sig::Dict{Tuple{Char,Int},UInt})
    p = session.profile
    week = _engine_week(decoder, session)
    if state.engine === nothing
        sym = _load_engine!(p)
        desc = decoder.descriptor === nothing ? "" : decoder.descriptor.antenna_descriptor
        rcv = decoder.descriptor === nothing ? "" : decoder.descriptor.receiver_type
        st = EAPI.Station(xyz = state.rec_pos, antenna = desc, receiver = rcv, antex = p.antex_file)
        # the package may have been loaded a moment ago: call through the latest world
        state.engine = Base.invokelatest(EAPI.create_engine, sym, st, _engine_options(p))
        state.engine_info = Base.invokelatest(EAPI.engine_info, state.engine)
        @info "engine plug-in started" engine = p.engine info = state.engine_info station = state.rec_pos
    end
    eng = state.engine
    ep = _frames_to_obsepoch(g.frames, week)
    ep === nothing && return
    t_abs = ep.t.week * 604800.0 + ep.t.tow
    # new or changed broadcast records -> the engine (it keeps its own pairing
    # rule); the epoch's own time places seconds-of-day/week references
    for ((sys, prn), rec) in decoder.eph
        rec.valid || continue
        h = get(nav_sig, (sys, prn), zero(UInt))
        get(state.engine_nav_sig, (sys, prn), zero(UInt)) == h && continue
        try
            Base.invokelatest(EAPI.engine_nav!, eng, EAPI.NavRow(sys, prn, rec.row), ep.t)
            state.engine_nav_sig[(sys, prn)] = h
        catch err
            @debug "engine_nav! failed" sys prn err
        end
    end
    nav_changed = _nav_changed(state.nav_sig, nav_sig)
    isempty(nav_changed) || (state.eph_changes += length(nav_changed); _cause_event!(:ephswitch, 1, first(join(nav_changed, " "), 60)))
    # hole in the input longer than the profile allows: restart the pairing
    iv = session.stats.input_interval_s
    mg = p.max_gap_epochs
    if mg > 0 && isfinite(state.engine_prev_t) && isfinite(iv) && iv > 0 && (t_abs - state.engine_prev_t) > (mg + 0.5) * iv
        Base.invokelatest(EAPI.engine_reset!, eng)
        state.last_xs = fill(NaN, max(length(state.last_xs), 3))
        _satflag_clear!(state.satflag)
        session.stats.epochs_rebaselined += 1
        _cause_event!(:rebaseline, 1, @sprintf("hole of %.1f s before epoch %.1f", t_abs - state.engine_prev_t, sod))
    end
    state.engine_prev_t = t_abs

    res = Base.invokelatest(EAPI.engine_step!, eng, ep)::EAPI.EngineResult
    if res.status != :ok
        # first epoch of a pair, or no fit: nothing published for this epoch
        state.last_xs = fill(NaN, max(length(state.last_xs), 6))
        _satflag_clear!(state.satflag)
        if res.status != :first
            session.stats.epochs_rebaselined += 1
            _cause_event!(:rebaseline, 1, "engine: $(res.status), $(res.nsat_in) sats offered")
        end
        return
    end
    clk(c) = get(res.clk, c, NaN)
    state.last_xs = [res.dxyz[1], res.dxyz[2], res.dxyz[3], clk('G'), clk('R'), clk('E')]
    state.last_sno = res.nsat_used
    state.last_res = res.rms_m
    _plugin_publish_sats!(state, res)
    dg = _engine_dg(res)
    state.last_dg = dg
    if state.warmup > 0
        state.warmup -= 1
        _satflag_clear!(state.satflag)
        state.last_xs = fill(NaN, length(state.last_xs))
        session.stats.epochs_rebaselined += 1
        _cause_event!(:rebaseline, 1, "warm-up epoch withheld")
        return
    end
    _satflag_update!(state.satflag, dg)
    _cons_update!(state, dg)
    isempty(state.satflag.prn) || _cause_event!(:satflag, 1, _satflag_note(state.satflag))
    dt = (isfinite(iv) && iv > 0) ? iv : 0.1
    _quality_gate!(state, p, dg, dt; pdop_hint = res.pdop) || _outlier_guard!(state, p)
    return
end

# Per-satellite azimuth/elevation of the engine's result in the `data.loc`
# layout the skyplot and the DOP tab read (matrices [prn, (az deg, el deg)]
# per system), and the engine's post-fit RMS as `data.psV` for the σ̂ panel.
function _plugin_publish_sats!(state::BridgeState, res)
    sizes = Dict(:gps => 32, :glo => 26, :gal => 36, :bds => 63)
    loc = _pstruct()
    for (f, n) in sizes
        setproperty!(loc, f, fill(NaN, n, 2))
    end
    for r in res.sats
        f = r.sys == 'G' ? :gps : r.sys == 'R' ? :glo : r.sys == 'E' ? :gal : :bds
        arr = getproperty(loc, f)
        (1 <= r.prn <= size(arr, 1) && isfinite(r.elev_deg)) || continue
        arr[r.prn, 1] = mod(r.azim_deg, 360.0)
        arr[r.prn, 2] = r.elev_deg
    end
    try
        state.data.loc = loc
        state.data.psV = res.rms_m
    catch err
        @debug "publishing engine satellites failed" err
    end
    return
end

# Weighted and unweighted RMS of the post-fit residuals of the satellites kept,
# from the per-satellite set `dg` (prn, res, w, removed) of either engine.
function _resid_rms(dg)
    (dg === nothing || isempty(dg.prn)) && return (NaN, NaN, 0)
    n = length(dg.prn)
    sw = sum(dg.w)
    rms_w = sw > 0 ? sqrt(sum(dg.w .* dg.res .^ 2) / sw) : NaN
    rms_u = sqrt(sum(dg.res .^ 2) / n)
    return (rms_w, rms_u, n)
end

# Smoothed sigma of the per-epoch weighted RMS (the windowed estimator the
# platform used since 0.4.2, here applied to either engine): the cumulative mean of the per-epoch weighted RMS for the first 300 epochs, then
# an exponential average that follows increases with a 300-epoch time
# constant and decreases with a 30-epoch one; an epoch larger than three times
# the current value enters capped at that, so one bad epoch cannot poison it.
function _sigma_va_update!(st::SessionStats, rms_w::Float64)
    isfinite(rms_w) || return st.resid_sigma_va
    n = st.resid_sigma_n
    if n == 0 || !isfinite(st.resid_sigma_va)
        st.resid_sigma_va = rms_w; st.resid_sigma_n = 1
        return st.resid_sigma_va
    end
    x = min(rms_w, 3.0 * st.resid_sigma_va)
    if n < 300
        st.resid_sigma_va += (x - st.resid_sigma_va) / (n + 1)
    else
        alpha = x > st.resid_sigma_va ? 1 / 300 : 1 / 30
        st.resid_sigma_va += alpha * (x - st.resid_sigma_va)
    end
    st.resid_sigma_n = n + 1
    return st.resid_sigma_va
end
