# Per-satellite SSR validity and fallback (bridge side):  julia --project=. test/ssr_validity_test.jl
using GaiaSeis, Test
const G = GaiaSeis

orb(sys, prn, ep) = G.SsrOrbitCorrection(sys, prn, ep, 5, 1, 7, 1.0, -2.0, 1.0, 0.0, 0.0, 0.0)
clk(sys, prn, ep) = G.SsrClockCorrection(sys, prn, ep, 5, 1, 2.0, 0.0, 0.0)
row(x) = (r = fill(NaN, 39); r[18] = 5153.7; r[19] = 3 * 86400.0; r[39] = 7200.0; r[8] = x; r)

function setup(; fallback = true, max_age = 60.0)
    p = G.NtripProfile(); p.use_ssr = true; p.ssr_fallback = fallback; p.ssr_max_age_s = max_age
    st = G._empty_bridge(p); st.data = G.PPPHVA.PStruct()
    dec = G.RtcmDecoder()
    for (sys, prn) in (('G', 3), ('G', 7), ('G', 11), ('E', 5), ('E', 6), ('R', 2))
        dec.eph[(sys, prn)] = G.EphemerisRecord(sys, prn, row(1e-5 * prn), true)
    end
    now = 40000.0
    dec.ssr_orb[('G', 3)] = orb('G', 3, now - 5);  dec.ssr_clk[('G', 3)] = clk('G', 3, now - 5)    # fresh
    dec.ssr_orb[('G', 7)] = orb('G', 7, now - 5);  dec.ssr_clk[('G', 7)] = clk('G', 7, now - 200)  # clock stale
    dec.ssr_orb[('G', 11)] = orb('G', 11, now - 5)                                                  # orbit only
    dec.ssr_orb[('E', 5)] = orb('E', 5, now - 300); dec.ssr_clk[('E', 5)] = clk('E', 5, now - 300)  # whole constellation stale
    dec.ssr_orb[('E', 6)] = orb('E', 6, now - 300); dec.ssr_clk[('E', 6)] = clk('E', 6, now - 300)
    return p, st, dec, now
end

@testset "defaults and options flag" begin
    p = G.NtripProfile()
    @test p.ssr_fallback && p.ssr_max_age_s == 60.0
    @test G._empty_bridge(p).options.ssr_fallback == 1
    q = G.NtripProfile(); q.ssr_fallback = false
    @test G._empty_bridge(q).options.ssr_fallback == 0 && G._empty_bridge(q).ssr_max_age == 0.0
end

@testset "validity with fallback" begin
    p, st, dec, now = setup()
    ch = G._refresh_ssr!(st, dec, now)
    @test ch === true
    @test st.ssr_valid == Set([('G', 3)])
    orbg = st.data.ssr.orb.gps; clkg = st.data.ssr.clk.gps
    @test all(isfinite, orbg[3, :]) && all(isfinite, clkg[3, :])      # fresh: kept
    @test all(isnan, orbg[7, :]) && all(isnan, clkg[7, :])             # one stale: both blanked
    @test all(isnan, orbg[11, :])                                      # orbit only: blanked
    @test all(isnan, st.data.ssr.orb.gal[5, :]) && all(isnan, st.data.ssr.orb.gal[6, :])
    @test st.ssr_cons['G'] == (1, 3) && st.ssr_cons['E'] == (0, 2) && st.ssr_cons['R'] == (0, 1)
    @test G._refresh_ssr!(st, dec, now) === false                      # unchanged validity: no rebuild needed
    @test G._refresh_ssr!(st, dec, now + 100.0) === true               # the fresh one ages out
    @test isempty(st.ssr_valid) && all(isnan, st.data.ssr.orb.gps[3, :])
    @test st.options.RTC == 1
end

@testset "old behaviour without fallback: no age check" begin
    p, st, dec, now = setup(fallback = false)
    G._refresh_ssr!(st, dec, now)
    @test ('G', 7) in st.ssr_valid && ('E', 5) in st.ssr_valid         # stale ones stay valid
    @test ('G', 11) ∉ st.ssr_valid                                     # incomplete ones are still dropped
end

@testset "status text" begin
    p, st, dec, now = setup()
    s = G.NtripSession(p); s.bridge_state = st
    @test G._ssr_mode(s) == "waiting"
    G._refresh_ssr!(st, dec, now)
    @test G._ssr_mode(s) == "partial" && G._ssr_sats(s) == "G 1/3 R 0/1 E 0/2 C 0/0"
    G._refresh_ssr!(st, dec, now + 100.0)
    @test G._ssr_mode(s) == "fallback"
    p.use_ssr = false
    @test G._ssr_mode(s) == "off"
end
println("ssr_validity_test: ok")
