# Reading the calibration files `calibrate_lambda.jl` writes (`results/lambda/<case id>.json`). JSON
# only, so a script that must not load the harness (the startup benchmark's `prepare.jl`) reads λ
# exactly as the sections do. Assumes BenchUtils (`small_mode`, `image_n`) is loaded.

using JSON: JSON

"""
    LAMBDA_DIR

`results/lambda/`, one calibration file per case; under `RISTRETTO_BENCH_SMALL=1` the separate
`results/lambda_small/`, so a smoke calibration of the shrunken cases never overwrites the real one.
An image size other than the default (`RISTRETTO_BENCH_N`) gets its own directory too,
`results/lambda_n<size>/` (`results/lambda_small_n<size>/` in small mode), since the best λ
changes with the size. `RISTRETTO_BENCH_LAMBDA_DIR` replaces all of these with a directory of its
own, to calibrate somewhere the sections do not read (comparing two calibrations, say).
"""
const LAMBDA_DIR = let base = small_mode() ? "lambda_small" : "lambda"
    isempty(get(ENV, "RISTRETTO_BENCH_N", "")) || (base *= "_n$(image_n())")
    dir = get(ENV, "RISTRETTO_BENCH_LAMBDA_DIR", "")
    normpath(isempty(dir) ? joinpath(@__DIR__, "..", "results", base) : dir)
end

"""
    lambda_from_files(ids, method, toolkit) -> Float64 or nothing

The calibrated λ of `toolkit` for `method`, from the first of the cases `ids` (a case, then its
synthetic analogue) whose file in [`LAMBDA_DIR`](@ref) has one, failing that from the pre-catalog
`results/lambda_calibration.json`; `nothing` when none has.
"""
function lambda_from_files(ids, method::Symbol, toolkit::AbstractString)
    for id in unique(ids)
        v = _lambda_from(joinpath(LAMBDA_DIR, "$id.json"), method, toolkit)
        v === nothing || return v
    end
    return _lambda_from(normpath(joinpath(@__DIR__, "..", "results", "lambda_calibration.json")), method, toolkit)
end

function _lambda_from(path, method, toolkit; table = "lambda")
    isfile(path) || return nothing
    tbl = try
        JSON.parsefile(path)[table]
    catch
        return nothing
    end
    m = get(tbl, String(method), nothing)
    (m === nothing || !haskey(m, toolkit)) && return nothing
    v = m[toolkit]
    return (v isa Real && isfinite(v)) ? Float64(v) : nothing
end
