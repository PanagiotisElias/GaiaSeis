# Replays a raw relay capture (logs/rtcm_raw_<stamp>.bin from
# GaiaVario.jl/tools/compare_live.jl) through the GaiaSeis bridge with an
# engine plug-in selected in the profile, and compares the bridge's per-epoch
# log with a direct GaiaVario replay of the same bytes (CSV of
# replay_gaiavario.jl, variant with the same mode). Checks that the plug-in
# path solves the epochs and reproduces the engine's own solutions.
#
#   julia --project=. test/engine_plugin_replay.jl logs/rtcm_raw_<stamp>.bin [logs/variants/m_l1.csv] [minutes]

using GaiaSeis, Dates, Printf, Test
const G = GaiaSeis

raw = ARGS[1]
ref = length(ARGS) >= 2 ? ARGS[2] : ""
mins = length(ARGS) >= 3 ? parse(Float64, ARGS[3]) : 3.0

# ENGINE=ppphva|gaiavario, GV_MODE (plug-in observable), VA_MODE (PPPHVA DFV|SFV), OUT (keep the bridge log there)
p = G.NtripProfile(name = "PLUGIN_TEST", caster = "replay", mountpoint = "replay",
                   engine = get(ENV, "ENGINE", "gaiavario"), engine_mode = get(ENV, "GV_MODE", "single"),
                   engine_path = joinpath(@__DIR__, "..", "..", "GaiaVario.jl"),
                   process_mode = get(ENV, "VA_MODE", "DFV"), antex_file = joinpath(@__DIR__, "..", "STHCR3-G3.atx"),
                   elv_cutoff_deg = 10.0, enable_gps = true, enable_glo = true, enable_gal = true, enable_bds = true,
                   use_ssr = false, use_eph = false, miniseed_mseed_dir = "", miniseed_csv_path = "", datalink_host = "")
sess = G.NtripSession(p)
sess.stats = G.SessionStats(started_at = Dates.now())
sess.bridge_state = nothing
logpath = get(ENV, "OUT", tempname() * ".txt")
sess.log_file = open(logpath, "w")
dec = G.RtcmDecoder()

t_first = NaN; nva = 0; nerr = 0
open(raw) do io
    while !eof(io)
        tw = read(io, Float64); st = read(io, UInt8); n = read(io, UInt32); buf = read(io, n)
        isnan(t_first) && (global t_first = tw)
        tw - t_first > mins * 60 && break
        for ev in G.feed_bytes!(dec, buf; stream = st == 0 ? :obs : :eph)
            ev isa G.EvEpoch || continue
            ev.sys == G._primary_sys(p) && G._note_input_epoch!(sess.stats, ev.epoch.sod)
            try
                isnan(G.bridge_step!(sess, dec, ev.epoch; stale = false)) || (global nva += 1)
            catch err
                global nerr += 1
                nerr <= 3 && @warn "bridge step failed" err
            end
        end
    end
end
close(sess.log_file)
println("bridge with engine=$(p.engine): groups solved $nva, step errors $nerr, engine: ", sess.bridge_state.engine_info)

# bridge log -> dXYZ per SOD
bridge = Dict{Float64,NTuple{3,Float64}}()
for line in eachline(logpath)
    (startswith(line, "#") || isempty(strip(line))) && continue
    f = split(line)
    bridge[round(parse(Float64, f[1]); digits = 1)] = (parse(Float64, f[3]), parse(Float64, f[4]), parse(Float64, f[5]))
end
nfin = count(v -> all(isfinite, v), values(bridge))
@printf("bridge epochs logged %d, with a solution %d\n", length(bridge), nfin)

@testset "engine plug-in through the bridge" begin
    @test nerr == 0
    @test nfin > 0.9 * length(bridge)
    if !isempty(ref)
        # direct replay: NEU per SOD; convert the bridge's dXYZ to NEU with the station of the CSV
        station = nothing; direct = Dict{Float64,NTuple{3,Float64}}()
        for line in eachline(ref)
            if startswith(line, "# station ECEF"); station = Tuple(parse.(Float64, split(line)[4:6])); continue; end
            (startswith(line, "#") || startswith(line, "sod,")) && continue
            f = split(line, ',')
            direct[round(parse(Float64, f[1]); digits = 1)] = (parse(Float64, f[3]), parse(Float64, f[4]), parse(Float64, f[5]))
        end
        A = G._ecef2neu_matrix(station)
        common = [s for s in keys(bridge) if haskey(direct, s) && all(isfinite, bridge[s]) && all(isfinite, direct[s])]
        same = 0; maxd = 0.0
        for s in common
            d = bridge[s]; neu = (A[1,1]*d[1]+A[1,2]*d[2]+A[1,3]*d[3], A[2,1]*d[1]+A[2,2]*d[2]+A[2,3]*d[3], A[3,1]*d[1]+A[3,2]*d[2]+A[3,3]*d[3])
            dd = maximum(abs.(neu .- direct[s])); maxd = max(maxd, dd)
            dd < 1e-4 && (same += 1)
        end
        @printf("common epochs with the direct replay %d, identical (< 0.1 mm) %d (%.1f %%), largest difference %.2f mm\n",
                length(common), same, 100same / max(length(common), 1), 1000maxd)
        @test length(common) > 0.9 * nfin
        @test same > 0.95 * length(common)
    end
end
haskey(ENV, "OUT") || rm(logpath; force = true)
