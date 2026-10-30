# Engine plug-ins (GaiaSeisEngineAPI) on the platform side: loading the
# package named by the profile, converting the decoder's epochs and records to
# the API types, and turning an engine's result into what the bridge logs,
# gates and publishes. The historical in-bridge PPPHVA path is selected with
# `engine = "ppphva"` and does not go through this file.

const EAPI = GaiaSeisEngineAPI

# Package to load for an engine name; other names are taken as package names.
const _ENGINE_PACKAGES = Dict("gaiavario" => "GaiaVario")

_engine_is_plugin(profile::NtripProfile) = lowercase(strip(profile.engine)) != "ppphva"

"""
Make the engine named in the profile available: `using` its package (from the
active environment, or from `engine_path` added to the load path). Returns the
registry symbol. Throws an ArgumentError with the install instructions when
the package cannot be loaded.
"""
function _load_engine!(profile::NtripProfile)
    name = lowercase(strip(profile.engine))
    sym = Symbol(name)
    EAPI.has_engine(sym) && return sym
    pkg = get(_ENGINE_PACKAGES, name, profile.engine)
    pkgsym = Symbol(pkg)
    loaded = false
    for attempt in 1:2
        try
            @eval Main using $pkgsym
            loaded = true
            break
        catch err
            if attempt == 1 && !isempty(profile.engine_path)
                p = abspath(expanduser(profile.engine_path))
                p in LOAD_PATH || pushfirst!(LOAD_PATH, p)
                continue
            end
            throw(ArgumentError("engine \"$(profile.engine)\": package $pkg could not be loaded ($(sprint(showerror, err))). " *
                                "Install it (julia> ] add $pkg) or set engine_path in the profile to its directory."))
        end
    end
    EAPI.has_engine(sym) || throw(ArgumentError("package $pkg loaded but registered no engine named \"$name\" (registered: $(join(string.(EAPI.engine_names()), ", ")))"))
    return sym
end

# Flat option dictionary for the engine: the profile's fields that concern every
# engine plus the free-form `engine_options` ("key=value,key=value").
function _engine_options(profile::NtripProfile)
    opts = Dict{String,Any}("mode" => profile.engine_mode,
                            "elev_mask_deg" => profile.elv_cutoff_deg,
                            "systems" => join(c for (c, on) in zip("GREC", (profile.enable_gps, profile.enable_glo,
                                                                            profile.enable_gal, profile.enable_bds)) if on))
    for kv in split(profile.engine_options, ',')
        kv = strip(kv); isempty(kv) && continue
        k, v = occursin('=', kv) ? split(kv, '='; limit = 2) : (kv, "true")
        v = strip(v)
        opts[String(strip(k))] = something(tryparse(Float64, v), v == "true" ? true : v == "false" ? false : String(v))
    end
    return opts
end

# ---- time and observations ---------------------------------------------------------

# Current GPS week: from the newest GPS LNAV record (row[2] is the absolute
# week), else from the session's anchor, else from the wall clock.
function _engine_week(decoder::RtcmDecoder, session::NtripSession)
    for ((sys, _), rec) in decoder.eph
        sys == 'G' && length(rec.row) >= 2 && isfinite(rec.row[2]) && rec.row[2] > 0 && return Int(rec.row[2])
    end
    session.stats.gps_week > 0 && return Int(session.stats.gps_week)
    return Int(_current_gps_week_anchor())
end

# MSM epoch encoding -> GPS (week, seconds of week); GLONASS and BeiDou frames
# are moved to the GPS scale (the same conventions as _sod_gps).
function _engine_epoch_time(ep::MsmEpoch, week::Int)
    ms = ep.epoch_ms
    if ep.sys == 'G' || ep.sys == 'E'
        tow = ms / 1000
    elseif ep.sys == 'C'
        tow = ms / 1000 + 14.0
    elseif ep.sys == 'R'
        dow = floor(ms / 2^27); tod = mod(ms, 2^27) / 1000
        tow = dow * 86400 + tod - 3 * 3600 + GPS_UTC_LEAP_S
    else
        return EAPI.EpochTime(week, NaN)
    end
    tow < 0 && (tow += 604800; week -= 1)
    tow >= 604800 && (tow -= 604800; week += 1)
    return EAPI.EpochTime(week, tow)
end

# Civil codes before semi-codeless/P codes inside a frequency slot (GPS 2X before 2W).
_engine_code_rank(code::AbstractString) = endswith(code, "W") ? 3 : endswith(code, "P") ? 2 : 1

"""All frames of one epoch group -> one ObsEpoch on the GPS time scale."""
function _frames_to_obsepoch(frames::Vector{MsmEpoch}, week::Int)
    sats = Dict{Tuple{Char,Int},EAPI.SatObservation}()
    rank = Dict{Tuple{Char,Int,Int},Int}()
    t = nothing
    for ep in frames
        et = _engine_epoch_time(ep, week)
        isfinite(et.tow) || continue
        # the group's time is the GPS frame's when present (all are equal within the tolerance)
        (t === nothing || ep.sys == 'G') && (t = et)
        for o in ep.obs
            sl = o.freq_no
            (sl <= 0 || !isfinite(o.carrier_m)) && continue
            s = get!(sats, (ep.sys, o.prn)) do; EAPI.SatObservation(ep.sys, o.prn); end
            r = _engine_code_rank(o.rinex_code)
            key = (ep.sys, o.prn, sl)
            haskey(rank, key) && rank[key] <= r && continue
            rank[key] = r
            s.phase[sl] = o.carrier_m; s.code[sl] = o.pseudorange_m
            s.lock[sl] = o.lock_indicator; s.half[sl] = o.half_cycle_amb; s.cnr[sl] = o.cnr_dbhz
            s.code_id[sl] = o.rinex_code
        end
    end
    t === nothing && return nothing
    return EAPI.ObsEpoch(t, collect(values(sats)))
end

# ---- results -> the bridge's flag/gate interfaces ------------------------------------

# PPPHVA satellite numbering used by the flag and gate helpers (see _prn_sys).
_engine_prn(sys::Char, prn::Int) = sys == 'G' ? prn : sys == 'R' ? 32 + prn : sys == 'E' ? 58 + prn : 94 + prn

# The `dg` the satellite-flag, constellation and gate helpers read: residual,
# weight and PRN of every satellite used, and the list the engine rejected.
function _engine_dg(res::EAPI.EngineResult)
    used = [r for r in res.sats if r.used]
    return (prn = [_engine_prn(r.sys, r.prn) for r in used],
            res = [r.resid_m for r in used],
            w = [r.weight for r in used],
            removed = [_engine_prn(r.sys, r.prn) for r in res.sats if r.reason == :rejected])
end

# ---- labels and the "About engine" text --------------------------------------------

const _ENGINE_MODE_LABEL = Dict("single" => "L1", "dual" => "ionosphere-free", "mean" => "L1+L2 mean", "l1gf" => "L1 + GF correction")

"""Short label for headers and status: "GaiaVario · L1", "PPPHVA · DFV"."""
function engine_label(profile::NtripProfile)
    _engine_is_plugin(profile) || return "PPPHVA · " * profile.process_mode
    m = lowercase(strip(profile.engine_mode))
    return string(get(_ENGINE_PACKAGES, lowercase(strip(profile.engine)), profile.engine), " · ", get(_ENGINE_MODE_LABEL, m, profile.engine_mode))
end

const _ENGINE_ABOUT = Dict{String,String}(
"gaiavario" => """
GaiaVario — variometric displacement engine written for GaiaSeis
Author     : Panagiotis Elias, Deforming Gaia Lab, University of Patras
Licence    : AGPL-3.0-only (same as the platform)
Repository : (to be published)

Method: epoch-to-epoch carrier-phase differences of every satellite seen
with continuous lock, minus the modelled change of geometry, satellite
clock, troposphere, solid tide and wind-up; weighted least squares with
elevation weights, per-satellite rejection and a windowed robust noise
estimate. One broadcast record per satellite for both epochs of a pair;
continuous GPS time (week, seconds of week), no day wrap.

Observables: single (L1 alone, default), dual (ionosphere-free pair),
mean (average of two phases), l1gf (L1 corrected with the smoothed
geometry-free rate).

Models and sources: GPS, Galileo and BeiDou orbits/clocks from the
interface control documents (IS-GPS-200, Galileo OS SIS ICD, BeiDou SIS
ICD incl. the GEO rotation); GLONASS by RK4 of the PZ-90 equations
(GLONASS ICD 5.1); Saastamoinen zenith delays with Niell (1996) mapping
functions; degree-2 solid Earth tide (IERS Conventions 2010) with
Sun/Moon from Montenbruck & Gill; phase wind-up after Wu et al. (1993).
No ANTEX, GPT3 or VMF files are needed.
""",
"ppphva" => """
PPPHVA.jl — Julia translation of PPPH-VA
Translation: Panagiotis Elias (University of Patras); original MATLAB
software PPPH-VA by B. Bahadur, M. Bezcioglu and C. O. Yigit.
Licence of the translation: pending the original authors' terms
(not distributed).

Please cite the original publication when results of this engine are
used: Bahadur B., Bezcioglu M., Yigit C. O. (2023), "PPPH-VA: an
open-source software for real-time multi-GNSS variometric approach
using single- and dual-frequency observations", GPS Solutions,
doi 10.1007/s10291-023-01560-z.

Method: variometric approach on ionosphere-free (DFV) or single-frequency
(SFV) carrier phase; broadcast or SSR orbits and clocks; VMF3/GPT3
troposphere; ANTEX phase centres; cycle-slip detection.
""")

"""Text of the "About engine" dialog / web box for the session (or, without a
session, for the engine of the default profile)."""
function engine_about_text(sess)
    profile = sess === nothing ? NtripProfile() : sess.profile
    name = lowercase(strip(profile.engine))
    key = _engine_is_plugin(profile) ? name : "ppphva"
    body = get(_ENGINE_ABOUT, key, "Engine \"$(profile.engine)\": no description registered.\n")
    running = sess !== nothing && sess.bridge_state !== nothing && !isempty(sess.bridge_state.engine_info) ?
              sess.bridge_state.engine_info : "not started"
    ver = ""
    if key == "gaiavario" && isdefined(Main, :GaiaVario)
        try; ver = string(Base.pkgversion(Main.GaiaVario)); catch; end
    end
    head = string("Engine in use : ", engine_label(profile), isempty(ver) ? "" : "  (GaiaVario $ver)", "\n",
                  "Profile       : ", profile.name, "\n",
                  "Running       : ", running, "\n",
                  _engine_is_plugin(profile) ? string("Options       : engine_mode = ", profile.engine_mode,
                      isempty(profile.engine_options) ? "" : ", " * profile.engine_options, "\n") :
                      string("Options       : process_mode = ", profile.process_mode, ", antex = ",
                             isempty(profile.antex_file) ? "none" : basename(profile.antex_file), "\n"),
                  "\n")
    return head * body * _PLUGIN_NOTE
end

const _PLUGIN_NOTE = """

────────────────────────────────────────────────────────────────────────
Engines are plug-ins

GaiaSeis is the platform (streams, decoding, epoch grouping, outputs,
quality gate, GUI/web). The displacement itself comes from an engine
selected in the profile ("Engine" page of the profile editor, or the
field engine = "..." in ntrip_profiles.toml). An engine is a Julia
package that depends only on the small interface package
GaiaSeisEngineAPI and registers itself under a name; the platform hands
it the station, every broadcast record and each receiver epoch, and
receives dX dY dZ, clocks, residuals and quality figures back. Switching
engines changes nothing downstream.

Engine available today: GaiaVario (in-house variometric, default); the
in-bridge path "ppphva" exists for the author's translation of PPPH-VA,
which is not distributed. Other engines that fit
the same interface, for example: a PPP-AR engine wrapping Ginan or
PPP-Wizard for absolute positions; a Kalman-filter variometric engine
that integrates velocities with a constrained drift; a replay engine
that reproduces a recorded solution for tests; an engine that fuses
GNSS with a co-located accelerometer.

Writing one: implement the four functions of GaiaSeisEngineAPI
(engine_nav!, engine_step!, engine_reset!, engine_info), declare the
parameters the configuration page should show (ParamSpec), and call
register_engine!(:name, factory; params, description) in the package's
__init__. Then set engine = "name" in the profile (engine_path points to
the package directory when it is not installed). Documents: the API
docstring in NtripClient.jl/GaiaSeisEngineAPI/src/GaiaSeisEngineAPI.jl
(call order, time scales, record layout), the user manual section 5.27
("Engine plug-ins"), and GaiaVario.jl/src/plugin.jl as a complete
example of about 60 lines.
"""

# ---- parameters for the configuration tab --------------------------------------

# The historical in-bridge PPPHVA path is configured through dedicated profile
# fields; the tab shows them through the same parameter mechanism.
const _PPPHVA_PARAMS = [
    EAPI.ParamSpec("process_mode", "Process mode", :choice; default = "DFV", choices = ["DFV", "SFV"],
                   help = "DFV = dual-frequency (ionosphere-free), SFV = single-frequency"),
    EAPI.ParamSpec("elv_cutoff_deg", "Elevation cut (°)", :float; default = 10.0, min = 0.0, max = 60.0, step = 1.0),
    EAPI.ParamSpec("antex_file", "ANTEX file", :text; default = "", help = "antenna phase-centre file (optional)"),
]

"""Engine names offered by the configuration tab: the registered plug-ins, the
plug-in packages this installation knows how to load (GaiaVario when its
package or directory is present) and, when the PPPHVA package was found at
load time, the in-bridge PPPHVA path."""
function available_engine_names(engine_path::AbstractString = "")
    names = String[]
    append!(names, string.(EAPI.engine_names()))
    _phva_loaded() && push!(names, "ppphva")
    for (n, pkg) in _ENGINE_PACKAGES
        n in names && continue
        if Base.find_package(pkg) !== nothing || (!isempty(engine_path) && isdir(abspath(expanduser(engine_path)))) ||
           isdir(joinpath(app_root(), "..", pkg * ".jl"))
            push!(names, n)
        end
    end
    return unique(names)
end

"""Parameter descriptions of an engine; loads the plug-in package if needed.
Throws with the install hint when it cannot be loaded."""
function engine_param_specs(name::AbstractString, engine_path::AbstractString = "")
    lowercase(strip(name)) == "ppphva" && return _PPPHVA_PARAMS
    prof = NtripProfile(engine = String(name), engine_path = String(engine_path))
    sym = _load_engine!(prof)
    return EAPI.engine_params(sym)
end

"""Parse the profile's `engine_options` ("key=value,key=value") into strings."""
function parse_engine_options(s::AbstractString)
    d = Dict{String,String}()
    for kv in split(s, ',')
        kv = strip(kv); isempty(kv) && continue
        k, v = occursin('=', kv) ? split(kv, '='; limit = 2) : (kv, "true")
        d[String(strip(k))] = String(strip(v))
    end
    return d
end
