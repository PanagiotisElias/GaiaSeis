# Headless / CLI example: load a profile from the TOML file, start streaming,
# print status every 2 s, stop on Ctrl-C.
using GaiaSeis

profiles_file = joinpath(@__DIR__, "..", "config", "ntrip_profiles.toml")
active, profiles = load_profiles(profiles_file)
profile = profiles[active]
println("Using profile: ", profile.name,
        "  → ", profile.caster, ":", profile.port, "/", profile.mountpoint)

session = NtripSession(profile)
start!(session)

try
    while isrunning(session)
        st = session.stats
        println("[", Dates.format(Dates.now(), "HH:MM:SS"), "] ",
                "bytes=", st.bytes_received,
                "  frames=", st.frames_total,
                "  badCRC=", st.frames_crc_failed,
                "  lastMT=", st.last_msg_type,
                "  sod=", round(st.last_epoch_sod, digits=2),
                "  nsat=", st.last_epoch_nsat,
                "  σ=", round(st.last_residual_m, digits=4))
        sleep(2)
    end
catch InterruptException
finally
    stop!(session)
    println("Stopped.")
end
