# RTCM 3 SSR (State Space Representation) decoders.
#
# Supported messages:
#   1057  GPS Orbit Correction
#   1058  GPS Clock Correction
#   1063  GLONASS Orbit Correction
#   1064  GLONASS Clock Correction
#   1240  Galileo Orbit Correction
#   1241  Galileo Clock Correction
#
# Spec: RTCM 10403.3 §3.5.4 (SSR I — GPS/GLO) and §3.5.5 (SSR — Galileo).
# Each message wraps a header describing the epoch + provider + IOD-SSR, then
# a per-satellite block of orbit (8 fields) or clock (3 fields) corrections.
#
# Output: SsrOrbitCorrection / SsrClockCorrection — flat records that the
# bridge accumulates into PPPHVA's `readssra` layout.

struct SsrOrbitCorrection
    sys::Char           # 'G'/'R'/'E'
    prn::Int
    epoch_s::Float64    # SSR epoch in seconds-of-day of the constellation time
    update_interval::Int
    iod_ssr::Int
    iode::Int           # broadcast-eph index this correction refers to
    delta_radial::Float64       # m
    delta_along::Float64        # m
    delta_cross::Float64        # m
    delta_radial_rate::Float64  # m/s
    delta_along_rate::Float64   # m/s
    delta_cross_rate::Float64   # m/s
end

struct SsrClockCorrection
    sys::Char
    prn::Int
    epoch_s::Float64
    update_interval::Int
    iod_ssr::Int
    c0::Float64         # m (delta-clock at epoch)
    c1::Float64         # m/s
    c2::Float64         # m/s²
end

# Update intervals: indicator → seconds (RTCM table 3.5-86)
const _SSR_UPDATE_INTERVAL = (1, 2, 5, 10, 15, 30, 60, 120, 240, 300, 600,
                              900, 1800, 3600, 7200, 10800)

# Helpers — system-specific header sizes are slightly different between
# GPS (sat ID 6 bits, IODE 8 bits) and GLONASS (sat ID 5 bits, IODE 8 bits),
# Galileo (sat ID 6 bits, IODnav 10 bits). Header epoch widths also differ
# (20 bits for GPS/GAL TOW, 17 bits for GLONASS time-of-day).
function _read_ssr_header!(br, sys::Char, is_orbit::Bool)
    skipbits!(br, 12)                            # message number
    epoch_bits = sys == 'R' ? 17 : 20
    epoch_s = Float64(readu(br, epoch_bits))
    upd_ind = Int(readu(br, 4))
    mmf     = readbool(br)                       # multiple-message flag
    # DF375 "satellite reference datum" is present in orbit messages only.
    if is_orbit
        skipbits!(br, 1)
    end
    iod_ssr = Int(readu(br, 4))
    skipbits!(br, 16)                            # SSR provider ID
    skipbits!(br, 4)                             # SSR solution ID
    nsat = Int(readu(br, 6))
    return epoch_s, upd_ind, iod_ssr, nsat, mmf
end

_iode_bits(sys::Char) = sys == 'R' ? 8 : (sys == 'E' ? 10 : 8)
_prn_bits(sys::Char)  = sys == 'R' ? 5 : 6

# Per-satellite ephemeris reference in orbit messages: GPS IODE (8),
# GLONASS IOD (8), Galileo IODnav (10); BeiDou (1258) carries "toe modulo"
# (10) followed by IOD (8). Returns the IOD used for matching.
function _read_ssr_iode!(br, sys::Char)
    if sys == 'C'
        skipbits!(br, 10)                        # BDS toe modulo
        return Int(readu(br, 8))                 # BDS IOD
    end
    return Int(readu(br, _iode_bits(sys)))
end

"""
    decode_ssr_orbit(payload, msg_type) -> Vector{SsrOrbitCorrection}

Decode an SSR orbit-correction message (1057/1063/1240/1258).
"""
function decode_ssr_orbit(payload::AbstractVector{UInt8}, msg_type::Int)
    sys = if msg_type == 1057; 'G'
        elseif msg_type == 1063; 'R'
        elseif msg_type == 1240; 'E'
        elseif msg_type == 1258; 'C'
        else; error("Unsupported SSR orbit message $(msg_type)")
        end
    br = BitReader(payload)
    epoch_s, upd_ind, iod_ssr, nsat, _ = _read_ssr_header!(br, sys, true)
    interval = _SSR_UPDATE_INTERVAL[min(max(upd_ind+1, 1), length(_SSR_UPDATE_INTERVAL))]
    out = SsrOrbitCorrection[]
    sizehint!(out, nsat)
    for _ in 1:nsat
        prn  = Int(readu(br, _prn_bits(sys)))
        iode = _read_ssr_iode!(br, sys)
        # delta-radial / along / cross (signed, mm resolution)
        d_r  = reads(br, 22) * 1e-4   # 0.1 mm
        d_a  = reads(br, 20) * 4e-4   # 0.4 mm
        d_c  = reads(br, 20) * 4e-4
        # rate components
        dr_r = reads(br, 21) * 1e-6   # 0.001 mm/s
        da_r = reads(br, 19) * 4e-6
        dc_r = reads(br, 19) * 4e-6
        push!(out, SsrOrbitCorrection(sys, prn, epoch_s, interval, iod_ssr, iode,
                                      d_r, d_a, d_c, dr_r, da_r, dc_r))
    end
    # A correctly parsed message ends within the byte padding. The BeiDou
    # layout is the least battle-tested one, so refuse (the decoder logs it)
    # rather than store garbage corrections.
    sys == 'C' && bits_remaining(br) >= 8 &&
        error("SSR $(msg_type): $(bits_remaining(br)) bits unread after $(nsat) satellites — layout mismatch")
    return out
end

"""
    decode_ssr_clock(payload, msg_type) -> Vector{SsrClockCorrection}

Decode an SSR clock-correction message (1058/1064/1241/1259).
"""
function decode_ssr_clock(payload::AbstractVector{UInt8}, msg_type::Int)
    sys = if msg_type == 1058; 'G'
        elseif msg_type == 1064; 'R'
        elseif msg_type == 1241; 'E'
        elseif msg_type == 1259; 'C'
        else; error("Unsupported SSR clock message $(msg_type)")
        end
    br = BitReader(payload)
    epoch_s, upd_ind, iod_ssr, nsat, _ = _read_ssr_header!(br, sys, false)
    interval = _SSR_UPDATE_INTERVAL[min(max(upd_ind+1, 1), length(_SSR_UPDATE_INTERVAL))]
    out = SsrClockCorrection[]
    sizehint!(out, nsat)
    for _ in 1:nsat
        prn = Int(readu(br, _prn_bits(sys)))
        c0  = reads(br, 22) * 1e-4    # 0.1 mm
        c1  = reads(br, 21) * 1e-6    # 0.001 mm/s
        c2  = reads(br, 27) * 5e-8    # 0.00002 mm/s²
        push!(out, SsrClockCorrection(sys, prn, epoch_s, interval, iod_ssr, c0, c1, c2))
    end
    return out
end
