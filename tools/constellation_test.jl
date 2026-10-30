# Constellation experiment: run the UPA10Z profile headless with different
# constellation sets, one after the other, and leave one per-epoch log and
# one metrics CSV per configuration for tools/constellation_report.py.
#
#   CT_MINUTES=8 CT_ROUNDS=2 julia -t auto --project=. tools/constellation_test.jl
#
# Runs beside the GUI: one extra session at a time is what the igs-ip.net
# login limit allows (SSR + ephemeris mounts, same user). The miniSEED,
# CSV and DataLink sinks are disabled for the test profiles so nothing
# reaches the archive or the SeedLink feed. Logs land in
# logs/UPA10Z_X<tag>_<stamp>.txt and logs/UPA10Z_X<tag>_metrics_<stamp>.csv.
using GaiaSeis, Dates
const G = GaiaSeis

mins   = parse(Float64, get(ENV, "CT_MINUTES", "8"))
rounds = parse(Int, get(ENV, "CT_ROUNDS", "2"))
configs = [("GPS",        (true,  false, false, false)),
           ("GPS+GLO",    (true,  true,  false, false)),
           ("GPS+GAL",    (true,  false, true,  false)),
           ("GPS+BDS",    (true,  false, false, true )),
           ("GPS+GAL+BDS",(true,  false, true,  true )),
           ("ALL",        (true,  true,  true,  true ))]

active, profiles = G.load_profiles()
base = profiles["UPA10Z"]
println("constellation test: $(rounds) round(s) × $(length(configs)) configs × $(mins) min, started $(now())")
flush(stdout)

for r in 1:rounds
    order = isodd(r) ? configs : reverse(configs)   # alternate to spread the diurnal drift
    for (tag, (gps, glo, gal, bds)) in order
        p = deepcopy(base)
        p.name = "UPA10Z_X" * replace(tag, "+" => "")
        p.enable_gps = gps; p.enable_glo = glo; p.enable_gal = gal; p.enable_bds = bds
        p.miniseed_mseed_dir = ""; p.miniseed_csv_path = ""; p.datalink_host = ""
        p.output_filename = ""                      # -> logs/<name>_<stamp>.txt
        s = G.NtripSession(p)
        t0 = now()
        println("[$(Dates.format(t0, "HH:MM:SS"))] round $r  $tag  start"); flush(stdout)
        try
            G.start!(s)
            sleep(mins * 60)
        catch err
            println("  error: ", sprint(showerror, err))
        finally
            try; G.stop!(s); catch; end
        end
        st = s.stats
        nout = s.bridge_state === nothing ? 0 : s.bridge_state.outlier_total
        println("[$(Dates.format(now(), "HH:MM:SS"))] round $r  $tag  stop  epochs=$(st.input_epochs) missing=$(st.input_missing) " *
                "skipped=$(st.epochs_skipped_backpressure) outliers=$(nout) nsat_last=$(st.last_epoch_nsat) reconnects=$(st.reconnects_obs)")
        flush(stdout)
        sleep(15)                                   # let the caster logins clear
    end
end
println("constellation test finished $(now())")
