"""
GaiaSeisEngineAPI — the interface between the GaiaSeis platform and a
displacement engine plug-in.

The platform decodes the NTRIP/RTCM streams, groups the observations of one
receiver epoch, keeps the broadcast ephemerides and the station information,
and hands them to an engine; the engine returns the displacement of the
receiver over the pair of epochs (variometric engines) together with the
quality figures the platform logs, gates and publishes. An engine package
depends only on this module (no GUI, no network code) and registers itself
under a name; the platform selects it with the profile field `engine`.

Contract, in the order the platform calls it:

1. `create_engine(name, station, options)` once the station position is known;
   `options` is a flat `Dict{String,Any}` from the profile (engine-specific
   keys, e.g. `"mode" => "single"`, `"elev_mask_deg" => 10.0`).
2. `engine_nav!(eng, nav, t)` for every new or changed broadcast record
   (also before the first epoch), where `nav.row` follows the platform's
   39-column layout documented below.
3. `engine_step!(eng, epoch)` once per receiver epoch, in time order; returns
   an `EngineResult`. The first epoch and any epoch without a fit return a
   result whose `status` is not `:ok` and whose displacement is NaN.
4. `engine_reset!(eng)` when the platform decides the pairing must restart
   (a hole in the input longer than the profile allows); the next epoch is
   then a first epoch again.
5. `engine_ssr!` is optional; engines that do not use SSR keep the default.

Times are GPS time as (week, seconds of week) for every constellation; the
platform converts GLONASS and BeiDou time scales before calling.

Row layout of `NavRow.row` (39 Float64, NaN where unused), as produced by the
platform's RTCM decoder:
  Kepler sets (GPS 1019, Galileo 1045, BeiDou 1042): [1] prn, [2] GPS
  week (NaN for Galileo), [8..10] af0 af1 af2, [11] IODE/IODnav/AODE, [12] crs,
  [13] Δn, [14] M0, [15] cuc, [16] e, [17] cus, [18] √A, [19] toe seconds of
  week (BeiDou in BDT), [20] cic, [21] Ω0, [22] cis, [23] i0, [24] crc, [25] ω,
  [26] Ω̇, [27] IDOT, [39] toc as GPS-scale seconds of day.
  GLONASS 1020: [2] frequency channel k, [8] −τn, [9] γn, [11,15,19] x y z km,
  [12,16,20] velocities km/s, [13,17,21] accelerations km/s², [39] tb as
  GPS-scale seconds of day.
"""
module GaiaSeisEngineAPI

export EpochTime, SatObservation, ObsEpoch, NavRow, Station, SatLine, EngineResult,
       AbstractEngine, engine_create, engine_nav!, engine_step!, engine_reset!, engine_ssr!,
       engine_info, register_engine!, engine_names, has_engine, create_engine, no_result,
       ParamSpec, engine_params, engine_description

"""GPS time: week number and seconds of week."""
struct EpochTime
    week::Int
    tow::Float64
end

"""One satellite's observations at one epoch. Phases and codes in metres,
keyed by frequency slot (1 = L1/E1/B1, 2 = L2/B1I, 5 = L5/E5a/B2a, 6 = E6/B3I,
7 = E5b/B2b, 8 = E5 AltBOC); `lock` is the RTCM lock-time indicator per slot
(a decrease means a loss of lock), `half` the half-cycle ambiguity flag, `cnr`
in dB-Hz; `code_id` the RINEX signal code chosen for the slot ("1C", "2X")."""
struct SatObservation
    sys::Char
    prn::Int
    phase::Dict{Int,Float64}
    code::Dict{Int,Float64}
    lock::Dict{Int,Int}
    half::Dict{Int,Bool}
    cnr::Dict{Int,Float64}
    code_id::Dict{Int,String}
end
SatObservation(sys::Char, prn::Int) = SatObservation(sys, prn, Dict{Int,Float64}(), Dict{Int,Float64}(),
                                                     Dict{Int,Int}(), Dict{Int,Bool}(), Dict{Int,Float64}(), Dict{Int,String}())

"""One receiver epoch, all constellations on the GPS time scale."""
struct ObsEpoch
    t::EpochTime
    sats::Vector{SatObservation}
end

"""A broadcast ephemeris record in the platform's 39-column layout."""
struct NavRow
    sys::Char
    prn::Int
    row::Vector{Float64}
end

"""Station information available to the engine."""
Base.@kwdef struct Station
    xyz::NTuple{3,Float64}
    antenna::String = ""           # antenna descriptor (IGS name) when the stream carries one
    receiver::String = ""
    antex::String = ""             # path of an ANTEX file, if the profile gives one
end

"""Per-satellite line of a result."""
struct SatLine
    sys::Char
    prn::Int
    elev_deg::Float64
    azim_deg::Float64
    resid_m::Float64               # post-fit residual of the pair observation
    weight::Float64
    used::Bool
    reason::Symbol                 # :ok :new :slip :elev :noeph :nofreq :rejected or engine-specific
end

"""Result of one epoch: displacement over the pair (previous epoch → this one)."""
struct EngineResult
    dxyz::NTuple{3,Float64}        # ECEF [m], NaN when no fit
    dneu::NTuple{3,Float64}        # local north, east, up [m]
    clk::Dict{Char,Float64}        # receiver clock change per constellation [m]
    nsat_in::Int                   # satellites offered to the fit
    nsat_used::Int                 # satellites in the final fit
    nsys::Int                      # constellations in the fit
    pdop::Float64
    rms_m::Float64                 # weighted post-fit RMS
    sig_neu::NTuple{3,Float64}     # formal 1-sigma of dneu [m]
    sats::Vector{SatLine}
    status::Symbol                 # :ok, :first, :few_sats, :no_position, :singular, or engine-specific
end

"""A result without a fit."""
no_result(status::Symbol, sats::Vector{SatLine} = SatLine[]) =
    EngineResult((NaN, NaN, NaN), (NaN, NaN, NaN), Dict{Char,Float64}(), length(sats), 0, 0,
                 NaN, NaN, (NaN, NaN, NaN), sats, status)

abstract type AbstractEngine end

# ---- the functions an engine implements ---------------------------------------
"""Feed a new or changed broadcast record; `t` is the current GPS time."""
function engine_nav! end
"""Solve one epoch; returns an EngineResult."""
function engine_step! end
"""Forget the previous epoch so the next one starts a new pair."""
function engine_reset! end
"""Optional: SSR orbit/clock corrections (engine-specific arguments). Default: ignored."""
engine_ssr!(eng::AbstractEngine, args...) = nothing
"""One line describing the engine and its options (logs, status page)."""
engine_info(eng::AbstractEngine) = string(nameof(typeof(eng)))

# ---- parameter descriptions (the platform's configuration tab is built from them) ----
"""One user-settable parameter of an engine. `kind` is :choice (with `choices`),
:float, :int, :bool or :text; `default` is the value used when the profile
does not set the key; the platform passes values in the options Dict under
`key` (numbers as Float64/Int, booleans as Bool, the rest as String)."""
struct ParamSpec
    key::String
    label::String
    kind::Symbol
    default::Any
    choices::Vector{String}
    min::Float64
    max::Float64
    step::Float64
    help::String
end
ParamSpec(key::AbstractString, label::AbstractString, kind::Symbol; default = nothing, choices = String[],
          min = -Inf, max = Inf, step = 1.0, help = "") =
    ParamSpec(String(key), String(label), kind, default, String.(collect(choices)), Float64(min), Float64(max), Float64(step), String(help))

# ---- registry -----------------------------------------------------------------
# name => (factory(station, options) -> AbstractEngine, params::Vector{ParamSpec}, description)
const _REGISTRY = Dict{Symbol,NamedTuple{(:factory, :params, :description),Tuple{Any,Vector{ParamSpec},String}}}()

"""Register an engine factory under `name` (an engine package calls this in
its `__init__`), with the parameters its configuration tab offers and a
one-paragraph description."""
function register_engine!(name::Symbol, factory; params::Vector{ParamSpec} = ParamSpec[], description::AbstractString = "")
    _REGISTRY[name] = (factory = factory, params = params, description = String(description))
    return nothing
end
engine_names() = sort!(collect(keys(_REGISTRY)))
has_engine(name::Symbol) = haskey(_REGISTRY, name)
engine_params(name::Symbol) = haskey(_REGISTRY, name) ? _REGISTRY[name].params : ParamSpec[]
engine_description(name::Symbol) = haskey(_REGISTRY, name) ? _REGISTRY[name].description : ""

"""Create the engine registered as `name`."""
function create_engine(name::Symbol, station::Station, options::Dict{String,Any} = Dict{String,Any}())
    r = get(_REGISTRY, name, nothing)
    r === nothing && throw(ArgumentError("no engine registered as \"$name\"; registered: $(join(string.(engine_names()), ", "))"))
    eng = r.factory(station, options)
    eng isa AbstractEngine || throw(ArgumentError("engine factory \"$name\" returned $(typeof(eng)), not an AbstractEngine"))
    return eng
end
"""Alias kept for readability in plug-in code."""
const engine_create = create_engine

end # module
