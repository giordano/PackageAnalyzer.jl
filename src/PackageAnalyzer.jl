module PackageAnalyzer

# Standard libraries
using Pkg, TOML, UUIDs, Printf
# Third-party packages
using LicenseCheck # for `find_license` and `is_osi_approved`
using JSON3 # for interfacing with `tokei` to count lines of code
using Tokei_jll # count lines of code
import GitHub # Use GitHub API to get extra information about the repo
import Git: Git
using Downloads
using Tar
using CodecZlib
using AbstractTrees
using JuliaSyntax
using JuliaSyntax: @K_str
using Legolas
using Legolas: @schema, @version
using OrderedCollections
using PrecompileTools

# We wrap `registry_info` for thread-safety, so we don't want to pull into the namespace here
using RegistryInstances: RegistryInstances, reachable_registries, PkgEntry

# Ways to find packages
export find_package, find_packages, find_packages_in_manifest
# Ways to analyze them
export analyze, analyze_manifest, analyze_packages, LineCategories
export PackageCollection

##
# Borrowed from
# https://github.com/beacon-biosignals/SlackThreads.jl/blob/74351c2863ec9a1cf22732873d4d2816aa9c140d/src/SlackThreads.jl#L27-L49
const CATCH_EXCEPTIONS = Ref(true)

# We turn off exception handling for our tests, to ensure we aren't throwing exceptions
# that we're missing. But we have it on by default, since in ordinary usage we want to
# be sure we are catching all exceptions.
macro maybecatch(expr, log_str, ret=nothing)
    quote
        try
            $(esc(expr))
        catch e
            if $(CATCH_EXCEPTIONS)[]
                @debug $(esc(log_str)) exception = (e, catch_backtrace())
                $(esc(ret))
            else
                # No stacktrace, because we'll get one anyway
                @debug $(esc(log_str)) exception = e
                rethrow()
            end
        end
    end
end
#
##

# To support (de)-serialization
export PackageV1, PackageV1SchemaVersion

# borrowed from <https://github.com/JuliaRegistries/RegistryTools.jl/blob/841a56d8274e2857e3fd5ea993ba698cdbf51849/src/builtin_pkgs.jl>
const stdlibs = isdefined(Pkg.Types, :stdlib) ? Pkg.Types.stdlib : Pkg.Types.stdlibs
# Julia 1.8 changed from `name` to `(name, version)`.
get_stdlib_name(s::AbstractString) = s
get_stdlib_name(s::Tuple) = first(s)
const STDLIBS = Dict(k => get_stdlib_name(v) for (k, v) in stdlibs())
is_stdlib(name::AbstractString) = name in values(STDLIBS)
is_stdlib(uuid::UUID) = uuid in keys(STDLIBS)

@schema "package-analyzer.license" License

@version LicenseV1 begin
    license_filename::String
    licenses_found::Vector{String}
    license_file_percent_covered::Float64
end

@schema "package-analyzer.lines-of-code" LinesOfCode

@version LinesOfCodeV2 begin
    directory::String
    language::Symbol
    sublanguage::Union{Nothing, Symbol}
    files::Int
    code::Int
    comments::Int
    blanks::Int
    docstrings::Union{Missing, Int}
end

@schema "package-analyzer.contributions" Contributions

@version ContributionsV1 begin
    login::Union{String,Missing}
    id::Union{Int,Missing}
    name::Union{String,Missing}
    type::String
    contributions::Int
end


@schema "package-analyzer.package" Package

# Handle version serialization
# https://github.com/apache/arrow-julia/issues/461
convert_version(::Missing) = missing
convert_version(::Nothing) = missing
convert_version(v::Any) = string(v)

# Upgrade V1's
upgrade_lines_of_code(loc::Vector{LinesOfCodeV2}) = loc
upgrade_lines_of_code(loc) = LinesOfCodeV2.(loc)

@version PackageV1 begin
    name::String # name of the package
    uuid::UUID # uuid of the package
    repo::String # URL of the repository
    subdir::String # subdirectory of the package in the repo
    reachable::Bool # can the repository be cloned?
    docs::Bool # does it have documentation?
    runtests::Bool # does it have the test/runtests.jl file?
    github_actions::Bool # does it use GitHub Actions?
    travis::Bool # does it use Travis CI?
    appveyor::Bool # does it use AppVeyor?
    cirrus::Bool # does it use Cirrus CI?
    circle::Bool # does it use Circle CI?
    drone::Bool # does it use Drone CI?
    buildkite::Bool # does it use Buildkite?
    azure_pipelines::Bool # does it use Azure Pipelines?
    gitlab_pipeline::Bool # does it use Gitlab Pipeline?
    license_files::Vector{LicenseV1} # a table of all possible license files
    licenses_in_project::Vector{String} # any licenses in the `license` key of the Project.toml
    lines_of_code::Vector{LinesOfCodeV2} = upgrade_lines_of_code(lines_of_code) # table of lines of code
    contributors::Vector{ContributionsV1} # table of contributor data
    # Note: ideally this would be Union{Nothing, VersionNumber}, however
    # Arrow seems to not be able to serialize that correctly: https://github.com/apache/arrow-julia/issues/461.
    version::Union{Missing, String}=convert_version(version) # the version number, if a release was analyzed
    tree_hash::String # the tree hash of the code that was analyzed
end

function PackageV1(name, uuid, repo;
                 subdir="",
                 reachable=false,
                 docs=false,
                 runtests=false,
                 github_actions=false,
                 travis=false,
                 appveyor=false,
                 cirrus=false,
                 circle=false,
                 drone=false,
                 buildkite=false,
                 azure_pipelines=false,
                 gitlab_pipeline=false,
                 license_files=LicenseV1[],
                 licenses_in_project=String[],
                 lines_of_code=LinesOfCodeV2[],
                 contributors=ContributionsV1[],
                 version=nothing,
                 tree_hash="",
                 )
    return PackageV1(; name, uuid, repo, subdir, reachable, docs, runtests, github_actions, travis,
                   appveyor, cirrus, circle, drone, buildkite, azure_pipelines, gitlab_pipeline,
                   license_files, licenses_in_project, lines_of_code, contributors, version,
                   tree_hash)
end

function Base.show(io::IO, p::PackageV1)
    compact = get(io, :compact, false)::Bool
    if compact
        return print(io, PackageV1, "(\"", p.name, "\", …)")
    end
    body = """
        PackageV1 $(p.name):
          * repo: $(p.repo)
        """
    if !isempty(p.subdir)
        body *= """
            * in subdirectory: $(p.subdir)
        """
    end
    body *= """
          * uuid: $(p.uuid)
          * version: $(p.version)
          * is reachable: $(p.reachable)
        """
    if p.reachable
        body *= """
          * tree hash: $(p.tree_hash)
        """
        if !isempty(p.lines_of_code)
            l_src = sum_julia_loc(p, "src")
            l_ext = sum_julia_loc(p, "ext")
            l_test = sum_julia_loc(p, "test")
            l_docs = sum_doc_lines(p)
            l_readme = sum_readme_lines(p)

            p_ext = @sprintf("%.1f", 100 * l_ext / (l_test + l_src + l_ext))
            p_test = @sprintf("%.1f", 100 * l_test / (l_test + l_src + l_ext))
            p_docs = @sprintf("%.1f", 100 * l_docs / (l_docs + l_src + l_ext))

            body *= """
                  * Julia code in `src`: $(l_src) lines
                  * Julia code in `ext`: $(l_ext) lines ($(p_ext)% of `test` + `src` + `ext`)
                  * Julia code in `test`: $(l_test) lines ($(p_test)% of `test` + `src` + `ext`)
                  * documentation in `docs`: $(l_docs) lines ($(p_docs)% of `docs` + `src` + `ext`)
                """

            l_src_docstring = sum_docstrings(p, "src")
            if !ismissing(l_src_docstring)
                n = l_src_docstring + l_readme
                p_docstrings = @sprintf("%.1f", 100 * n / (n + l_src))
                body *= """
                      * documentation in README & docstrings: $(n) lines ($(p_docstrings)% of README + `src`)
                    """
                end
            end
        if isempty(p.license_files)
            body *= "  * no license found\n"
        else
            lic = p.license_files[1]
            license_string = join(lic.licenses_found, ", ")
            body *= "  * has license(s) in file: $(license_string)\n"
            body *= "    * filename: $(lic.license_filename)\n"
            body *= "    * OSI approved: $(all(is_osi_approved, lic.licenses_found))\n"
        end
        if !isempty(p.licenses_in_project)
            lic_project = join(p.licenses_in_project, ", ")
            body *= "  * has license(s) in Project.toml: $(lic_project)\n"
            body *= "    * OSI approved: $(all(is_osi_approved, p.licenses_in_project))\n"
        end
        if !isempty(p.contributors)
            n_anon = sum_contributors(p; type="Anonymous")
            body *= "  * number of contributors: $(sum_contributors(p)) (and $(n_anon) anonymous contributors)\n"
            body *= "  * number of commits: $(sum_commits(p))\n"
        end
        body *= """
              * has `docs/make.jl`: $(p.docs)
              * has `test/runtests.jl`: $(p.runtests)
            """
        ci_services = (p.github_actions => "GitHub Actions",
                       p.travis => "Travis",
                       p.appveyor => "AppVeyor",
                       p.cirrus => "Cirrus",
                       p.circle => "Circle",
                       p.drone => "Drone CI",
                       p.buildkite => "Buildkite",
                       p.azure_pipelines => "Azure Pipelines",
                       p.gitlab_pipeline => "GitLab Pipeline",
                       )
        if any(first.(ci_services))
            body *= "  * has continuous integration: true\n"
            for (k, v) in ci_services
                if k
                    body *= "    * $(v)\n"
                end
            end
        else
            body *= "  * has continuous integration: false\n"
        end
    end
    print(io, strip(body))
end


# We could have:
# * release version: registry + version or registry + tree_hash (equivalent)
# * Pkg.add: path + tree_hash, or url + tree_hash
# * Pkg.dev: just path or url
#
# Additionally, the user may pass us just a path, which we treat like Pkg.dev
# or the user may pass us a Module, which we treat the same way (via pkgdir),
# or they may ask for the dev version, which again we treat the same way.
#
# They may ask for a specific version, which we treat like release.
"""
    abstract type PkgSource

Represents the installed version of a package, e.g. a release from a registry, or a `Pkg.add`'d package, or a `Pkg.dev`'d package.
"""
abstract type PkgSource end

# Represents the released version of a package
# Contains the fields we need from the registry
Base.@kwdef struct Release <: PkgSource
    name::String = ""
    uuid::UUID = UUID(0)
    repo::String = ""
    subdir::String = ""
    tree_hash::String = ""
    version::VersionNumber = v"0"
end

# Helper to extract needed fields from a `PkgEntry`, with a version number
function Release(entry::PkgEntry, version::VersionNumber)
    info = registry_info(entry)
    tree_hash = bytes2hex(info.version_info[version].git_tree_sha1.bytes)
    name = entry.name
    uuid = entry.uuid
    repo = something(info.repo, "")
    subdir = something(info.subdir, "")
    return Release(; tree_hash, name, uuid, repo, subdir, version)
end

function Base.show(io::IO, r::Release)
    print(io, "Release(")
    show(io, r.name)
    print(io, ", ")
    show(io, r.version)
    print(io, ")")
end

# Represents a `Pkg.add`'d package (non-release)
Base.@kwdef struct Added <: PkgSource
    name::String = ""
    uuid::UUID = UUID(0)
    # Only one of `path` or `repo_url` should be non-empty
    path::String = ""
    repo_url::String = ""
    tree_hash::String = ""
    subdir::String = ""
end

function Base.show(io::IO, a::Added)
    print(io, "Added(")
    show(io, a.name)
    print(io, ", ")
    show(io, a.tree_hash)
    print(io, ")")
end

# Represents a Pkg.dev'd package
Base.@kwdef struct Dev <: PkgSource
    name::String = ""
    uuid::UUID = UUID(0)
    path::String = ""
end

function Base.show(io::IO, d::Dev)
    print(io, "Dev(")
    show(io, d.name)
    print(io, ", ")
    show(io, d.path)
    print(io, ")")
end


# Represents the latest state of the trunk branch
# of a repo
Base.@kwdef struct Trunk <: PkgSource
    repo_url::String=""
    subdir::String=""
end

function Base.show(io::IO, d::Trunk)
    print(io, "Trunk(")
    url = d.repo_url
    if !isempty(d.subdir)
        url *= ":" * d.subdir
    end
    show(io, url)
    print(io, ")")
end

include("package_collection.jl")

# Provides methods to obtain a `PkgSource`
include("find_packages.jl")

# `PkgSource` -> code directory
include("obtain_code.jl")

# `analyze_code`: `code directory -> `PackageV1`
# `analyze`: `PkgSource` -> code directory -> `PackageV1`
# `analyze`: input -> `PkgSource` -> code directory -> `PackageV1`
include("analyze.jl")

# Collection of `PkgSource` -> `Vector{PackageV1}`
include("parallel.jl")

# github, parsing
include("utilities.jl")

include("LineCategories.jl")
using .CategorizeLines

# tokei, counting
include("count_loc.jl")

include("deprecated_schemas.jl")

@compile_workload begin
    p = analyze(PackageAnalyzer)
    sprint(show, MIME"text/plain"(), p)
    nothing
end

end # module
