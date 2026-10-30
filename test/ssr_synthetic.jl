# Self-test for the SSR decode + bridge wiring using synthetic frames.
# No network required — encodes a 1057 (GPS orbit) and 1058 (GPS clock) frame
# by hand, feeds them through the RTCM decoder, and checks the resulting
# `data.ssr.orb.gps` / `data.ssr.clk.gps` columns are populated and that
# `options.RTC` flips to 1.
using GaiaSeis
using GaiaSeis: BitReader, readu, reads, crc24q, FrameBuffer, feed!,
                   RtcmDecoder, feed_bytes!, EvSsrOrbit, EvSsrClock,
                   decode_ssr_orbit, decode_ssr_clock,
                   _refresh_ssr!, _empty_bridge

# --- helpers to write packed bit fields ---
mutable struct BitWriter; bytes::Vector{UInt8}; pos::Int; end
BitWriter(n) = (BitWriter(zeros(UInt8, n), 1))

function writeu!(bw::BitWriter, value::Unsigned, n::Int)
    for i in 1:n
        bit = UInt8((value >> (n-i)) & 0x1)
        byte_idx = ((bw.pos - 1) >> 3) + 1
        bit_idx  = 7 - ((bw.pos - 1) & 0x7)
        bw.bytes[byte_idx] |= bit << bit_idx
        bw.pos += 1
    end
end
writes!(bw::BitWriter, value::Integer, n::Int) =
    writeu!(bw, reinterpret(UInt64, Int64(value)) & ((UInt64(1) << n) - UInt64(1)), n)

function build_frame(build_payload!::Function, msg_type::Int)
    bw = BitWriter(256)
    writeu!(bw, UInt64(msg_type), 12)
    build_payload!(bw)
    payload_bits = bw.pos - 1
    payload = bw.bytes[1 : ceil(Int, payload_bits / 8)]
    frame = UInt8[]
    push!(frame, 0xD3)
    push!(frame, UInt8((length(payload) >> 8) & 0x03))
    push!(frame, UInt8(length(payload) & 0xFF))
    append!(frame, payload)
    crc = crc24q(frame)
    push!(frame, UInt8((crc >> 16) & 0xFF))
    push!(frame, UInt8((crc >>  8) & 0xFF))
    push!(frame, UInt8(crc & 0xFF))
    return frame
end

# --- build a 1057 (GPS orbit, 1 satellite) ---
frame1057 = build_frame(1057) do bw
    writeu!(bw, UInt64(43200), 20)   # epoch 12:00 GPS TOW (s)
    writeu!(bw, UInt64(3), 4)        # update interval indicator
    writeu!(bw, UInt64(0), 1)        # multiple message bit
    writeu!(bw, UInt64(0), 1)        # sat. reference datum
    writeu!(bw, UInt64(1), 4)        # IOD-SSR
    writeu!(bw, UInt64(123), 16)     # provider ID
    writeu!(bw, UInt64(0), 4)        # solution ID
    writeu!(bw, UInt64(1), 6)        # 1 satellite
    writeu!(bw, UInt64(5), 6)        # PRN G05
    writeu!(bw, UInt64(42), 8)       # IODE
    writes!(bw, Int64( 10000), 22)   # radial =  1.0 m
    writes!(bw, Int64( -5000), 20)   # along  = -2.0 m
    writes!(bw, Int64(  2500), 20)   # cross  =  1.0 m
    writes!(bw, Int64(   100), 21)   # radial rate = 0.0001 m/s
    writes!(bw, Int64(   -50), 19)   # along rate  = -0.0002 m/s
    writes!(bw, Int64(    25), 19)   # cross rate  = 0.0001 m/s
end

# --- build a 1058 (GPS clock, same 1 satellite) ---
# Note: clock messages do NOT carry the "satellite reference datum" bit that
# orbit messages have, so the header is one bit shorter.
frame1058 = build_frame(1058) do bw
    writeu!(bw, UInt64(43200), 20)   # epoch
    writeu!(bw, UInt64(3), 4)        # update interval indicator
    writeu!(bw, UInt64(0), 1)        # multiple message bit
    writeu!(bw, UInt64(1), 4)        # IOD-SSR
    writeu!(bw, UInt64(123), 16)     # provider ID
    writeu!(bw, UInt64(0), 4)        # solution ID
    writeu!(bw, UInt64(1), 6)        # 1 satellite
    writeu!(bw, UInt64(5), 6)        # PRN G05
    writes!(bw, Int64(20000), 22)    # c0 =  2.0 m
    writes!(bw, Int64( 1000), 21)    # c1 =  0.001 m/s
    writes!(bw, Int64(    0), 27)    # c2 = 0
end

dec = RtcmDecoder()
events1 = feed_bytes!(dec, frame1057)
events2 = feed_bytes!(dec, frame1058)

@assert any(e -> e isa EvSsrOrbit, events1) "1057 should produce EvSsrOrbit"
@assert any(e -> e isa EvSsrClock, events2) "1058 should produce EvSsrClock"
@assert haskey(dec.ssr_orb, ('G', 5))
@assert haskey(dec.ssr_clk, ('G', 5))

orb = dec.ssr_orb[('G', 5)]; clk = dec.ssr_clk[('G', 5)]
println("decoded SSR orbit  G05: dR=$(orb.delta_radial)m  dA=$(orb.delta_along)m  dC=$(orb.delta_cross)m  IODE=$(orb.iode)")
println("decoded SSR clock  G05: c0=$(clk.c0)m  c1=$(clk.c1)m/s")
@assert isapprox(orb.delta_radial,  1.0; atol=1e-3)
@assert isapprox(orb.delta_along,  -2.0; atol=1e-3)
@assert isapprox(orb.delta_cross,   1.0; atol=1e-3)
@assert isapprox(clk.c0, 2.0; atol=1e-3)

# Bridge: feed _refresh_ssr! with a fake state and ensure options.RTC flips to 1
prof = NtripProfile(name="test", process_mode="DFV")
state = _empty_bridge(prof)
@assert state.options.RTC == 0
state.data = GaiaSeis.PPPHVA.PStruct()
_refresh_ssr!(state, dec, mod(orb.epoch_s, 86400.0))   # sod = the SSR epoch (needs the 3-arg form since 2026-09-10)
@assert state.options.RTC == 1
@assert GaiaSeis.PPPHVA.hasfield_p(state.data, :ssr)
@assert state.data.ssr.iop == 1
@assert isapprox(state.data.ssr.orb.gps[5, 3],  1.0; atol=1e-3)
@assert isapprox(state.data.ssr.clk.gps[5, 3],  2.0; atol=1e-3)
println("bridge: options.RTC flipped to $(state.options.RTC); ssr.iop=$(state.data.ssr.iop)")
println("\nAll SSR pipeline checks passed.")
