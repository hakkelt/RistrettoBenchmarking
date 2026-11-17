# Builds the site from the result files committed under `benchmark/`. It runs no benchmark and does
# not load Ristretto: every table comes from `docs/tables.jl`.
#
#   julia --project=docs -e 'using Pkg; Pkg.instantiate()'
#   julia --project=docs docs/make.jl
using Documenter

include(joinpath(@__DIR__, "tables.jl"))  # module Tables, called from the pages' @eval blocks

makedocs(;
    sitename = "RistrettoBenchmarking",
    repo = Remotes.GitHub("hakkelt", "RistrettoBenchmarking"),
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", nothing) == "true", edit_link = "master", inventory_version = "",
        size_threshold = 1_000_000, size_threshold_warn = 400_000,
    ),
    pages = [
        "Overview" => "index.md",
        "Methodology" => "methods.md",
        "Comparison" => ["accuracy.md", "fixed.md", "scaling.md", "gpu.md", "sizes.md", "startup.md"],
        "Ristretto alone" => ["large.md", "ablation.md"],
        "Feature comparison" => "features.md",
        "Data and reproduction" => "data.md",
    ],
)
