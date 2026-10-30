# Diagnostic dump used by the GUI's Debug window.
# Returns a single human-readable text block with everything we'd need to
# diagnose why PPP-VA isn't producing displacements.

"""
    diagnostic_dump(session::NtripSession) -> String

Snapshot the full state of a running (or stopped) session: profile, stats,
RTCM decoder counters, bridge state including the registered observation
codes per constellation, and a top-level diagnosis of why dXYZ isn't being
produced (if it isn't).
"""
function diagnostic_dump(session::NtripSession)
    io = IOBuffer()
    p   = session.profile
    st  = session.stats
    bs  = session.bridge_state

    _line(s = "") = println(io, s)
    _hdr(s)       = (_line(); _line("── " * s * " " * "─"^max(0, 70 - length(s))))

    _line("GaiaSeis diagnostic — $(Dates.now())")
    _line("=" ^ 76)

    _hdr("Profile  $(p.name)")
    _line("  obs : $(p.caster):$(p.port)/$(p.mountpoint)  user=$(p.user)  pw=$(isempty(p.password) ? "(empty)" : "***")")
    _line("  ssr : use_ssr=$(p.use_ssr)  $(p.ssr_caster):$(p.ssr_port)/$(p.ssr_mountpoint)  user=$(p.ssr_user)  pw=$(isempty(p.ssr_password) ? "(empty)" : "***")")
    _line("  eph : use_eph=$(p.use_eph)  $(p.eph_caster):$(p.eph_port)/$(p.eph_mountpoint)  user=$(p.eph_user)  pw=$(isempty(p.eph_password) ? "(empty)" : "***")")
    _line("  GGA seed         : lat=$(p.gga_lat_deg)  lon=$(p.gga_lon_deg)  h=$(p.gga_height_m)  (send=$(p.send_gga))")
    _line("  constellations   : GPS=$(p.enable_gps)  GLO=$(p.enable_glo)  GAL=$(p.enable_gal)  BDS=$(p.enable_bds)  incomplete-epochs=$(p.solve_incomplete_epochs ? "solve" : "skip")")
    _line("  process mode     : $(p.process_mode)  elv-cut=$(p.elv_cutoff_deg)°")

    _hdr("Session stats")
    _line("  connected (obs)  : $(st.connected)")
    _line("  isrunning        : $(isrunning(session))")
    _line("  bytes received   : $(st.bytes_received)")
    _line("  reconnects       : obs $(st.reconnects_obs)  ssr $(st.reconnects_ssr)  eph $(st.reconnects_eph)" *
          (st.last_stall_at == DateTime(0) ? "" :
           "   last stall $(Dates.format(st.last_stall_at, "yyyy-mm-ddTHH:MM:SSZ"))"))
    for o in st.outages
        dur = isnan(o[2]) ? "open" : @sprintf("%.1f s", _sod_diff(o[2], o[1]))
        kind = o[3] == 1.0 ? "obs" : o[3] == 2.0 ? "ssr" : "eph"
        _line(@sprintf("  outage           : %s  from wall-UTC sod %.1f  duration %s", kind, o[1], dur))
    end
    for d in st.drop_log
        _line("  drop             : " * d)
    end
    _line("  frames decoded   : $(st.frames_total)  (bad CRC: $(st.frames_crc_failed))")
    _line("  last msg type    : $(st.last_msg_type)")
    _line("  last epoch SOD   : $(st.last_epoch_sod)  (nsat=$(st.last_epoch_nsat))")
    _line("  last residual σ  : $(st.last_residual_m)")
    _line("  last dXYZ        : $(st.last_position_dxyz)")
    # Render a fully-qualified stream timestamp. PREFERS the GPS week + obs
    # TOW pair (taken from the RTCM payload itself, so correct for replays);
    # falls back to the wall-clock byte-arrival anchor when the GPS week
    # hasn't been observed yet (no 1019 message decoded).
    _GPS_EPOCH_LOCAL = DateTime(1980, 1, 6)
    function _fmt_sod_with_anchor(sod::Float64, anchor::DateTime)
        isnan(sod) && return "—"
        sod_mod = mod(sod, 86400.0)
        h = floor(Int, sod_mod/3600); rem = sod_mod - 3600*h
        m = floor(Int, rem/60);       rem -= 60*m
        hms = @sprintf("%02d:%02d:%05.2f", h, m, rem)
        date_part = ""
        if st.gps_week > 0 && !isnan(st.last_obs_stream_tow)
            dow = floor(Int, mod(st.last_obs_stream_tow, 7*86400.0) / 86400)
            dt  = _GPS_EPOCH_LOCAL + Dates.Day(7*st.gps_week + dow)
            date_part = Dates.format(Dates.Date(dt), "yyyy-mm-dd ")
        elseif anchor != DateTime(0)
            anchor_sod = Dates.value(Dates.Time(anchor) - Dates.Time(0)) / 1_000_000_000
            diff = sod_mod - anchor_sod
            day_offset = diff > 43200.0 ? -1 : diff < -43200.0 ? 1 : 0
            d = Dates.Date(anchor) + Dates.Day(day_offset)
            date_part = Dates.format(d, "yyyy-mm-dd ")
        end
        return date_part * hms * @sprintf(" (SOD=%.2f)", sod)
    end
    _line("  GPS week (1019)  : $(st.gps_week == 0 ? "—" : st.gps_week)" *
          (isnan(st.last_obs_stream_tow) ? "" :
           "   obs TOW=" * @sprintf("%.2f", st.last_obs_stream_tow) *
           " (dow=" * string(floor(Int, mod(st.last_obs_stream_tow, 7*86400.0)/86400)) * ")"))
    _line("  last obs frame   : rx $(st.last_obs_byte_at == DateTime(0) ? "—" :
                                     Dates.format(st.last_obs_byte_at, "yyyy-mm-ddTHH:MM:SSZ"))" *
          "   stream " * _fmt_sod_with_anchor(st.last_obs_stream_sod, st.last_obs_byte_at))
    _line("  last ssr frame   : rx $(st.last_ssr_byte_at == DateTime(0) ? "—" :
                                     Dates.format(st.last_ssr_byte_at, "yyyy-mm-ddTHH:MM:SSZ"))" *
          "   stream " * _fmt_sod_with_anchor(st.last_ssr_stream_sod, st.last_ssr_byte_at))
    _line("  last eph frame   : rx $(st.last_eph_byte_at == DateTime(0) ? "—" :
                                     Dates.format(st.last_eph_byte_at, "yyyy-mm-ddTHH:MM:SSZ"))" *
          "   stream " * _fmt_sod_with_anchor(st.last_eph_stream_sod, st.last_eph_byte_at))
    _line("  have_rec_pos     : $(st.have_rec_pos)")
    _line("  have_ephemeris   : $(st.have_ephemeris)  (n_eph=$(st.n_eph))")
    _line("  have_ssr         : $(st.have_ssr)        (orb=$(st.n_ssr_orb), clk=$(st.n_ssr_clk))")
    _line("  error            : $(st.error_message)")

    if !isempty(st.msg_counts)
        _hdr("RTCM message counts")
        for (mt, n) in sort(collect(st.msg_counts), by = x -> -x[2])
            _line("  $(lpad(mt, 5))  ×$n   $(_message_name(mt))")
        end
    end

    # Which stream each message type arrives on (the sum above mixes the receiver,
    # the ephemeris caster and the SSR caster).
    st_by = st.msg_counts_by
    if !isempty(st_by)
        for kind in (:obs, :eph, :ssr)
            d = get(st_by, kind, nothing)
            (d === nothing || isempty(d)) && continue
            _hdr("RTCM message counts - " * String(kind) * " stream")
            for (mt, n) in sort(collect(d), by = x -> -x[2])
                _line("  $(lpad(mt, 5))  ×$n   $(_message_name(mt))")
            end
        end
    end

    # Per-system MSM7 diagnostics — populated by the obs reader thread.
    dec = _try_get_decoder(session)
    if dec !== nothing && !isempty(dec.msm_frames)
        _hdr("MSM7 per-system breakdown")
        for sys in ('G', 'R', 'E', 'C')
            frames  = get(dec.msm_frames, sys, 0)
            epochs  = get(dec.msm_epochs, sys, 0)
            sm      = get(dec.msm_last_satmask, sys, UInt64(0))
            gm      = get(dec.msm_last_sigmask, sys, UInt32(0))
            mmf     = get(dec.msm_last_mmf, sys, false)
            frames == 0 && continue
            sat_bits = _set_bits(sm, 64)
            sig_bits = _set_bits(UInt64(gm), 32)
            _line("  $sys : frames=$frames  epochs_emitted=$epochs  last MMF=$(mmf)")
            _line("       sat-mask bits = $sat_bits   (= sats: $(join(_sats_for_sys(sys, sat_bits), ',')))")
            _line("       sig-mask bits = $sig_bits   (= codes: $(_codes_for_sys(sys, sig_bits)))")
        end
    end

    if bs === nothing
        _hdr("Bridge state")
        _line("  (not yet initialised — no MSM7 epoch has arrived from the obs stream)")
    else
        _hdr("Bridge state")
        _line("  fi (epoch counter)  : $(bs.fi)")
        _gdesc(g) = g === nothing ? "-" :
            "sod=$(round(g.sod, digits=1))/$(join(sort(collect(g.sys)), ','))" *
            (g.stale ? "/stale" : "") * (g.done ? "/done" : "") * "/nobs=$(g.nobs)"
        _line("  epoch groups        : cur=$(_gdesc(bs.cur))  held=$(_gdesc(bs.held))  " *
              "seen=$(join(sort(collect(bs.seen_sys)), ','))  late-frames=$(bs.late_frames)  incomplete=$(bs.incomplete_groups)")
        _line("  rec_pos (m)         : $(bs.rec_pos)")
        _line("  options.RTC         : $(bs.options.RTC)")
        _line("  options.system      : gps=$(bs.options.system.gps)  glo=$(bs.options.system.glo)  gal=$(bs.options.system.gal)  bds=$(bs.options.system.bds)")
        _line("  last filter sno     : $(bs.last_sno)   (# satellites after dfvsats / sfvsats)")
        _line("  last filter xs      : $(bs.last_xs)")
        _line("  last filter σ̂       : $(bs.last_res)")
        # obs.st cardinality + obs.gps stats so we can see how many sats
        # are "complete" (PR+CP on both freqs) at the moment.
        if hasfield_p_safe(bs.data, :obs)
            obs = bs.data.obs
            if hasfield_p_safe(obs, :st)
                obs_st = obs.st
                _line("  data.obs.st (==1)   : $(count(==(1), obs_st))/$(length(obs_st))")
            end
            if hasfield_p_safe(obs, :gps)
                g = obs.gps
                n_nan = count(isnan, g); tot = length(g)
                _line("  data.obs.gps NaN%  : $(n_nan)/$(tot)  ($(size(g, 1))×$(size(g, 2)))")
            end
        end
        # Per-system PRN coverage — shows the intersection that calcsatnav
        # actually has data for. The set we need at each epoch is
        # OBS ∩ NAV ∩ SSR-ORB ∩ SSR-CLK; if any term is empty we get sno=0.
        if hasfield_p_safe(bs.data, :obs)
            for (sysf, sysc) in ((:gps, 'G'), (:glo, 'R'), (:gal, 'E'), (:bds, 'C'))
                getproperty(bs.options.system, sysf) == 0 && continue
                obs_prns = _prns_with_obs(bs.data, sysf, bs.options, sysf)
                nav_prns = _prns_with_nav(bs.data, sysf)
                ssro = sort([prn for ((s, prn), _) in dec.ssr_orb if s == sysc])
                ssrc = sort([prn for ((s, prn), _) in dec.ssr_clk if s == sysc])
                inter = sort!(intersect(obs_prns, nav_prns, ssro, ssrc))
                _line("  $(string(sysf)) coverage:")
                _line("       obs PRNs        = $obs_prns")
                _line("       nav PRNs        = $nav_prns")
                _line("       ssr-orb PRNs    = $ssro")
                _line("       ssr-clk PRNs    = $ssrc")
                _line("       USABLE (∩)      = $inter   ⟵ this is what calcsatnav can process")
            end
        end
        # Show registered observation codes per system (this is what
        # PPPHVA's dfvotype/sfvotype searches against)
        for sysf in (:gps, :glo, :gal, :bds)
            seq = _try_get(bs.data, [:inf, :seq, sysf])
            _line("  inf.seq.$(string(sysf))           : $(seq === nothing ? "(none)" : join(seq, "  "))")
        end
        for sysf in (:gps, :glo, :gal, :bds)
            for o in (:obsp, :obsl, :obsp2, :obsl2)
                v = _try_get(bs.options, [o, sysf])
                v === nothing && continue
                _line("  options.$(string(o)).$(string(sysf))    : $v")
            end
        end
        # Eligibility (matches the auto-disable logic in bridge_step!)
        _hdr("Filter eligibility (per bridge_step!)")
        is_dfv = p.process_mode == "DFV"
        for (sysf, en) in ((:gps, p.enable_gps), (:glo, p.enable_glo),
                            (:gal, p.enable_gal), (:bds, p.enable_bds))
            elig = _sys_eligible(bs, sysf, en, is_dfv)
            _line("  $(rpad(string(sysf), 4))  profile-enabled=$en   eligible($(p.process_mode))=$elig")
        end
    end

    # Diagnose why no dXYZ
    _hdr("Diagnosis")
    reasons = String[]
    if bs === nothing
        push!(reasons, "Bridge state not initialised → no MSM7 epoch decoded from the obs stream yet.")
    else
        st.have_rec_pos  || push!(reasons, "rec_pos missing (no 1005/1006 + no GGA seed).")
        st.have_ephemeris || push!(reasons, "no ephemeris (n_eph=0 — eph stream not flowing?).")
        if p.use_ssr && !st.have_ssr
            push!(reasons, "use_ssr=true but RTC=0 (missing orb=$(st.n_ssr_orb) or clk=$(st.n_ssr_clk)).")
        end
        # Are any systems eligible?
        is_dfv = p.process_mode == "DFV"
        any_eligible = false
        for (sysf, en) in ((:gps, p.enable_gps), (:glo, p.enable_glo),
                            (:gal, p.enable_gal), (:bds, p.enable_bds))
            if _sys_eligible(bs, sysf, en, is_dfv)
                any_eligible = true; break
            end
        end
        if !any_eligible
            push!(reasons, "no constellation is eligible (probably DFV needs L1+L2 but only one frequency is in inf.seq.*).")
        end
        if bs.fi == 0 && st.have_rec_pos && st.have_ephemeris && any_eligible
            push!(reasons, "fi=0 → filter has been initialised but waiting for second epoch.")
        end
    end
    if isempty(reasons)
        _line("  Nothing blocking visible. Watch the next epoch — dXYZ should appear within 1-2 obs frames.")
    else
        for r in reasons; _line("  • $r"); end
    end

    return String(take!(io))
end

# Friendly RTCM message-name table for the most common things we'd encounter.
const _RTCM_NAMES = Dict(
    1004 => "GPS L1+L2 obs (legacy)",
    1005 => "Station ARP coords",
    1006 => "Station ARP coords + ant. height",
    1007 => "Station antenna descriptor",
    1008 => "Station antenna descriptor + serial",
    1012 => "GLONASS L1+L2 obs (legacy)",
    1019 => "GPS LNAV ephemeris",
    1020 => "GLONASS ephemeris",
    1033 => "Receiver / antenna descriptor",
    1042 => "BeiDou ephemeris",
    1045 => "Galileo F/NAV ephemeris (E5a)",
    1046 => "Galileo I/NAV ephemeris (E1B)",
    1057 => "SSR GPS Orbit",
    1058 => "SSR GPS Clock",
    1059 => "SSR GPS Code Bias",
    1060 => "SSR GPS combined Orbit+Clock",
    1063 => "SSR GLONASS Orbit",
    1064 => "SSR GLONASS Clock",
    1065 => "SSR GLONASS Code Bias",
    1066 => "SSR GLONASS combined Orbit+Clock",
    1077 => "MSM7 GPS observations",
    1087 => "MSM7 GLONASS observations",
    1097 => "MSM7 Galileo observations",
    1127 => "MSM7 BeiDou observations",
    1230 => "GLONASS L1/L2 code-phase biases",
    1240 => "SSR Galileo Orbit",
    1258 => "SSR BeiDou Orbit",
    1259 => "SSR BeiDou Clock",
    1260 => "SSR BeiDou Code Bias",
    1261 => "SSR BeiDou combined Orbit+Clock",
    1241 => "SSR Galileo Clock",
    1242 => "SSR Galileo Code Bias",
    1243 => "SSR Galileo combined Orbit+Clock",
    1265 => "IGS-SSR generic",
)
_message_name(mt::Integer) = get(_RTCM_NAMES, Int(mt), "")

# Defensive nested-property accessor that returns `nothing` if any link is missing.
function _try_get(obj, path::Vector{Symbol})
    cur = obj
    for f in path
        cur === nothing && return nothing
        if _is_pstruct(cur)
            haskey(cur, f) || return nothing
            cur = getproperty(cur, f)
        else
            return nothing
        end
    end
    return cur
end

_try_get_decoder(session::NtripSession) = session.decoder

# PRNs that have at least one non-NaN observation in the pseudorange row that
# dfvotype picked for this constellation.
function _prns_with_obs(data, sysf::Symbol, options, optf::Symbol)
    hasfield_p_safe(data, :obs) || return Int[]
    hasfield_p_safe(data.obs, sysf) || return Int[]
    arr = getproperty(data.obs, sysf)
    size(arr, 1) == 0 && return Int[]
    pi = getproperty(options.obsp, optf)
    if pi isa AbstractVector
        isempty(pi) && return Int[]
        pi = first(pi)
    end
    pi = Int(pi)
    1 <= pi <= size(arr, 1) || return Int[]
    return [j for j in 1:size(arr, 2) if !isnan(arr[pi, j])]
end

# PRNs that have an ephemeris row populated for this constellation
# (column 18 = sqrtA for GPS/GAL, column 11 = X for GLONASS — both must be non-NaN).
function _prns_with_nav(data, sysf::Symbol)
    hasfield_p_safe(data, :nav) || return Int[]
    hasfield_p_safe(data.nav, sysf) || return Int[]
    arr = getproperty(data.nav, sysf)
    size(arr, 1) == 0 && return Int[]
    col = sysf === :glo ? 11 : 18
    return [j for j in 1:size(arr, 1) if !isnan(arr[j, col])]
end

# Return the 1-based MSB-first bit positions set in `mask` (matches how
# RTCM specs index satellite / signal mask bits).
function _set_bits(mask::Unsigned, n::Int)
    out = Int[]
    for i in 1:n
        bit = one(typeof(mask)) << (n - i)
        (mask & bit) != 0 && push!(out, i)
    end
    return out
end

# Pretty-print the satellite-mask bit positions: for a system bit, the
# PRN equals the bit position.
_sats_for_sys(::Char, bits::Vector{Int}) = bits

# Translate signal-mask bit positions to the RINEX-style code strings our
# MSM7 decoder uses, so the dump shows e.g. "1C, 2W (bit 11 NOT mapped)".
function _codes_for_sys(sys::Char, bits::Vector{Int})
    sigmap = sys == 'G' ? _SIGMAP_GPS :
             sys == 'R' ? _SIGMAP_GLO :
             sys == 'E' ? _SIGMAP_GAL :
             sys == 'C' ? _SIGMAP_BDS :
             Dict{Int,Tuple{String,Int}}()
    parts = String[]
    for b in bits
        if haskey(sigmap, b)
            push!(parts, sigmap[b][1])
        else
            push!(parts, "?bit$b")
        end
    end
    return join(parts, ", ")
end
