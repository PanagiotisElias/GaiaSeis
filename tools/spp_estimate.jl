# Single-point (pseudorange) position of a profile's receiver, using GaiaSeis's
# own RTCM decoder on the obs mount and the profile's ephemeris mount. Prints
# the values to paste into the profile's gga_* fields (ellipsoidal height).
# Usage (from the package root, nothing else connected to the mount):
#   PROFILE=UPA10Z DUR=90 julia -t auto --project=. tools/spp_estimate.jl
using GaiaSeis, Statistics, Printf, LinearAlgebra
const G = GaiaSeis
const C = 299_792_458.0; const GM = 3.986005e14; const OMEGA_E = 7.2921151467e-5
const F1 = 1575.42e6; const F2 = 1227.60e6
prof_name = get(ENV, "PROFILE", "UPA10Z"); DUR = parse(Float64, get(ENV, "DUR", "90"))
_, profiles = G.load_profiles()
key = haskey(profiles, prof_name) ? prof_name : first(k for k in keys(profiles) if startswith(k, prof_name[1:3]))
prof = profiles[key]; println("profile ", key, "  obs ", prof.caster, ":", prof.port, "/", prof.mountpoint,
                              "  eph ", prof.eph_caster, "/", prof.eph_mountpoint)
dec_obs = G.RtcmDecoder(); dec_eph = G.RtcmDecoder()
epochs = G.MsmEpoch[]; lk = ReentrantLock(); stop = Threads.Atomic{Bool}(false)
t_obs = @async try G.run_stream!(prof, b -> begin
        for ev in G.feed_bytes!(dec_obs, b); ev isa G.EvEpoch && ev.sys == 'G' && lock(() -> push!(epochs, ev.epoch), lk); end end; stop_flag = stop)
    catch e; println("obs stream ended: ", e); end
t_eph = @async try G.run_stream!(G._eph_view(prof), b -> (G.feed_bytes!(dec_eph, b); nothing); stop_flag = stop)
    catch e; println("eph stream ended: ", e); end
t0 = time(); while time() - t0 < DUR; sleep(5); @printf("t=%3.0fs epochs=%d eph=%d\n", time()-t0, length(epochs), count(k -> k[1]=='G', keys(dec_eph.eph))); flush(stdout); end
stop[] = true; sleep(2)

# ---- broadcast orbit + clock (IS-GPS-200 Table 20-IV) ----
function satpos(row, t)              # t = GPS time of transmission (sow)
    toe = row[19]; A = row[18]^2; n0 = sqrt(GM / A^3); tk = t - toe
    tk > 302400 && (tk -= 604800); tk < -302400 && (tk += 604800)
    n = n0 + row[13]; M = row[14] + n * tk; E = M
    for _ in 1:10; E = M + row[16] * sin(E); end
    ν = atan(sqrt(1 - row[16]^2) * sin(E), cos(E) - row[16]); Φ = ν + row[25]
    du = row[17] * sin(2Φ) + row[15] * cos(2Φ); dr = row[12] * sin(2Φ) + row[24] * cos(2Φ); di = row[22] * sin(2Φ) + row[20] * cos(2Φ)
    u = Φ + du; r = A * (1 - row[16] * cos(E)) + dr; i = row[23] + di + row[27] * tk
    xo = r * cos(u); yo = r * sin(u); Ω = row[21] + (row[26] - OMEGA_E) * tk - OMEGA_E * toe
    x = xo * cos(Ω) - yo * cos(i) * sin(Ω); y = xo * sin(Ω) + yo * cos(i) * cos(Ω); z = yo * sin(i)
    dts = row[8] + row[9] * tk + row[10] * tk^2 - 2 * sqrt(GM) * row[16] * row[18] * sin(E) / C^2   # toc ≡ toe for LNAV
    return (x, y, z), dts
end
function ecef2plh(x, y, z)
    a = 6378137.0; e2 = 6.69437999014e-3; lon = atan(y, x); p = hypot(x, y); lat = atan(z, p * (1 - e2)); h = 0.0
    for _ in 1:8; N = a / sqrt(1 - e2 * sin(lat)^2); h = p / cos(lat) - N; lat = atan(z, p * (1 - e2 * N / (N + h))); end
    return rad2deg(lat), rad2deg(lon), h
end
function enu_el(rx, sat)
    lat, lon, _ = ecef2plh(rx...); φ = deg2rad(lat); λ = deg2rad(lon); d = sat .- rx
    e = -sin(λ)*d[1] + cos(λ)*d[2]; n = -sin(φ)cos(λ)*d[1] - sin(φ)sin(λ)*d[2] + cos(φ)*d[3]; u = cos(φ)cos(λ)*d[1] + cos(φ)sin(λ)*d[2] + sin(φ)*d[3]
    return atan(u, hypot(e, n))
end
tropo(h, el) = (h < 0 ? 2.3 : 2.3 * exp(-h / 7500)) / max(sin(el), 0.1) * (1 + 0.0026)   # crude zenith-dry × 1/sin(el)

seed = G._plh_to_ecef(prof.gga_lat_deg, prof.gga_lon_deg, prof.gga_height_m)
sols = NTuple{3,Float64}[]; nsat_used = Int[]
for ep in epochs
    trx = ep.epoch_ms * 1e-3
    # pick per-satellite pseudoranges: iono-free from 1C + (2W|2L|2X|2S), else 1C alone
    pr = Dict{Int,Float64}()
    for prn in unique(o.prn for o in ep.obs)
        obs = [o for o in ep.obs if o.prn == prn]
        p1 = findfirst(o -> o.rinex_code == "1C" && !isnan(o.pseudorange_m), obs); p1 === nothing && continue
        p2 = findfirst(o -> o.rinex_code in ("2W","2L","2X","2S") && !isnan(o.pseudorange_m), obs)
        P1 = obs[p1].pseudorange_m
        pr[prn] = p2 === nothing ? P1 : (F1^2 * P1 - F2^2 * obs[p2].pseudorange_m) / (F1^2 - F2^2)
    end
    x = collect(seed); cdt = 0.0; ok = false; nuse = 0
    for it in 1:10
        rows = Vector{Float64}[]; res = Float64[]
        for (prn, P) in pr
            haskey(dec_eph.eph, ('G', prn)) || continue
            row = dec_eph.eph[('G', prn)].row
            ttx = trx - P / C; sp, dts = satpos(row, ttx); ttx -= dts; sp, dts = satpos(row, ttx)
            τ = P / C; θ = OMEGA_E * τ; sp = (sp[1]*cos(θ) + sp[2]*sin(θ), -sp[1]*sin(θ) + sp[2]*cos(θ), sp[3])   # Sagnac
            el = enu_el((x[1],x[2],x[3]), sp); (it > 2 && el < deg2rad(10)) && continue
            ρ = norm(collect(sp) .- x); h = ecef2plh(x...)[3]
            push!(rows, [-(sp[1]-x[1])/ρ, -(sp[2]-x[2])/ρ, -(sp[3]-x[3])/ρ, 1.0])
            push!(res, P - (ρ + cdt - C * dts + tropo(h, el)))
        end
        nuse = length(rows); nuse < 5 && break
        A = reduce(vcat, transpose.(rows)); dx = A \ res
        x .+= dx[1:3]; cdt += dx[4]
        norm(dx[1:3]) < 1e-3 && (ok = true; break)
    end
    ok && nuse >= 5 && (push!(sols, (x[1], x[2], x[3])); push!(nsat_used, nuse))
end
println("\nepochs decoded=", length(epochs), "  solved=", length(sols))
if length(sols) >= 10
    X = median(s[1] for s in sols); Y = median(s[2] for s in sols); Z = median(s[3] for s in sols)
    sx = std(s[1] for s in sols); sy = std(s[2] for s in sols); sz = std(s[3] for s in sols)
    lat, lon, h = ecef2plh(X, Y, Z); slat, slon, sh = ecef2plh(seed...)
    d = norm([X, Y, Z] .- collect(seed))
    @printf("SPP median ECEF: X=%.3f Y=%.3f Z=%.3f  (per-epoch std %.1f/%.1f/%.1f m, sats used median %d)\n", X, Y, Z, sx, sy, sz, median(nsat_used))
    @printf("SPP lat/lon/h  : %.7f  %.7f  %.3f m (ellipsoidal)\n", lat, lon, h)
    @printf("profile seed   : %.7f  %.7f  %.3f m   -> seed is %.1f m away\n", slat, slon, prof.gga_height_m, d)
    @printf("RESULT gga_lat_deg=%.7f gga_lon_deg=%.7f gga_height_m=%.2f\n", lat, lon, h)
end
dec_obs.station === nothing || println("1005 seen: ", dec_obs.station)
println("DONE")
