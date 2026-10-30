# Encode synthetic GPS MSM4/5/6/7 payloads by the RTCM 10403.3 layout and decode them:
#   julia --project=. test/msm_roundtrip_test.jl
# MSM4/MSM6 satellite data has no extended-info field; MSM5/MSM7 have it (and the rough rate).
using GaiaSeis, Test
const G = GaiaSeis

mutable struct BW; bits::Vector{Bool}; end
BW() = BW(Bool[])
function wu!(b::BW, v::Integer, n::Int); for i in n-1:-1:0; push!(b.bits, ((v >> i) & 1) == 1); end; end
ws!(b::BW, v::Integer, n::Int) = wu!(b, v < 0 ? v + (Int128(1) << n) : v, n)
function bytes(b::BW)
    bits = copy(b.bits); while length(bits) % 8 != 0; push!(bits, false); end
    UInt8[foldl((a, x) -> (a << 1) | UInt8(x), bits[i:i+7]; init = UInt8(0)) for i in 1:8:length(bits)]
end

# two GPS satellites (3, 7), two signals (mask bits 2 = 1C, 10 = 2W), all four cells present
function encode(mt::Int)
    last = mt % 10; ext = last in (5, 7); hi = last in (6, 7); rate = last in (5, 7)
    b = BW()
    wu!(b, mt, 12); wu!(b, 77, 12); wu!(b, 123456789, 30); wu!(b, 0, 1)
    wu!(b, 0, 3 + 7 + 2 + 2 + 1 + 3)
    sat = UInt64(0); for s in (3, 7); sat |= UInt64(1) << (64 - s); end
    sig = UInt32(0); for g in (2, 10); sig |= UInt32(1) << (32 - g); end
    wu!(b, sat, 64); wu!(b, sig, 32)
    for _ in 1:4; wu!(b, 1, 1); end                                   # cell mask: 2 sats x 2 signals
    for ms in (80, 82); wu!(b, ms, 8); end                             # rough range, integer ms
    ext && for _ in 1:2; wu!(b, 0, 4); end                             # extended satellite info
    for m in (256, 512); wu!(b, m, 10); end                            # rough range, mod 1 ms (1/1024)
    rate && for r in (-12, 30); ws!(b, r, 14); end                     # rough phase-range rate
    fpr = hi ? 20 : 15; fph = hi ? 24 : 22; lk = hi ? 10 : 4; cn = hi ? 10 : 6
    for v in (1234, -2345, 345, -456); ws!(b, v, fpr); end             # fine pseudorange
    for v in (5678, -6789, 789, -890); ws!(b, v, fph); end             # fine phase range
    for v in (3, 5, 7, 9); wu!(b, v, lk); end                          # lock indicator
    for v in (0, 1, 0, 1); wu!(b, v, 1); end                           # half-cycle
    for v in (45, 40, 35, 30); wu!(b, v, cn); end                      # CNR
    rate && for v in (100, -200, 300, -400); ws!(b, v, 15); end        # fine rate
    return bytes(b)
end

@testset "MSM$(mt % 10) ($mt) round trip" for mt in (1074, 1075, 1076, 1077)
    ep = G.decode_msm(encode(mt), mt)
    last = mt % 10; hi = last in (6, 7); rate = last in (5, 7)
    pr_lsb = hi ? 2.0^-29 : 2.0^-24; ph_lsb = hi ? 2.0^-31 : 2.0^-29; cn_lsb = hi ? 1/16 : 1.0
    @test length(ep.obs) == 4
    @test [o.prn for o in ep.obs] == [3, 3, 7, 7]
    @test [o.rinex_code for o in ep.obs] == ["1C", "2W", "1C", "2W"]
    coarse = [80 + 256/1024, 80 + 256/1024, 82 + 512/1024, 82 + 512/1024]
    fpr = [1234, -2345, 345, -456]; fph = [5678, -6789, 789, -890]
    for (k, o) in enumerate(ep.obs)
        @test o.pseudorange_m ≈ (coarse[k] + fpr[k] * pr_lsb) * G._LIGHT_MS atol = 1e-6
        @test o.carrier_m ≈ (coarse[k] + fph[k] * ph_lsb) * G._LIGHT_MS atol = 1e-6
        @test o.cnr_dbhz ≈ (45, 40, 35, 30)[k] * cn_lsb
        @test o.lock_indicator == (3, 5, 7, 9)[k]
        @test o.half_cycle_amb == (false, true, false, true)[k]
    end
    if rate
        @test ep.obs[1].doppler_mps ≈ -12 + 100 * 1e-4 && ep.obs[4].doppler_mps ≈ 30 - 400 * 1e-4
    else
        @test all(o -> isnan(o.doppler_mps), ep.obs)
    end
end
println("msm_roundtrip_test: ok")
