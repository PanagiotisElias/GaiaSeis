# Satellite-level residual flagging (bridge side): pure-function checks.
#   julia --project=. test/satflag_test.jl
using GaiaSeis, Test, Random
const G = GaiaSeis
Random.seed!(11)

mkdg(res; w = ones(length(res)), prn = collect(1:length(res)), removed = Int[]) =
    (prn = prn, res = res, w = w, vk = zeros(length(res)), removed = removed)

@testset "labels" begin
    @test G._prn_label(5) == "G05"
    @test G._prn_label(33) == "R01"
    @test G._prn_label(58) == "R26"
    @test G._prn_label(59) == "E01"
    @test G._prn_label(72) == "E14"
    @test G._prn_label(95) == "C01"
    @test G._prn_label(111) == "C17"
end

@testset "evaluation" begin
    quiet = mkdg(1e-3 .* randn(20))
    prn, z, maxz, n = G._satflag_eval(quiet)
    @test isempty(prn) && n == 20 && maxz < 0.005 * G.SATFLAG_K

    r = 1e-3 .* randn(20); r[14] = 0.06                    # one bad satellite (E-range PRN 14)
    prn, z, maxz, n = G._satflag_eval(mkdg(r))
    @test prn == [14] && z[1] > 0.05 && maxz > 0.05

    # weight standardisation: a large raw residual on a low-weight satellite is damped
    w = ones(20); w[7] = 0.01
    r2 = 1e-3 .* randn(20); r2[7] = 0.04                   # 0.04*sqrt(0.01) = 4 mm < floor-based gate
    @test isempty(G._satflag_eval(mkdg(r2; w = w))[1])

    # a coherent shift of all satellites (what real ground motion would leave) is not flagged
    @test isempty(G._satflag_eval(mkdg(1e-3 .* randn(20) .+ 0.05))[1])

    # too few satellites: no evaluation
    @test isempty(G._satflag_eval(mkdg([0.0, 0.0, 0.5, 0.0]))[1])
    @test isempty(G._satflag_eval(mkdg(Float64[]))[1])
end

@testset "state and counters" begin
    sf = G.SatFlagState()
    r = 1e-3 .* randn(20); r[3] = 0.05; r[40 - 20] = -0.05  # G03 and index 20
    G._satflag_update!(sf, mkdg(r; prn = [1:19; 70], removed = [8]))
    @test sort(sf.prn) == [3, 70] && sf.epochs == 1 && sf.epochs_flagged == 1
    @test sf.sat_flags == 2 && sf.by_sys['G'] == 1 && sf.by_sys['E'] == 1 && sf.engine_removed == 1
    G._satflag_update!(sf, mkdg(1e-3 .* randn(20)))
    @test isempty(sf.prn) && sf.epochs == 2 && sf.epochs_flagged == 1 && sf.sat_flags == 2
    G._satflag_clear!(sf)
    @test isempty(sf.prn) && sf.nused == 0 && sf.epochs == 2   # counters survive a clear
    # fresh bridge state carries the flag state
    @test G._empty_bridge(G.NtripProfile()).satflag isa G.SatFlagState
end
println("satflag_test: ok")

@testset "cause kind and note" begin
    @test :satflag in G._CAUSE_KINDS && haskey(G._CAUSE_INFO, :satflag)
    sf = G.SatFlagState()
    r = 1e-3 .* randn(20); r[4] = 0.06; r[12] = -0.055
    G._satflag_update!(sf, mkdg(r; prn = [1:10; 70; 71; 72:79]))
    note = G._satflag_note(sf)
    @test occursin("G04 +", note) && occursin("E13 -", note)
    before = G._CAUSES.total[:satflag]
    G._cause_event!(:satflag, 1, note)
    @test G._CAUSES.total[:satflag] == before + 1
end
println("satflag_test (causes): ok")
