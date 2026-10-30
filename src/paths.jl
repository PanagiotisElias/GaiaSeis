# Runtime path resolution.
#
# Every path the program needs while running — the bundled assets, the
# profile TOML, the logs directory — used to be derived from `@__DIR__`.
# That is correct for a source checkout but wrong for two deployment
# shapes we now support:
#
#   * a PackageCompiler app, where `@__DIR__` bakes the *build machine's*
#     source path into the binary and no longer exists at run time;
#   * a system-wide install (`/opt/gaiaseis`, `/usr/local/...`) whose
#     program directory is read-only, so logs and the profile TOML have
#     to live somewhere else.
#
# Both are routed through the two roots below.
#
#   app_root()   read-only program data: docs/assets, config template,
#                the ANTEX files.  Override with GAIASEIS_ROOT.
#   data_root()  writable state: logs/, mseed dumps, the live profile
#                TOML.  Override with GAIASEIS_DATA_DIR.
#
# With neither variable set both collapse to the repo root, so a source
# checkout behaves exactly as it did before this file existed.

const _APP_ROOT  = Ref{String}("")
const _DATA_ROOT = Ref{String}("")

# The source-tree layout: src/ sits one level below the package root.
_source_root() = normpath(joinpath(@__DIR__, ".."))

"""
    app_root() -> String

Directory holding the read-only program data (`docs/assets`, `config`,
the `.atx` files). `GAIASEIS_ROOT` wins over the source-tree default.
"""
function app_root()
    isempty(_APP_ROOT[]) || return _APP_ROOT[]
    env = get(ENV, "GAIASEIS_ROOT", "")
    return isempty(env) ? _source_root() : normpath(abspath(env))
end

"""
    data_root() -> String

Directory the program writes into (logs, miniSEED, the profile TOML).
`GAIASEIS_DATA_DIR` wins; otherwise it is the same as [`app_root`](@ref).
"""
function data_root()
    isempty(_DATA_ROOT[]) || return _DATA_ROOT[]
    env = get(ENV, "GAIASEIS_DATA_DIR", "")
    return isempty(env) ? app_root() : normpath(abspath(env))
end

"""
    set_app_root!(path)
    set_data_root!(path)

Pin either root explicitly, taking precedence over the environment.
The compiled-app entry point uses these to point at the directories
laid down beside the binary.
"""
set_app_root!(p)  = (_APP_ROOT[]  = normpath(abspath(String(p))))
set_data_root!(p) = (_DATA_ROOT[] = normpath(abspath(String(p))))

assets_dir()     = joinpath(app_root(), "docs", "assets")
icon_theme_dir() = joinpath(assets_dir(), "icons")
logs_dir()       = joinpath(data_root(), "logs")
config_dir()     = joinpath(data_root(), "config")

# Software version, read from Project.toml at load time. Lives here because
# `paths.jl` is the first include, so both the NTRIP User-Agent (ntrip.jl)
# and the GUI header/About text can use it without duplicating the lookup.
const _SOFTWARE_VERSION = try
    string(Base.pkgversion(@__MODULE__))
catch
    "0.5.0"
end
