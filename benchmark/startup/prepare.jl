# Writes the case the startup benchmark solves to plain files, so every toolkit's script reads the
# same data without loading the comparison harness (which would load all six toolkits at once):
#
#   julia --project=benchmark/comparison benchmark/startup/prepare.jl <datadir> [case id]
#
# `<datadir>/`: `kspace.c64` (zero-filled `(nx, ny, coil)`), `smaps.c64` (`(nx, ny, coil)`),
# `reference.c64` (`(nx, ny)`), `mask.u8` (`(nx, ny)`), all column-major complex64 / uint8, the same
# k-space, maps and reference as BART's `ksp.cfl` / `sens.cfl` (`(nx, ny, 1, coil)`) and `ref.cfl`, and
# `meta.json` with the sizes, the iteration counts, each toolkit's calibrated λ of the L1-wavelet row
# (read as the sections read it) and the NRMSE the harness's own Ristretto reconstruction reaches on
# each method, which `run.jl` checks `solve_ristretto.jl` against.

using BartIO: write_cfl
using JSON

include(joinpath(@__DIR__, "..", "..", "Ristretto", "benchmark", "utils", "bench_utils.jl"))
using .BenchUtils
include(joinpath(@__DIR__, "..", "comparison", "scripts", "_lambda_files.jl"))

const DIR = ARGS[1]
const CASE = length(ARGS) >= 2 ? ARGS[2] : "shepp_logan_2d_8ch_cartesian"
const TOOLKITS = ("Ristretto", "BART", "SigPy", "MRIReco", "MIRT", "MRpro")
mkpath(DIR)

c = get_case(CASE)
c.family === :single_slice && c.trajectory === :cartesian && c.smaps !== nothing ||
    error("$CASE: the startup benchmark takes a single-slice multichannel Cartesian case")
nx, ny, nc = size(c.kspace)

writeraw(name, a) = open(io -> write(io, a), joinpath(DIR, name), "w")
writeraw("kspace.c64", ComplexF32.(c.kspace))
writeraw("smaps.c64", ComplexF32.(c.smaps))
writeraw("reference.c64", ComplexF32.(c.reference))
writeraw("mask.u8", UInt8.(c.mask))

write_cfl(joinpath(DIR, "ksp"), reshape(ComplexF32.(c.kspace), nx, ny, 1, nc))
write_cfl(joinpath(DIR, "sens"), reshape(ComplexF32.(c.smaps), nx, ny, 1, nc))
write_cfl(joinpath(DIR, "ref"), reshape(ComplexF32.(c.reference), nx, ny))

lambda = Dict(tk => v for tk in TOOLKITS for v in (lambda_from_files((c.id, c.analogue), :wavelet, tk),) if v !== nothing)
maxit = Dict(:wavelet => OUTER_ITERATIONS, :cgsense => CG_ITERATIONS)
ristretto_nrmse = Dict(
    String(m) => BenchUtils.mag_nrmse(parent(ristretto_reconstructor(c, m; λ = get(lambda, "Ristretto", 0.0), maxit = maxit[m])()), c.reference)
        for m in (:wavelet, :cgsense)
)
meta = Dict(
    "case" => CASE, "nx" => nx, "ny" => ny, "coils" => nc,
    "wavelet_iterations" => maxit[:wavelet], "cgsense_iterations" => maxit[:cgsense],
    "wavelet_levels" => BenchUtils.WAVELET_LEVELS, "wavelet_name" => "db2", "lambda_wavelet" => lambda,
    "ristretto_nrmse" => ristretto_nrmse,
)
open(io -> JSON.print(io, meta, 2), joinpath(DIR, "meta.json"), "w")
println("wrote $CASE ($nx×$ny, $nc coils) to $DIR")
