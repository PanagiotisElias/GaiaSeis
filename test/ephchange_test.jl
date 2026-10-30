# Ephemeris-change detection used to keep both epochs of a variometric pair on
# the same broadcast record:  julia --project=. test/ephchange_test.jl
using GaiaSeis, Test
const G = GaiaSeis

p = G.NtripProfile()
state = G._empty_bridge(p)
dec = G.RtcmDecoder()
row(x) = (r = fill(NaN, 39); r[18] = 5153.7; r[19] = 3 * 86400.0; r[39] = 7200.0; r[8] = x; r)
dec.eph[('G', 5)]  = G.EphemerisRecord('G', 5, row(1e-5), true)
dec.eph[('E', 14)] = G.EphemerisRecord('E', 14, row(2e-5), true)

@testset "signature and change detection" begin
    s1 = G._refresh_nav!(state, dec, 100.0)
    @test s1 isa Dict && length(s1) == 2 && haskey(s1, ('G', 5))
    @test state.data.nav.gps[5, 18] == 5153.7
    @test isempty(G._nav_changed(Dict{Tuple{Char,Int},UInt}(), s1))     # first sight: no change
    s2 = G._refresh_nav!(state, dec, 100.1)                              # same records re-sent: identical
    @test isempty(G._nav_changed(s1, s2))
    dec.eph[('E', 14)] = G.EphemerisRecord('E', 14, row(2.5e-5), true)  # new issue for E14
    s3 = G._refresh_nav!(state, dec, 100.2)
    @test G._nav_changed(s2, s3) == ["E14"]
    dec.eph[('G', 9)] = G.EphemerisRecord('G', 9, row(3e-5), true)       # a satellite appearing is not a change
    s4 = G._refresh_nav!(state, dec, 100.3)
    @test isempty(G._nav_changed(s3, s4))
    dec.eph[('G', 5)] = G.EphemerisRecord('G', 5, row(1.1e-5), true)
    dec.eph[('E', 14)] = G.EphemerisRecord('E', 14, row(2.6e-5), true)
    @test G._nav_changed(s4, G._refresh_nav!(state, dec, 100.4)) == ["E14", "G05"]
end

@testset "state and cause kind" begin
    @test state.eph_changes == 0 && state.eph_rebuilds == 0 && isempty(state.nav_sig)
    @test :ephswitch in G._CAUSE_KINDS && haskey(G._CAUSE_INFO, :ephswitch)
end
println("ephchange_test: ok")
