using GaiaSeis
using GaiaSeis: BitReader, readu, reads, readbool, skipbits!, bits_remaining,
                   crc24q, FrameBuffer, feed!, RtcmFrame,
                   RtcmDecoder, feed_bytes!, EvStation, EvEpoch, EvEphemeris,
                   decode_1005_1006, StationCoord,
                   default_profiles_path, load_profiles, save_profiles, NtripProfile

println("== CRC-24Q ==")
# Known vector: empty message + valid CRC roundtrips.
@assert crc24q(UInt8[]) == 0
println("crc24q(empty) = 0  ✔")

println("== BitReader ==")
let
    # 0b 1010 0101 0011 1100 = 0xA53C
    br = BitReader([0xA5, 0x3C])
    @assert readu(br, 4) == 0xA
    @assert readu(br, 4) == 0x5
    @assert readu(br, 8) == 0x3C
    @assert bits_remaining(br) == 0
end
let
    # signed: 0b 1111_1110 -> -2 in 8-bit two's complement
    br = BitReader([0xFE])
    @assert reads(br, 8) == -2
end
println("BitReader read paths  ✔")

println("== Profile TOML round-trip ==")
let
    tmp = tempname() * ".toml"
    profiles = Dict("p1" => NtripProfile(name="p1", caster="example.com", port=2110,
                                          mountpoint="X1", user="u", password="p"),
                    "p2" => NtripProfile(name="p2", caster="other.com"))
    save_profiles("p1", profiles, tmp)
    active, loaded = load_profiles(tmp)
    @assert active == "p1"
    @assert haskey(loaded, "p1") && haskey(loaded, "p2")
    @assert loaded["p1"].caster == "example.com"
    @assert loaded["p1"].port   == 2110
    @assert loaded["p2"].caster == "other.com"
    rm(tmp; force = true)
end
println("TOML round-trip  ✔")

println("== Frame parsing (synthetic 1005 message) ==")
let
    # Build a 1005 payload by hand: message number 1005 + station id 7 + zeros.
    # 1005 is 19 bytes of payload (152 bits).
    payload = zeros(UInt8, 19)
    # Bits 0..11   : 1005   (0x3ED)
    # Bits 12..23  : 7      (station id)
    # We'll just write a payload with msg type 1005, station id 7, and ECEF
    # coordinates X=10 m, Y=20 m, Z=30 m (stored as 38-bit signed int in 0.1mm).
    function _writebits!(buf, bitpos, value::Unsigned, n::Int)
        for i in 1:n
            byte_idx = ((bitpos - 1) >> 3) + 1
            bit_idx  = 7 - ((bitpos - 1) & 0x7)
            b = UInt8((value >> (n - i)) & 0x1)
            buf[byte_idx] |= b << bit_idx
            bitpos += 1
        end
        return bitpos
    end
    function _writes!(buf, bitpos, value::Integer, n::Int)
        mask = (UInt64(1) << n) - 1
        return _writebits!(buf, bitpos, UInt64(value) & mask, n)
    end
    pos = 1
    pos = _writebits!(payload, pos, UInt64(1005), 12)        # message #
    pos = _writebits!(payload, pos, UInt64(7),    12)        # station id
    pos = _writebits!(payload, pos, UInt64(0),    6)         # ITRF year
    pos = _writebits!(payload, pos, UInt64(0),    3)         # G/R/E ind
    pos = _writebits!(payload, pos, UInt64(0),    1)         # ref-station ind
    pos = _writes!(payload, pos, Int64(10 * 10_000),  38)    # X in 0.1 mm
    pos = _writebits!(payload, pos, UInt64(0),    2)         # osc + reserved
    pos = _writes!(payload, pos, Int64(20 * 10_000),  38)    # Y
    pos = _writebits!(payload, pos, UInt64(0),    2)         # qcycle/reserved
    pos = _writes!(payload, pos, Int64(30 * 10_000),  38)    # Z
    # Pad rest with zeros (payload is 19 bytes = 152 bits; we used 12+12+6+3+1+38+2+38+2+38 = 152 — perfect)

    # Wrap in an RTCM frame: 0xD3 + length(2B big-endian, lo 10 bits) + payload + CRC
    frame = UInt8[]
    push!(frame, 0xD3)
    msg_len = length(payload)
    push!(frame, UInt8((msg_len >> 8) & 0x03))
    push!(frame, UInt8(msg_len & 0xFF))
    append!(frame, payload)
    crc = crc24q(frame)
    push!(frame, UInt8((crc >> 16) & 0xFF))
    push!(frame, UInt8((crc >>  8) & 0xFF))
    push!(frame, UInt8(crc & 0xFF))

    fb = FrameBuffer()
    frames = feed!(fb, frame)
    @assert length(frames) == 1
    @assert frames[1].msg_type == 1005
    coord = decode_1005_1006(frames[1].payload, 1005)
    @assert coord.station_id == 7
    @assert isapprox(coord.x, 10.0; atol=1e-4)
    @assert isapprox(coord.y, 20.0; atol=1e-4)
    @assert isapprox(coord.z, 30.0; atol=1e-4)
    println("decoded 1005 station=$(coord.station_id) X=$(coord.x) Y=$(coord.y) Z=$(coord.z)  ✔")

    # Also exercise the higher-level decoder
    dec = RtcmDecoder()
    events = feed_bytes!(dec, frame)
    @assert any(e -> e isa EvStation, events)
    @assert dec.station !== nothing && dec.station.station_id == 7
    println("RtcmDecoder.feed_bytes! produced EvStation  ✔")
end

println("\nAll smoke checks passed.")
