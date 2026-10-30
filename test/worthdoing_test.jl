# Per-stream message counts, PDOP of the used satellites, pruning of archived session logs:
#   julia --project=. test/worthdoing_test.jl
using GaiaSeis, Test
const G = GaiaSeis

@testset "per-stream message counts" begin
    dec = G.RtcmDecoder()
    @test isempty(dec.msg_counts_by)
    # a CRC-valid frame of an unknown type (1005-like payload of zeros) fed as the :obs and :eph streams
    function frame(mt)
        payload = UInt8[(mt >> 4) & 0xff, (mt & 0xf) << 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        hdr = UInt8[0xd3, 0x00, length(payload)]
        body = vcat(hdr, payload); c = G.crc24q(body)
        vcat(body, UInt8[(c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff])
    end
    G.feed_bytes!(dec, frame(4091); stream = :obs); G.feed_bytes!(dec, frame(4091); stream = :obs)
    G.feed_bytes!(dec, frame(1019 + 100); stream = :eph)
    @test dec.msg_counts_by[:obs][4091] == 2 && dec.msg_counts_by[:eph][1119] == 1
    @test !haskey(get(dec.msg_counts_by, :ssr, Dict{Int,Int}()), 4091)
    @test dec.msg_counts[4091] == 2 && sum(values(dec.msg_counts)) == 3
end

@testset "PDOP restricted to the used satellites" begin
    st = G._empty_bridge(G.NtripProfile())
    loc = G.PPPHVA.PStruct()
    gps = fill(NaN, 32, 2)
    # a well spread constellation: 8 satellites around the sky
    for (k, (az, el)) in enumerate(zip(0:45:315, (30, 60, 30, 60, 30, 60, 30, 60))); gps[k, 1] = az; gps[k, 2] = el; end
    loc.gps = gps; loc.glo = fill(NaN, 26, 2); loc.gal = fill(NaN, 36, 2); loc.bds = fill(NaN, 61, 2)
    st.data = G.PPPHVA.PStruct(); st.data.loc = loc
    all_n, _, p_all, _, _ = G._compute_dop(st)
    @test all_n == 8 && 1.0 < p_all < 4.0
    # the fit used only four satellites clustered in one quadrant: a much worse PDOP
    _, _, p_used, _, _ = G._compute_dop(st; used = Set([1, 2, 3, 4]))
    @test p_used > p_all
    n_none = G._compute_dop(st; used = Set(Int[]))[1]
    @test n_none == 0
    @test G._compute_dop(st; used = Set([1, 2, 3, 4, 5, 6, 7, 8]))[3] ≈ p_all
end

@testset "old session logs are pruned to the newest N" begin
    d = mktempdir(); root = joinpath(d, "GaiaSeis-UPC10Z")
    for st in ("20261001_100000", "20261002_100000", "20261003_100000", "20261004_100000", "20261005_100000")
        write(string(root, "_", st, ".log"), "x")
    end
    write(joinpath(d, "GaiaSeis-UPA10Z_20261001_100000.log"), "other profile")
    write(joinpath(d, "GaiaSeis-UPC10Z_notes.log"), "not an archive")
    write(joinpath(d, "GaiaSeis-UPC10Z.log"), "the live one")
    G._prune_session_logs(root, ".log", 3)
    left = sort(readdir(d))
    @test count(f -> occursin(r"UPC10Z_\d{8}_\d{6}\.log$", f), left) == 3
    @test "GaiaSeis-UPC10Z_20261005_100000.log" in left && "GaiaSeis-UPC10Z_20261001_100000.log" ∉ left
    @test "GaiaSeis-UPA10Z_20261001_100000.log" in left && "GaiaSeis-UPC10Z_notes.log" in left && "GaiaSeis-UPC10Z.log" in left
    # through the start-up helper: keep = 2
    write(joinpath(d, "GaiaSeis-UPC10Z.log"), "session N")
    arch = G._keep_previous_log(joinpath(d, "GaiaSeis-UPC10Z.log"), "GaiaSeis-UPC10Z.log"; keep = 2)
    @test arch !== nothing && count(f -> occursin(r"UPC10Z_\d{8}_\d{6}\.log$", f), readdir(d)) == 2
    @test G.NtripProfile().keep_session_logs == 20
end
println("worthdoing_test: ok")
