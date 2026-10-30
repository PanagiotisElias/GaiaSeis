# Catch-up on queue length (plan item 4):  julia --project=. test/catchup_test.jl
using GaiaSeis, Test
const G = GaiaSeis

mk(sys, sod) = G.EvEpoch(sys, G.MsmEpoch(sys, 1, sod * 1000, sod, false, G.MsmObservation[], UInt64(0), UInt32(0), 1077))

@testset "limit from the per-epoch time" begin
    @test G._catchup_limit(NaN) == 25            # unknown: 40 ms assumed -> 1 s / 40 ms
    @test G._catchup_limit(37.0) == 27           # the old 37 ms solve: 27 epochs
    @test G._catchup_limit(3.0) == 300           # fast solver: capped at 300 (30 s at 10 Hz)
    @test G._catchup_limit(0.5) == 300
    @test G._catchup_limit(500.0) == 10          # very slow machine: still the floor of 10
    @test G._catchup_limit(-1.0) == 25           # nonsense -> default
end

@testset "shedding decision" begin
    @test !G._shed_backlog(10, 37.0)             # 1 s of data, affordable
    @test !G._shed_backlog(27, 37.0)
    @test G._shed_backlog(28, 37.0)              # beyond the budget: shed to the newest
    @test !G._shed_backlog(250, 3.0)             # a 25 s stall burst on the fast solver is solved in full
    @test G._shed_backlog(301, 3.0)
    @test G._shed_backlog(40, 400.0)             # slow machine sheds early: no backlog spiral
end

@testset "backlog size from a batch" begin
    p = G.NtripProfile()                         # GPS + others per defaults
    evs = Any[mk('G', 100.0), mk('E', 100.0), mk('G', 100.1), mk('E', 100.1), mk('G', 100.2),
              G.EvOther(1005)]
    @test G._backlog_epochs(evs, p) == 3         # largest per-constellation count
    q = G.NtripProfile(); q.enable_gps = false; q.enable_gal = false
    @test G._backlog_epochs(evs, q) == 0
    @test G._backlog_epochs(Any[], p) == 0
end

@testset "counters exist" begin
    st = G.NtripSession(G.NtripProfile()).stats
    @test st.epochs_caught_up == 0 && isnan(st.solve_ms_ema)
end
println("catchup_test: ok")
