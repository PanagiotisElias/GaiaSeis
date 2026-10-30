# The bridge keeps its per-session containers (`inf`, `nav`, `obs`, `ssr`,
# `loc`, …) in MATLAB-like dynamic structs. Historically these were
# `PPPHVA.PStruct`; GaiaSeis now has its own, so the platform loads and runs
# without the PPPHVA package. When PPPHVA *is* present (a local test
# installation with `engine = "ppphva"`), its own PStruct type is used instead
# so its functions receive the type they were written for.

"""Dynamic struct: fields are created on first access (nested) or assignment."""
mutable struct PStruct
    d::Dict{Symbol,Any}
    PStruct() = new(Dict{Symbol,Any}())
    PStruct(p::Pair...) = (s = new(Dict{Symbol,Any}()); for (k, v) in p; s.d[k] = v; end; s)
end

function Base.getproperty(s::PStruct, k::Symbol)
    k === :d && return getfield(s, :d)
    dd = getfield(s, :d)
    haskey(dd, k) || (dd[k] = PStruct())
    return dd[k]
end
Base.setproperty!(s::PStruct, k::Symbol, v) = (getfield(s, :d)[k] = v)
Base.haskey(s::PStruct, k::Symbol) = haskey(getfield(s, :d), k)
Base.keys(s::PStruct) = keys(getfield(s, :d))
Base.show(io::IO, s::PStruct) = print(io, "PStruct(", join(string.(keys(getfield(s, :d))), ", "), ")")

# ---- optional PPPHVA ------------------------------------------------------------------
# The Julia translation of PPPH-VA is not distributed with GaiaSeis. It is
# picked up at load time when it is resolvable: in the active environment, in
# the directory named by GAIASEIS_PPPHVA_PATH, or as the sibling
# `../PPPH_VA/PPPHVA.jl` of the application root. Without it the engine name
# "ppphva" is not offered and a profile that asks for it fails to start with
# the message below.
const _PPPHVA_MOD = Ref{Any}(nothing)

_phva_loaded() = _PPPHVA_MOD[] !== nothing

"""The PPPHVA module, or an ArgumentError explaining how to make it available."""
function _phva()
    m = _PPPHVA_MOD[]
    m === nothing && throw(ArgumentError(
        "the \"ppphva\" engine is not available: the package PPPHVA (Julia translation of PPPH-VA) " *
        "is not distributed with GaiaSeis. Select engine = \"gaiavario\" in the profile, or make " *
        "PPPHVA loadable (add it to the environment, set GAIASEIS_PPPHVA_PATH, or place it at " *
        "../PPPH_VA/PPPHVA.jl beside the application root) and restart."))
    return m
end

"""A new dynamic struct of the type the active solver expects."""
_pstruct() = _phva_loaded() ? _PPPHVA_MOD[].PStruct() : PStruct()

_is_pstruct(x) = x isa PStruct || (_phva_loaded() && x isa _PPPHVA_MOD[].PStruct)

"""Load PPPHVA if it can be found (called from `__init__`). Returns true when loaded."""
function _init_ppphva!()
    try
        id = Base.identify_package("PPPHVA")
        if id === nothing
            for d in (get(ENV, "GAIASEIS_PPPHVA_PATH", ""), joinpath(app_root(), "..", "PPPH_VA", "PPPHVA.jl"))
                isempty(d) && continue
                d = abspath(expanduser(d))
                isfile(joinpath(d, "Project.toml")) || continue
                d in LOAD_PATH || push!(LOAD_PATH, d)
                id = Base.identify_package("PPPHVA")
                id === nothing || break
            end
        end
        id === nothing && return false
        _PPPHVA_MOD[] = Base.require(id)
        # the package was loaded a moment ago: its methods are newer than this world
        Base.invokelatest(_autodetect_gpt3_grid!)
        return true
    catch err
        @warn "PPPHVA found but could not be loaded; the \"ppphva\" engine is unavailable" err
        _PPPHVA_MOD[] = nothing
        return false
    end
end
