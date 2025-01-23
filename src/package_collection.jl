struct PackageCollection <: AbstractVector{PackageV1}
    pkgs::Vector{PackageV1}
end

Base.getindex(p::PackageCollection, i::Int) = p.pkgs[i]
Base.size(p::PackageCollection) = size(p.pkgs)

function _to_underscore(n::Integer)
    x = Iterators.partition(digits(n), 3)
    return join(reverse(join.(reverse.(x))), '_')
end


function Base.show(io::IO, ::MIME"text/plain", c::PackageCollection)
    n = length(c)
    summary(io, c)
    println(io)
    l_src = l_ext = l_test = l_docs = l_readme = l_src_docstring = 0

    for p in c
        l_src += sum_julia_loc(p, "src")
        l_ext += sum_julia_loc(p, "ext")
        l_test += sum_julia_loc(p, "test")
        l_docs += sum_doc_lines(p)
        l_readme += sum_readme_lines(p)
        l_src_docstring += sum_docstrings(p, "src")
    end

    p_ext = @sprintf("%.1f", 100 * l_ext / (l_test + l_src + l_ext))
    p_test = @sprintf("%.1f", 100 * l_test / (l_test + l_src + l_ext))
    p_docs = @sprintf("%.1f", 100 * l_docs / (l_docs + l_src + l_ext))

    p_ext = @sprintf("%.1f", 100 * l_ext / (l_test + l_src + l_ext))
    p_test = @sprintf("%.1f", 100 * l_test / (l_test + l_src + l_ext))
    p_docs = @sprintf("%.1f", 100 * l_docs / (l_docs + l_src + l_ext))

    body = """
        * Source code
          * Total Julia source code: $(_to_underscore(l_src)) lines
          * Total Julia extension code: $(_to_underscore(l_ext)) lines ($(p_ext)% of `test` + `src` + `ext`)
          * Julia code test code: $(_to_underscore(l_test)) lines ($(p_test)% of `test` + `src` + `ext`)
          * Lines of documentation: $(_to_underscore(l_docs)) lines ($(p_docs)% of `docs` + `src` + `ext`)
        """

    n = l_src_docstring + l_readme
    p_docstrings = @sprintf("%.1f", 100 * n / (n + l_src))
    body *= """
          * Total lines of documentation in README & docstrings: $(n) lines ($(p_docstrings)% of README + `src`)
        """
    print(io, strip(body))

    licenses = OrderedDict{String, Vector{String}}()
    for p in c
        for lic in p.license_files
            for license in lic.licenses_found
                v = get!(Vector{String}, licenses, license)
                push!(v, p.name)
            end
        end
    end
    sort!(licenses; by=((k,v),) -> length(v))
    println(io, "\n* Licenses")
    for (k, v) in licenses
        sort!(unique!(v))
        print(io, "  * $k ($(length(v))): ")
        join(io, v, ", ")
        println(io)
    end
end
