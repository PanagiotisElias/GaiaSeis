# Headless 2-minute run of the full pipeline against the active TOML profile.
# Writes one final diagnostic dump to logs/headless_dump.txt.
# Use this to isolate the bridge from any Gtk freeze: if dXYZ shows up here
# but not in the GUI, the freeze is purely a GUI/event-loop issue.
using GaiaSeis
using Dates

const RUN_FOR_SECONDS = 120

active, profiles = load_profiles()
profile = profiles[active]
println("[$(Dates.now())] active profile: $(profile.name)")
println("  obs: $(profile.caster):$(profile.port)/$(profile.mountpoint)")
profile.use_ssr && println("  ssr: $(profile.ssr_caster):$(profile.ssr_port)/$(profile.ssr_mountpoint)")
profile.use_eph && println("  eph: $(profile.eph_caster):$(profile.eph_port)/$(profile.eph_mountpoint)")

session = NtripSession(profile)
start!(session)

deadline = time() + RUN_FOR_SECONDS
global last_report = 0.0
while time() < deadline && isrunning(session)
    if time() - last_report >= 5
        global last_report = time()
        st = session.stats
        println("[$(Dates.format(Dates.now(),"HH:MM:SS"))] ",
                "conn=", st.connected,
                "  bytes=", st.bytes_received,
                "  frames=", st.frames_total,
                "  sod=", round(st.last_epoch_sod, digits=2),
                "  nsat=", st.last_epoch_nsat,
                "  pos✓=", st.have_rec_pos,
                "  eph=", st.n_eph,
                "  ssr=", st.n_ssr_orb, "/", st.n_ssr_clk,
                "  σ̂=", st.last_residual_m,
                "  dXYZ=", st.last_position_dxyz)
    end
    sleep(1.0)
end

println("\n[$(Dates.now())] stopping...")
final = GaiaSeis.diagnostic_dump(session)
stop!(session)

out = joinpath(@__DIR__, "..", "logs", "headless_dump.txt")
mkpath(dirname(out))
open(out, "w") do io; write(io, final); end
println("Final dump written to: ", out)
println("\n=== Final dump (last 60 lines) ===")
for line in last(split(final, "\n"), 60); println(line); end
