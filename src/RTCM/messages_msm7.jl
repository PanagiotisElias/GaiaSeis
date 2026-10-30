# RTCM 3 MSM7 (Multiple Signal Message, type 7) decoder.
#
# MSM7 carries the highest-precision pseudorange / carrier-phase /
# Doppler / CNR observations for one GNSS in a single message:
#   1077 = GPS, 1087 = GLONASS, 1097 = Galileo, 1127 = BeiDou.
#
# Wire layout (high-level — see RTCM 10403.3 §3.5.13):
#   12 bits  message number
#   12 bits  reference station ID
#   30 bits  GNSS epoch time (TOW in ms for G/E, BDT for C, time-of-day for R)
#   1  bit   multiple-message bit (0 = last MSM of epoch)
#   3  bits  IODS (set to 0)
#   7  bits  reserved
#   2  bits  clock steering indicator
#   2  bits  external clock indicator
#   1  bit   smoothing indicator
#   3  bits  smoothing interval
#   64 bits  satellite mask  (1 = present)
#   32 bits  signal mask
#   Nsat×Nsig bits cell mask
#
# Satellite data block (DF397/Nsat×8 + DF398/Nsat×10 + DF399/Nsat×14):
#   8  bits  rough integer ms part of range
#   4  bits  extended satellite info (we ignore)
#   10 bits  rough range modulo 1 ms
#   14 bits  rough phase-range rate
#
# Signal data block (per cell):
#   20 bits  fine pseudorange (signed)
#   24 bits  fine phaserange  (signed)
#   10 bits  phase-range lock indicator
#   1  bit   half-cycle ambiguity indicator
#   10 bits  CNR
#   15 bits  fine phaserange rate
#
# Resolutions:  range modulo 1 ms is 2^-10 ms; fine PR is 2^-29 ms;
#               phase rate rough is 2^-1 m/s, fine is 0.0001 m/s.

const _C_LIGHT = 299792458.0
const _MS_PER_LIGHTSEC = 1000.0
const _LIGHT_MS = _C_LIGHT / _MS_PER_LIGHTSEC  # metres per ms of light-time

# MSM7 invalid sentinels (per RTCM)
const _MSM_INV_INT_MS   = 0xFF     # 8-bit
const _MSM_INV_ROUGH_PR = 0x200    # 10-bit signed (sentinel = -2^9? actually 0x200 = -512)
const _MSM_INV_FINE_PR  = -1 << 19 # 20-bit signed sentinel = -2^19
const _MSM_INV_FINE_PH  = -1 << 23 # 24-bit signed sentinel = -2^23

# Signal-mask bit-index (1..32, MSB-first) → RTCM signal ID and human label.
# Source: RTCM 10403.3 tables 3.5-91..-100.  We map to (rinex_code, freq_no).
#   freq_no encodes which PPPHVA frequency slot (1=L1, 2=L2, 5=L5/E5a, etc.)
#
# Only the most common entries needed for PPPHVA's L1+L2/L5 ionosphere-free
# combination are listed below; unknown bits decode to ("",-1) and are stored
# but not used by the bridge.

# GPS signal mask  (1077)
const _SIGMAP_GPS = Dict{Int,Tuple{String,Int}}(
    2  => ("1C", 1),  3  => ("1P", 1),  4  => ("1W", 1),
    8  => ("2C", 2),  9  => ("2P", 2), 10  => ("2W", 2),
    15 => ("2S", 2), 16  => ("2L", 2), 17 => ("2X", 2),
    22 => ("5I", 5), 23  => ("5Q", 5), 24 => ("5X", 5),
)

# GLONASS signal mask (1087)
const _SIGMAP_GLO = Dict{Int,Tuple{String,Int}}(
    2  => ("1C", 1),  3  => ("1P", 1),
    8  => ("2C", 2),  9  => ("2P", 2),
)

# Galileo signal mask (1097)
const _SIGMAP_GAL = Dict{Int,Tuple{String,Int}}(
    2  => ("1C", 1),  3  => ("1A", 1),  4  => ("1B", 1),
    5  => ("1X", 1),  6  => ("1Z", 1),
    8  => ("6C", 6),  9  => ("6A", 6), 10 => ("6B", 6),
    11 => ("6X", 6), 12 => ("6Z", 6),
    14 => ("7I", 7), 15 => ("7Q", 7), 16 => ("7X", 7),
    18 => ("8I", 8), 19 => ("8Q", 8), 20 => ("8X", 8),
    22 => ("5I", 5), 23 => ("5Q", 5), 24 => ("5X", 5),
)

# BeiDou signal mask (1127)
const _SIGMAP_BDS = Dict{Int,Tuple{String,Int}}(
    2  => ("2I", 2),  3  => ("2Q", 2),  4  => ("2X", 2),      # B1I
    8  => ("6I", 6),  9  => ("6Q", 6), 10 => ("6X", 6),      # B3I
    14 => ("7I", 7), 15 => ("7Q", 7), 16 => ("7X", 7),      # B2I / B2b
    22 => ("5D", 5), 23 => ("5P", 5), 24 => ("5X", 5),      # B2a (BDS-3)
    25 => ("7D", 7), 26 => ("7P", 7), 27 => ("7Z", 7),      # B2b (BDS-3)
    30 => ("1D", 1), 31 => ("1P", 1), 32 => ("1X", 1),      # B1C (BDS-3)
)

"""
A decoded MSM7 observation for one (satellite, signal) cell.
The bridge converts these into PPPHVA's obs.gps / obs.glo / … matrices.
"""
struct MsmObservation
    sys::Char           # 'G'/'R'/'E'/'C'
    prn::Int            # 1-based PRN
    rinex_code::String  # e.g. "1C", "2W" — paired with sys char gives "C1C" / "L2W"
    freq_no::Int        # frequency slot (1, 2, 5, 6, 7, 8)
    pseudorange_m::Float64    # NaN if invalid
    carrier_m::Float64        # NaN if invalid (already in metres)
    lock_indicator::Int
    half_cycle_amb::Bool
    cnr_dbhz::Float64
    doppler_mps::Float64      # NaN if invalid
end

"""
One decoded MSM7 epoch for one GNSS.
"""
struct MsmEpoch
    sys::Char
    station_id::Int
    epoch_ms::Float64         # raw GNSS-time encoding (sys-specific; see below)
    sod::Float64              # second-of-day in receiver time-system, for logging
    more_to_follow::Bool
    obs::Vector{MsmObservation}
    sat_mask_raw::UInt64      # diagnostic: bits set tell which satellites were in this frame
    sig_mask_raw::UInt32      # diagnostic: bits set tell which signals
    msg_type::Int             # actual RTCM number (1075/1077/1085/…) — tells MSM variant
end

function _sys_from_msg_type(mt::Int)
    1074 <= mt <= 1077 && return 'G'
    1084 <= mt <= 1087 && return 'R'
    1094 <= mt <= 1097 && return 'E'
    1124 <= mt <= 1127 && return 'C'
    return ' '
end

# True for any MSM4/5/6/7 message we know how to decode. MSM1/2/3 lack one
# or more of the observables we need (PR, phase, CNR) and are skipped.
_is_msm_obs(mt::Int) = _sys_from_msg_type(mt) != ' ' && mod(mt, 10) in (4, 5, 6, 7)

# Bit-widths and LSB scales for each MSM variant. MSM6/7 use the wide
# (high-resolution) signal fields; MSM5/7 carry the rough+fine phase-range
# rate (Doppler) — MSM4 and MSM6 don't.
struct _MsmFmt
    has_ext_info::Bool        # 4-bit extended satellite info per satellite: MSM5/MSM7 only
    has_rough_rate::Bool
    has_fine_rate::Bool
    fine_pr_bits::Int
    fine_pr_lsb_ms::Float64
    fine_ph_bits::Int
    fine_ph_lsb_ms::Float64
    lock_bits::Int
    cnr_bits::Int
    cnr_lsb_db::Float64
end

function _msm_fmt(msg_type::Int)
    last = mod(msg_type, 10)
    hi   = (last == 6 || last == 7)
    doppler = (last == 5 || last == 7)
    return _MsmFmt(
        doppler,                                # has_ext_info (MSM5/7; MSM4/6 have none)
        doppler,                                # has_rough_rate (sat block)
        doppler,                                # has_fine_rate  (sig block)
        hi ? 20 : 15,                           # fine PR bits
        hi ? 1/(1<<29) : 1/(1<<24),             # fine PR LSB (ms)
        hi ? 24 : 22,                           # fine phase bits
        hi ? 1/(1<<31) : 1/(1<<29),             # fine phase LSB (ms)
        hi ? 10 : 4,                            # lock indicator bits
        hi ? 10 : 6,                            # CNR bits
        hi ? 1/16 : 1.0,                        # CNR LSB (dB-Hz)
    )
end

function _sigmap_for(sys::Char)
    sys == 'G' && return _SIGMAP_GPS
    sys == 'R' && return _SIGMAP_GLO
    sys == 'E' && return _SIGMAP_GAL
    sys == 'C' && return _SIGMAP_BDS
    return Dict{Int,Tuple{String,Int}}()
end

function _wavelength_m(sys::Char, prn::Int, freq_no::Int)
    f = _frequency_hz(sys, prn, freq_no)
    f == 0 && return NaN
    return _C_LIGHT / f
end

# Mirror of PPPHVA's gnssfreq table (subset). Avoids a runtime dependency at decode time.
function _frequency_hz(sys::Char, prn::Int, fno::Int)
    glok = (1,-4,5,6,1,-4,5,6,-2,-7,0,-1,-2,-7,0,-1,4,-3,3,2,4,-3,3,2,0,0)
    if sys == 'G'
        fno == 1 && return 10.23e6 * 154
        fno == 2 && return 10.23e6 * 120
        fno == 5 && return 10.23e6 * 115
    elseif sys == 'R'
        prn < 1 || prn > 26 && return 0.0
        fno == 1 && return (1602 + (9/16)*glok[prn])*1e6
        fno == 2 && return (1246 + (7/16)*glok[prn])*1e6
        fno == 3 && return 10.23e6*117.5
    elseif sys == 'E'
        fno == 1 && return 10.23e6*154
        fno == 5 && return 10.23e6*115
        fno == 6 && return 10.23e6*125
        fno == 7 && return 10.23e6*118
        fno == 8 && return 10.23e6*116.5
    elseif sys == 'C'
        fno == 1 && return 10.23e6*154
        fno == 2 && return 10.23e6*152.6
        fno == 5 && return 10.23e6*115
        fno == 6 && return 10.23e6*124
        fno == 7 && return 10.23e6*118
    end
    return 0.0
end

"""
    decode_msm(payload, msg_type) -> MsmEpoch

Generic MSM4/5/6/7 decoder. `msg_type` ∈ 1074-1077, 1084-1087, 1094-1097,
1124-1127 selects both the constellation (107X = GPS, 108X = GLONASS,
109X = Galileo, 112X = BeiDou) and the MSM variant (X4 = MSM4, X5 = MSM5,
…). MSM4/6 omit the Doppler block; MSM4/5 use compact (15/22/4/6-bit)
signal fields, MSM6/7 use the high-resolution (20/24/10/10-bit) ones.
"""
function decode_msm(payload::AbstractVector{UInt8}, msg_type::Int)
    sys = _sys_from_msg_type(msg_type)
    fmt = _msm_fmt(msg_type)
    sigmap = _sigmap_for(sys)
    br = BitReader(payload)
    skipbits!(br, 12)                              # message number
    station_id = Int(readu(br, 12))
    epoch_ms_raw = Float64(readu(br, 30))          # ms in sys-specific time scale
    more_to_follow = readbool(br)                  # multiple-message bit
    skipbits!(br, 3 + 7 + 2 + 2 + 1 + 3)           # IODS + reserved + clk/smooth flags

    sat_mask = readu(br, 64)
    sig_mask = readu(br, 32)
    sats = Int[]
    sigs = Int[]
    for i in 1:64
        bit = UInt64(1) << (64 - i)
        if (sat_mask & bit) != 0
            push!(sats, i)
        end
    end
    for i in 1:32
        bit = UInt32(1) << (32 - i)
        if (sig_mask & bit) != 0
            push!(sigs, i)
        end
    end
    Nsat = length(sats); Nsig = length(sigs)
    cell_present = falses(Nsat, Nsig)
    for i in 1:Nsat, j in 1:Nsig
        cell_present[i,j] = readbool(br)
    end
    Nobs = count(cell_present)

    # Satellite data block. MSM5 / MSM7 carry, per satellite: rough range
    # (integer ms), extended satellite info (4 bits), rough range mod 1 ms and the
    # rough phase-range rate; MSM4 / MSM6 carry only the two rough-range fields
    # (before 2026-10-21 the 4 extended-info bits were skipped for every variant, so
    # MSM4/6 streams were misread from the first satellite block onward).
    rough_int_ms  = Vector{Int}(undef, Nsat)
    rough_mod_ms  = Vector{Int}(undef, Nsat)
    rough_rate    = fmt.has_rough_rate ? Vector{Int}(undef, Nsat) : Int[]
    for i in 1:Nsat; rough_int_ms[i] = Int(readu(br, 8)); end
    if fmt.has_ext_info
        for i in 1:Nsat; skipbits!(br, 4); end       # extended sat info (MSM5/7)
    end
    for i in 1:Nsat; rough_mod_ms[i] = Int(readu(br, 10)); end
    if fmt.has_rough_rate
        for i in 1:Nsat; rough_rate[i] = reads(br, 14); end
    end

    # Signal data block (per cell). Cells are enumerated row-major as in
    # MSM7. Field widths depend on the MSM variant.
    cell_idx = Tuple{Int,Int}[(i,j) for i in 1:Nsat for j in 1:Nsig if cell_present[i,j]]
    fine_pr   = Vector{Int}(undef, Nobs)
    fine_ph   = Vector{Int}(undef, Nobs)
    lock      = Vector{Int}(undef, Nobs)
    half_amb  = Vector{Bool}(undef, Nobs)
    cnr       = Vector{Int}(undef, Nobs)
    fine_rate = fmt.has_fine_rate ? Vector{Int}(undef, Nobs) : Int[]
    for k in 1:Nobs; fine_pr[k]  = reads(br, fmt.fine_pr_bits); end
    for k in 1:Nobs; fine_ph[k]  = reads(br, fmt.fine_ph_bits); end
    for k in 1:Nobs; lock[k]     = Int(readu(br, fmt.lock_bits)); end
    for k in 1:Nobs; half_amb[k] = readbool(br); end
    for k in 1:Nobs; cnr[k]      = Int(readu(br, fmt.cnr_bits)); end
    if fmt.has_fine_rate
        for k in 1:Nobs; fine_rate[k] = reads(br, 15); end
    end

    # Invalid-cell sentinels are the most-negative N-bit value.
    inv_fine_pr = -(1 << (fmt.fine_pr_bits - 1))
    inv_fine_ph = -(1 << (fmt.fine_ph_bits - 1))

    obs = MsmObservation[]
    sizehint!(obs, Nobs)
    for k in 1:Nobs
        i, j = cell_idx[k]
        prn = sats[i]
        sig_bit = sigs[j]
        code, freq_no = get(sigmap, sig_bit, ("", -1))

        # Skip cells with invalid coarse range
        if rough_int_ms[i] == _MSM_INV_INT_MS
            continue
        end

        # Coarse range in metres
        coarse_ms = Float64(rough_int_ms[i]) + Float64(rough_mod_ms[i]) / 1024
        pr_m = NaN
        if fine_pr[k] != inv_fine_pr
            fine_ms = Float64(fine_pr[k]) * fmt.fine_pr_lsb_ms
            pr_m = (coarse_ms + fine_ms) * _LIGHT_MS
        end

        ph_m = NaN
        if fine_ph[k] != inv_fine_ph
            fine_ph_ms = Float64(fine_ph[k]) * fmt.fine_ph_lsb_ms
            ph_m = (coarse_ms + fine_ph_ms) * _LIGHT_MS
        end

        # Doppler (MSM5/7 only): coarse 2^-1 m/s, fine 1e-4 m/s
        doppler = NaN
        if fmt.has_rough_rate && fmt.has_fine_rate
            if rough_rate[i] != -1 << 13 && fine_rate[k] != -1 << 14
                doppler = Float64(rough_rate[i]) + Float64(fine_rate[k]) * 1e-4
            end
        end

        cnr_db = Float64(cnr[k]) * fmt.cnr_lsb_db

        push!(obs, MsmObservation(sys, prn, code, freq_no,
                                  pr_m, ph_m, lock[k], half_amb[k],
                                  cnr_db, doppler))
    end

    sod = _sod_from_epoch_ms(sys, epoch_ms_raw)
    return MsmEpoch(sys, station_id, epoch_ms_raw, sod, more_to_follow, obs,
                    sat_mask, sig_mask, msg_type)
end

"""
    decode_msm7(payload, msg_type) -> MsmEpoch

Backward-compat alias for `decode_msm` — accepts only 1077/1087/1097/1127.
"""
decode_msm7(payload::AbstractVector{UInt8}, msg_type::Int) = decode_msm(payload, msg_type)

# Convert MSM7 epoch encoding to second-of-day in the constellation's time scale.
# (PPPHVA only needs SOD consistency epoch-to-epoch, not absolute alignment.)
function _sod_from_epoch_ms(sys::Char, epoch_ms::Float64)
    if sys == 'G' || sys == 'E'
        # GPS/Galileo TOW in ms (mod 1 week handled upstream)
        return mod(epoch_ms * 1e-3, 86400)
    elseif sys == 'R'
        # GLONASS: DF416 day-of-week (3 bits) followed by DF034 time-of-day
        # in ms (27 bits) in the UTC(SU)+3h scale. Only the time-of-day part
        # is wanted here; leaving the day bits in put the GLONASS SOD
        # 5 h 8 min off on weekdays (seen 2026-09-10).
        tod_ms = mod(epoch_ms, 2.0^27)
        return mod(tod_ms * 1e-3 - 3*3600, 86400)
    elseif sys == 'C'
        # BDS TOW in ms (BDT)
        return mod(epoch_ms * 1e-3, 86400)
    end
    return NaN
end
