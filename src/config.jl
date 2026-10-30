# Persisted NTRIP-profile management.
#
# The on-disk format is TOML so it's easy to hand-edit. Schema:
#
#     # ntrip_profiles.toml
#     active = "BKG_GREF"             # name of the profile to load by default
#
#     [profiles.BKG_GREF]
#     caster        = "products.igs-ip.net"
#     port          = 2101
#     mountpoint    = "GREF00DEU0"
#     user          = "user"
#     password      = "secret"
#     use_tls       = false
#     send_gga      = false
#     gga_lat_deg   = 50.10
#     gga_lon_deg   = 8.68
#     gga_height_m  = 100.0
#     enable_gps    = true
#     enable_glo    = true
#     enable_gal    = true
#     enable_bds    = false
#     process_mode  = "DFV"
#     elv_cutoff_deg= 10
#     log_dir       = "logs"
#     output_filename = ""
#
#     [profiles.LocalCaster]
#     caster        = "127.0.0.1"
#     port          = 2101
#     mountpoint    = "MYMOUNT"
#     ...

# Lives under `data_root()` (= the repo root in a source checkout, an
# XDG state directory for an installed build) because the GUI writes it
# back on every "Save profile". `GAIASEIS_PROFILES` overrides it wholesale.
function default_profiles_path()
    env = get(ENV, "GAIASEIS_PROFILES", "")
    return isempty(env) ? joinpath(config_dir(), "ntrip_profiles.toml") : abspath(env)
end

profiles_path() = default_profiles_path()

"""
    load_profiles(path = default_profiles_path()) -> (active::String, profiles::Dict{String,NtripProfile})

Read the TOML config. Missing fields fall back to `NtripProfile`'s defaults.
If the file doesn't exist, returns a single seed profile named `"default"`.
"""
function load_profiles(path::AbstractString = default_profiles_path())
    profiles = Dict{String,NtripProfile}()
    if !isfile(path)
        p = NtripProfile(name = "default")
        profiles["default"] = p
        return "default", profiles
    end
    data = TOML.parsefile(path)
    raw_profiles = get(data, "profiles", Dict{String,Any}())
    for (name, body) in raw_profiles
        p = NtripProfile(; name = String(name))
        for (k, v) in body
            sym = Symbol(k)
            if hasproperty(p, sym)
                try
                    setproperty!(p, sym, _coerce(typeof(getproperty(p, sym)), v))
                catch err
                    @warn "skipping bad field $name.$k: $err"
                end
            end
        end
        profiles[String(name)] = p
    end
    if isempty(profiles)
        profiles["default"] = NtripProfile(name = "default")
    end
    active = get(data, "active", first(keys(profiles)))
    haskey(profiles, active) || (active = first(keys(profiles)))
    return String(active), profiles
end

"""
    save_profiles(active, profiles, path = default_profiles_path())

Write the in-memory profile table back to TOML, preserving formatting roughly
(TOML round-trips lose comments). Creates parent directory if needed.
"""
function save_profiles(active::AbstractString, profiles::Dict{String,NtripProfile},
                       path::AbstractString = default_profiles_path())
    mkpath(dirname(path))
    out = Dict{String,Any}()
    out["active"] = String(active)
    pmap = Dict{String,Any}()
    for (name, p) in profiles
        body = Dict{String,Any}()
        for f in fieldnames(NtripProfile)
            f === :name && continue
            body[String(f)] = getfield(p, f)
        end
        pmap[name] = body
    end
    out["profiles"] = pmap
    open(path, "w") do io
        TOML.print(io, out; sorted = true)
    end
    return path
end

"""
    default_profile() -> NtripProfile

Construct a fresh profile with the package defaults.
"""
default_profile() = NtripProfile()

# Type-coerce TOML values into the profile's declared field type.
_coerce(::Type{T}, v) where {T<:AbstractString} = String(v)
_coerce(::Type{Int}, v) = v isa Integer ? Int(v) : Int(round(v))
_coerce(::Type{Float64}, v) = Float64(v)
_coerce(::Type{Bool}, v) = v isa Bool ? v : (v == 1 || v == "true")
_coerce(::Type{T}, v) where {T} = T(v)
