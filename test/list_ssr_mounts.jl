# Fetch the source-table on products.igs-ip.net and list mounts that
# advertise SSR messages (1057-1068 and Galileo equivalents) in their format.
using GaiaSeis
using GaiaSeis: fetch_source_table, parse_source_table

active, profiles = load_profiles()
p = profiles["IGS_PRODUCTS"]
body = fetch_source_table(p)

# Re-parse to keep full STR rows
lines = filter(l -> startswith(l, "STR;"), split(body, '\n'))
rows = [split(strip(l), ';') for l in lines if length(split(l, ';')) >= 12]

println("SSR-bearing mounts on products.igs-ip.net (showing format string):")
println("  ", rpad("mount", 16), rpad("identifier", 22), "format-details")
println("  ", "-"^80)
for r in rows
    fmt = r[5]
    if occursin(r"1057|1058|1059|1060|1063|1064|1065|1066|1240|1241|1242|1243|1244|1245"i, fmt)
        println("  ", rpad(r[2], 16), rpad(r[3], 22), fmt[1:min(end, 80)])
    end
end
