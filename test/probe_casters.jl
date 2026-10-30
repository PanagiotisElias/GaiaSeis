# Pull the source-table from each registered caster so we know which mount
# points exist. Authentication isn't required for the source-table on the
# major casters; using the credentials anyway is harmless.
using GaiaSeis
using GaiaSeis: fetch_source_table, parse_source_table

active, profiles = load_profiles()
for name in ("EUREF_IP", "IGS_IP", "IGS_PRODUCTS")
    p = profiles[name]
    println("\n=== ", name, " — ", p.caster, ":", p.port, " ===")
    try
        body = fetch_source_table(p)
        rows = parse_source_table(body)
        println("got ", length(rows), " mountpoints; first 8:")
        for r in rows[1:min(end, 8)]
            print("  - ", rpad(r.mountpoint, 14), " ", rpad(r.identifier, 24))
            println("  ", r.format, "  ", r.country)
        end
    catch err
        println("  FAILED: ", sprint(showerror, err))
    end
end
