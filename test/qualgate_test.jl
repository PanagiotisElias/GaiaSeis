# Quality gate and amplitude flag (bridge side): pure/state checks.
#   julia --project=. test/qualgate_test.jl
using GaiaSeis, Test, Random
const G = GaiaSeis
Random.seed!(5)

p = G.NtripProfile()
mkdg(n; res = 1e-3 .* randn(n), prn = nothing) =
    (prn = prn === nothing ? [1:10; 40:45; 70:77; 100:105][1:n] : prn, res = res, w = ones(n), vk = zeros(n), removed = Int[])
cur0 = (0.001, -0.002, 0.003)

@testset "defaults" begin
    @test p.max_velocity_mps == 5.0 && p.min_sats_used == 8 && p.min_constellations == 2
    @test p.max_pdop == 5.0 && p.max_fit_rms_m == 0.1
    @test p.outlier_mad_threshold == 8.0 && p.outlier_window == 200
end

@testset "check" begin
    @test G._qualgate_check(mkdg(30), cur0, p, 0.1, 4, 1.8)[1] === :ok
    @test G._qualgate_check(mkdg(6, prn = [1, 2, 3, 40, 41, 70]), cur0, p, 0.1, 4, 1.8)[1] === :sats
    @test G._qualgate_check(mkdg(10, prn = collect(1:10)), cur0, p, 0.1, 4, 1.8)[1] === :consts   # GPS only, 4 enabled
    @test G._qualgate_check(mkdg(10, prn = collect(1:10)), cur0, p, 0.1, 1, 1.8)[1] === :ok       # GPS-only profile
    @test G._qualgate_check(mkdg(30), cur0, p, 0.1, 4, 7.2)[1] === :pdop
    @test G._qualgate_check(mkdg(30), cur0, p, 0.1, 4, NaN)[1] === :ok                              # unknown PDOP does not blank
    @test G._qualgate_check(mkdg(30, res = fill(0.3, 30)), cur0, p, 0.1, 4, 1.8)[1] === :fit
    @test G._qualgate_check(mkdg(30), (0.6, 0.0, 0.0), p, 0.1, 4, 1.8)[1] === :step                 # 0.6 m > 0.5 m at 10 Hz
    @test G._qualgate_check(mkdg(30), (0.6, 0.0, 0.0), p, 1.0, 4, 1.8)[1] === :ok                   # 1 Hz: limit 5 m
    # a 6 cm/s-class excursion (60 mm per epoch) and a 1 m/s one (100 mm) pass: real motion
    @test G._qualgate_check(mkdg(30), (0.1, 0.0, 0.0), p, 0.1, 4, 1.8)[1] === :ok
    # switching a check off
    q = G.NtripProfile(); q.max_velocity_mps = 0.0; q.min_sats_used = 0
    @test G._qualgate_check(mkdg(30), (9.0, 0.0, 0.0), q, 0.1, 4, 1.8)[1] === :ok
end

# Minimal bridge state for the stateful paths.
bs = G._empty_bridge(p)
@testset "gate blanks and counts" begin
    bs.last_xs = [0.7, 0.0, 0.0, 0.0]
    @test G._quality_gate!(bs, p, mkdg(30), 0.1)
    @test all(isnan, bs.last_xs) && bs.qgate.total == 1 && bs.qgate.by[:step] == 1
    bs.last_xs = [0.001, 0.0, 0.0, 0.0]
    @test !G._quality_gate!(bs, p, mkdg(30), 0.1) && bs.qgate.total == 1
    bs.last_xs = fill(NaN, 4)
    @test !G._quality_gate!(bs, p, mkdg(30), 0.1)               # nothing to gate
end

@testset "amplitude flag keeps the epoch" begin
    st = G._empty_bridge(p)
    for i in 1:60                      # quiet history
        st.last_xs = [1e-3 * randn(), 1e-3 * randn(), 2e-3 * randn(), 0.0]
        G._outlier_guard!(st, p)
    end
    n0 = st.outlier_total
    st.last_xs = [0.08, 0.0, 0.0, 0.0] # 80 mm: far outside 8 x MAD
    G._outlier_guard!(st, p)
    @test st.outlier_total == n0 + 1
    @test st.last_xs[1] == 0.08        # kept, not blanked
    # a sustained excursion: every epoch is kept; once it fills more than half the
    # 200-epoch window the median follows it and the flags stop (no reset latch)
    flags = Int[]
    for i in 1:260
        st.last_xs = [0.08 + 1e-3 * randn(), 0.0, 0.0, 0.0]
        before = st.outlier_total
        G._outlier_guard!(st, p)
        push!(flags, st.outlier_total - before)
        @test !isnan(st.last_xs[1])
    end
    @test sum(flags[end-9:end]) == 0   # the history has adapted: no latch, no endless flags
end
println("qualgate_test: ok")
