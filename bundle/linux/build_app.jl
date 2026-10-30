# build_app.jl — PackageCompiler driver for the standalone GaiaSeis binary.
#
# Invoked by build-app.sh; not meant to be run by hand.
#
#   julia build_app.jl <repo_root> <app_source> <dest> <gaiavario_path> [ppphva_path]
#
# Julia cannot cross-compile: run this ON the Linux machine you want the
# binary for, and the glibc there sets the floor for what it will run on.

const REPO      = abspath(ARGS[1])
const APPSRC    = abspath(ARGS[2])
const DEST      = abspath(ARGS[3])
const GAIAVARIO = length(ARGS) >= 4 && !isempty(ARGS[4]) ? abspath(ARGS[4]) : ""
const PPPHVA    = length(ARGS) >= 5 && !isempty(ARGS[5]) ? abspath(ARGS[5]) : ""

isdir(REPO)   || error("repo root not found: $REPO")
isdir(APPSRC) || error("app source not found: $APPSRC")
isfile(joinpath(GAIAVARIO, "Project.toml")) || error("GaiaVario.jl not found: $GAIAVARIO")

using Pkg

# ---- 1. Point the app environment at the local checkouts ---------------
# GaiaSeis and GaiaVario are path deps of the app; GaiaSeisEngineAPI (a
# path dep of both, inside the GaiaSeis tree) and the optional PPPHVA
# come along. Dev'ing them explicitly means the build does not care where
# the checkouts sit relative to one another on this machine.
@info "resolving the app environment" APPSRC REPO GAIAVARIO PPPHVA
# Without PPPHVA the GaiaSeis Project.toml must not list it, or the
# resolve below fails on the missing path dependency.
if isempty(PPPHVA) && occursin(r"^PPPHVA\s*="m, read(joinpath(REPO, "Project.toml"), String))
    error("$(joinpath(REPO, "Project.toml")) still lists PPPHVA as a dependency; " *
          "build with --with-ppphva or remove that line")
end
Pkg.activate(APPSRC)
# All of them go in ONE develop call. Developing them one at a time fails:
# the first resolve sees the other as an unregistered dependency and
# errors with "expected package GaiaSeis [7c8d0e1a] to be registered".
specs = Pkg.PackageSpec[]
push!(specs, Pkg.PackageSpec(path = joinpath(REPO, "GaiaSeisEngineAPI")))
isempty(PPPHVA) || push!(specs, Pkg.PackageSpec(path = PPPHVA))
push!(specs, Pkg.PackageSpec(path = GAIAVARIO))
push!(specs, Pkg.PackageSpec(path = REPO))
Pkg.develop(specs)
Pkg.instantiate()
Pkg.precompile()

# ---- 2. PackageCompiler itself ----------------------------------------
# It goes in the shared default environment, never in the app's own deps —
# otherwise it would be compiled into the shipped binary.
Pkg.activate()
try
    @eval using PackageCompiler
catch
    @info "installing PackageCompiler into the default environment"
    Pkg.add("PackageCompiler")
    @eval using PackageCompiler
end

# ---- 3. Build ----------------------------------------------------------
@info "building the app (this takes 10-30 min and a few GB of RAM)" DEST
create_app(
    APPSRC, DEST;
    executables            = ["gaiaseis" => "julia_main"],
    force                  = true,
    # Gtk4 pulls its GTK/Pango/Cairo shared libraries in as artifacts,
    # several of them lazy — without this the binary starts and then dies
    # on a missing libgtk-4.so.
    include_lazy_artifacts = true,
    # A fresh sysimage rather than an incremental one: smaller, and it
    # avoids inheriting whatever happens to be in the host's default image.
    incremental            = false,
    filter_stdlibs         = false,
)

@info "app built" DEST
