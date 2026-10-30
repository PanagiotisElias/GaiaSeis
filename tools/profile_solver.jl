# Profile the per-epoch solve of a live headless session (beside the GUI,
# one extra session is allowed by the SSR caster's login limit).
#   PS_WARMUP=90 PS_SECONDS=60 julia -t auto --project=. tools/profile_solver.jl
# Prints: epochs solved, solve-time percentiles, allocation per epoch, GC
# share, and the flat profile of the hottest functions (Julia frames only).
using GaiaSeis, Dates, Profile, Statistics
const G = GaiaSeis
warm = parse(Float64, get(ENV, "PS_WARMUP", "90"))
secs = parse(Float64, get(ENV, "PS_SECONDS", "60"))
active, profiles = G.load_profiles()
p = deepcopy(profiles["UPA10Z"])
p.name = "UPA10Z_PROF"; p.miniseed_mseed_dir = ""; p.miniseed_csv_path = ""; p.datalink_host = ""; p.output_filename = ""
s = G.NtripSession(p); G.start!(s)
println("warm-up $(warm) s …"); flush(stdout); sleep(warm)
st = s.stats
e0 = st.input_epochs; t0 = time()
gc0 = Base.gc_num(); bytes0 = gc0.allocd + gc0.deferred_alloc
Profile.init(n = 10^7, delay = 0.001)
Profile.clear()
Profile.@profile sleep(secs)
gc1 = Base.gc_num(); n = st.input_epochs - e0
println("\nepochs in $(secs) s: $n  (", round(n / secs, digits = 1), " Hz)")
alloc = (gc1.allocd + gc1.deferred_alloc) - bytes0
println("allocated: ", round(alloc / 1e6, digits = 1), " MB  = ", round(alloc / max(n, 1) / 1e3, digits = 1), " kB per epoch;  GC time ",
        round((gc1.total_time - gc0.total_time) / 1e9, digits = 2), " s (", round(100 * (gc1.total_time - gc0.total_time) / 1e9 / secs, digits = 1), " %)")
# solve-time percentiles from the metrics history (last n entries)
h = st.metrics_history
if !isempty(h)
    sv = [x.solve_ms for x in h[max(1, end - n + 1):end] if hasproperty(x, :solve_ms)]
    isempty(sv) || println("solve ms p50/p90/p99 = ", round(quantile(sv, .5), digits = 1), " / ", round(quantile(sv, .9), digits = 1), " / ", round(quantile(sv, .99), digits = 1))
end
println("\n=== flat profile, Julia frames, by self count ===")
Profile.print(format = :flat, sortedby = :count, C = false, noisefloor = 2, mincount = 50, maxdepth = 0)
println("\n=== tree, PPPHVA / bridge only ===")
Profile.print(format = :tree, C = false, noisefloor = 2, mincount = 100, maxdepth = 14, recur = :flat)
G.stop!(s)
