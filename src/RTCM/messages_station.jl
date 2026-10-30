# RTCM 1005/1006/1007/1008 — station (caster) reference information.
# Only the ARP ECEF coordinates and station ID are needed by PPPHVA.

struct StationCoord
    station_id::Int
    x::Float64
    y::Float64
    z::Float64
    height_m::Float64   # NaN for 1005, antenna height for 1006
end

function decode_1005_1006(payload::AbstractVector{UInt8}, msg_type::Int)
    br = BitReader(payload)
    skipbits!(br, 12)                       # message number (already known)
    station_id = Int(readu(br, 12))
    skipbits!(br, 6)                        # ITRF realization year
    skipbits!(br, 1 + 1 + 1)                # GPS/GLO/Galileo ind. (we ignore)
    skipbits!(br, 1)                        # reference-station ind.
    x_int = reads(br, 38)
    skipbits!(br, 1)                        # single-receiver osc. ind.
    skipbits!(br, 1)                        # reserved
    y_int = reads(br, 38)
    skipbits!(br, 2)                        # quarter-cycle / reserved
    z_int = reads(br, 38)
    height = NaN
    if msg_type == 1006
        # 16-bit antenna height in 0.1 mm
        h = readu(br, 16)
        height = Float64(h) * 1e-4
    end
    return StationCoord(station_id,
                        Float64(x_int) * 1e-4,
                        Float64(y_int) * 1e-4,
                        Float64(z_int) * 1e-4,
                        height)
end

# Receiver / antenna descriptor (RTCM 10403.3 §3.5.6) — message types 1033 and
# 1008.  We extract the antenna descriptor string so the bridge can plug it
# into `inf.ant.type`; PPPHVA's `readatx` then finds the matching ANTEX entry.

struct StationDescriptor
    station_id::Int
    antenna_descriptor::String
    antenna_serial::String
    receiver_type::String
    receiver_firmware::String
    receiver_serial::String
end

# Helper — read `n` characters from the bit stream (each char is 8 bits ASCII).
function _read_chars!(br::BitReader, n::Int)
    n <= 0 && return ""
    buf = Vector{UInt8}(undef, n)
    for i in 1:n
        buf[i] = UInt8(readu(br, 8))
    end
    return strip(String(buf))
end

function decode_1033(payload::AbstractVector{UInt8})
    br = BitReader(payload)
    skipbits!(br, 12)                       # message number
    station_id = Int(readu(br, 12))
    n_ant = Int(readu(br, 8))
    ant_desc = _read_chars!(br, n_ant)
    skipbits!(br, 8)                        # antenna setup ID
    n_ser = Int(readu(br, 8))
    ant_ser = _read_chars!(br, n_ser)
    n_rec = Int(readu(br, 8))
    rec_type = _read_chars!(br, n_rec)
    n_fw = Int(readu(br, 8))
    rec_fw = _read_chars!(br, n_fw)
    n_recser = Int(readu(br, 8))
    rec_ser = _read_chars!(br, n_recser)
    return StationDescriptor(station_id, ant_desc, ant_ser,
                              rec_type, rec_fw, rec_ser)
end

# Receiver / antenna descriptor short form (RTCM 1008) — also carries antenna.
function decode_1008(payload::AbstractVector{UInt8})
    br = BitReader(payload)
    skipbits!(br, 12)
    station_id = Int(readu(br, 12))
    n_ant = Int(readu(br, 8))
    ant_desc = _read_chars!(br, n_ant)
    skipbits!(br, 8)                        # antenna setup ID
    n_ser = Int(readu(br, 8))
    ant_ser = _read_chars!(br, n_ser)
    return StationDescriptor(station_id, ant_desc, ant_ser, "", "", "")
end
