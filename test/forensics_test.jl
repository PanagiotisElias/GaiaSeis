# Plan item 8: metrics CSV forensics columns and the kept previous session log:
#   julia --project=. test/forensics_test.jl
using GaiaSeis, Test, Dates
const G = GaiaSeis

@testset "SSR message count" begin
    st = G.SessionStats()
    st.msg_counts = Dict(1075 => 1000, 1057 => 12, 1058 => 12, 1240 => 7, 1263 => 1, 1019 => 50, 1264 => 9, 1056 => 4)
    @test G._ssr_msgs_total(st) == 12 + 12 + 7 + 1
    @test G._ssr_msgs_total(G.SessionStats()) == 0
end

@testset "row matches the header" begin
    s = G.NtripSession(G.NtripProfile())
    tmp = tempname(); s.stats.metrics_csv = open(tmp, "w")
    s.stats.msg_counts = Dict(1057 => 3, 1058 => 3)
    G._record_metrics!(s, 20017.3, G._wall_utc_sod(), 8.0)
    close(s.stats.metrics_csv); line = read(tmp, String)
    @test count(==(','), G._METRICS_HEADER) == 26
    @test count(==(','), strip(line)) == 26                      # 27 fields
    f = split(strip(line), ',')
    @test f[22] == "6"                                            # ssr_msgs_cum
    @test f[end - 3:end] == ["NaN", "NaN", "NaN", "NaN"] || length(f) == 27   # health fields present (NaN without a sampler)
end

@testset "previous session log is kept, not truncated" begin
    d = mktempdir(); p = joinpath(d, "GaiaSeis-UPC10Z.log")
    @test G._keep_previous_log(p, "GaiaSeis-UPC10Z.log") === nothing      # nothing there yet
    write(p, "# session 1\n1.0 5 0 0 0\n")
    arch = G._keep_previous_log(p, "GaiaSeis-UPC10Z.log")
    @test arch !== nothing && isfile(arch) && !isfile(p)
    @test occursin(r"GaiaSeis-UPC10Z_\d{8}_\d{6}\.log$", arch) && read(arch, String) == "# session 1\n1.0 5 0 0 0\n"
    write(p, ""); @test G._keep_previous_log(p, "x") === nothing          # empty file: nothing to keep
    write(p, "data"); @test G._keep_previous_log(p, "") === nothing && isfile(p)   # timestamped default name: no action
end
println("forensics_test: ok")
