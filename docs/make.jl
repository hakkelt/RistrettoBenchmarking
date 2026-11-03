# Builds the site from the committed snapshots in `benchmark/comparison/results/` and
# `benchmark/startup/results.json`. It runs no benchmark and does not load Ristretto.
#
#   julia --project=docs -e 'using Pkg; Pkg.instantiate()'
#   julia --project=docs docs/make.jl
using Documenter

include(joinpath(@__DIR__, "benchmark_tables.jl"))  # BenchmarkTables, for results.md

makedocs(;
    sitename = "RistrettoBenchmarking",
    repo = Remotes.GitHub("hakkelt", "RistrettoBenchmarking"),
    format = Documenter.HTML(; prettyurls = get(ENV, "CI", nothing) == "true", edit_link = "master", inventory_version = ""),
    pages = ["Overview" => "index.md", "Benchmarks" => "results.md", "Feature comparison" => "features.md"],
)
