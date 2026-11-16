# Part 4b ablation: Ristretto's own design choices switched off one at a time.
#
#   julia --project=benchmark/comparison -t N benchmark/ablation/ablation.jl \
#       --case=<id> --method=<m> --out=<file.json> [--reltol=<tol> --maxit=<n>] [--no-pin]
#
# One process per case and thread count. The variants are all run-time switches, so they run in
# this one process, each timed with the suite's protocol (`time_run`: one warm-up, FFTW wisdom
# dropped before every run), and each image is scored against the ground truth and against the
# default variant's image. Placement comes from outside (numactl in ablation.sh); the Julia
# threads are pinned to the allowed physical cores in order.
#
# Variants:
#   default             nothing changed
#   no_task_splitting   disable_task_splitting = true
#   no_fusion           AbstractOperators.POINTWISE_FUSION[] = false
#   no_inner_threading  slices run in parallel, each serial (MultiThreadingExecutor) where the
#                       case splits into several tasks; threaded = false where it is one task
#   fft_estimate        fft_planning = :estimate
#   fft_measure         fft_planning = :measure
# Variants with no switch in Ristretto are recorded with status "no_switch" (see NO_SWITCH).

const ARGD = Dict(split(a[3:end], "="; limit = 2)[1] => (occursin("=", a) ? split(a, "="; limit = 2)[2] : "1") for a in ARGS if startswith(a, "--"))
const CASE = ARGD["case"]
const METHOD = Symbol(ARGD["method"])
const OUT = ARGD["out"]
const RELTOL = parse(Float64, get(ARGD, "reltol", "0"))
const MAXIT_ARG = get(ARGD, "maxit", nothing)

include(joinpath(@__DIR__, "..", "..", "Ristretto", "benchmark", "utils", "config.jl"))
load_site_env!()
using LinearAlgebra, FFTW, ThreadPinning, JSON, Dates

const NT = Threads.nthreads()
function allowed_physical_cpus()
    m = match(r"Cpus_allowed_list:\s*(\S+)", read("/proc/self/status", String))
    allowed = Int[]
    for part in split(m.captures[1], ',')
        lo, hi = occursin('-', part) ? split(part, '-') : (part, part)
        append!(allowed, parse(Int, lo):parse(Int, hi))
    end
    phys = filter(!ThreadPinning.ishyperthread, allowed)
    length(phys) >= NT || error("only $(length(phys)) physical cores allowed, $NT threads")
    return phys[1:NT]
end
# `--no-pin` leaves the threads unpinned, for smoke runs where fewer physical cores are allowed
# than threads asked for.
const CPUS = haskey(ARGD, "no-pin") ? Int[] : allowed_physical_cpus()
isempty(CPUS) || pinthreads(CPUS)
BLAS.set_num_threads(NT)
FFTW.set_num_threads(NT)

using Ristretto
include(joinpath(@__DIR__, "..", "..", "Ristretto", "benchmark", "utils", "bench_utils.jl"))
using .BenchUtils

const AO = Ristretto.AbstractOperators

const NO_SWITCH = Dict(
    "fftshift" => "fftshift instead of sign alternation: no switch; the shift is replaced by a sign alternation or phase ramp whenever it sits next to a DFT",
    "no_toeplitz" => "no switch: NFFTOperators.has_optimized_normalop(::NFFTOp) is fixed to true",
    "nfft_library_default" => "no switch: reconstruct does not forward m/sigma/precompute to the NFFT (get_fourier_operator takes them; DEFAULT_NFFT_M/SIGMA/PRECOMPUTE are constants)",
    "blas_free" => "no switch: every iterative solve runs under with_serial_blas (only CG takes BLAS threads back, via ProximalAlgorithms.CG_BLAS_THREAD_BYTES; see Part 3)",
)

c = get_case(CASE)
acq = ristretto_acquisition(c)
maxit = MAXIT_ARG === nothing ? default_maxit(METHOD) : parse(Int, MAXIT_ARG)
reg = METHOD === :cgsense ? () : ristretto_regularizer(c, METHOD, default_lambda(c, METHOD))
m = IterativeReconstruction(; regularization = reg, algorithm = ristretto_algorithm(METHOD, maxit; rho = admm_rho(c)), maxit, reltol = RELTOL)

# Whether the default configuration splits this case into more than one task.
const NTASKS = let plan = Ristretto.get_task_splitting_plan(acq, m, Ristretto.resolve_config(ReconstructionConfig(), acq, m))
    plan === nothing ? 1 : prod((plan.kspace_size[d] for d in plan.kspace_batch_dims); init = 1)
end

solver(; kw...) = () -> reconstruct(acq, m; verbosity = Silent(), kw...)

variants = [
    "default" => (solver(), () -> nothing, () -> nothing),
    "no_task_splitting" => (solver(; disable_task_splitting = true), () -> nothing, () -> nothing),
    "no_fusion" => (solver(), () -> (AO.POINTWISE_FUSION[] = false), () -> (AO.POINTWISE_FUSION[] = true)),
    "no_inner_threading" => (NTASKS > 1 ? solver(; task_executor = Ristretto.MultiThreadingExecutor()) : solver(; threaded = false), () -> nothing, () -> nothing),
    "fft_estimate" => (solver(; fft_planning = :estimate), () -> nothing, () -> nothing),
    "fft_measure" => (solver(; fft_planning = :measure), () -> nothing, () -> nothing),
]

rows = Any[]
ref_img = nothing
for (name, (f, on, off)) in variants
    row = Dict{String, Any}("variant" => name)
    try
        on()
        tmin, tmed, img = time_run(f; runs = timed_runs(c))
        img = Array(img)
        name == "default" && (global ref_img = img)
        row["status"] = "ok"
        row["time_min_s"] = tmin
        row["time_median_s"] = tmed
        row["nrmse_gt"] = BenchUtils.mag_nrmse(img, c.reference)
        row["nrmse_vs_default"] = BenchUtils.mag_nrmse(img, ref_img)
    catch e
        row["status"] = "error"
        row["error"] = first(sprint(showerror, e), 2000)
    finally
        off()
    end
    name == "no_task_splitting" && NTASKS == 1 && (row["note"] = "the default already runs this case as one task")
    name == "no_inner_threading" && (row["note"] = NTASKS > 1 ? "slices in parallel, each serial (MultiThreadingExecutor)" : "one task: threaded = false, so nothing threads")
    push!(rows, row)
    @info name row
end
for (name, why) in NO_SWITCH
    push!(rows, Dict("variant" => name, "status" => "no_switch", "note" => why))
end

subtree(dir) = try
    strip(read(`git -C $dir rev-parse HEAD:deps/AbstractOperators`, String))
catch
    ""
end
rdir = normpath(joinpath(@__DIR__, "..", "..", "Ristretto"))
meta = Dict(
    "case" => CASE, "method" => String(METHOD), "maxit" => maxit, "reltol" => RELTOL, "tasks" => NTASKS,
    "threads" => NT, "cpus" => CPUS, "host" => gethostname(), "node_class" => BenchUtils.node_class(),
    "slurm_job" => get(ENV, "SLURM_JOB_ID", ""), "numactl" => (
        try
            read(`numactl --show`, String)
        catch
            ""
        end
    ),
    "ristretto" => BenchUtils.git_ref(rdir), "benchmarking" => BenchUtils.git_ref(normpath(joinpath(@__DIR__, "..", ".."))),
    "deps_trees" => Dict(
        p => (
            try
                strip(read(`git -C $rdir rev-parse HEAD:deps/$p`, String))
            catch
                ""
            end
        ) for p in ("AbstractOperators", "ProximalAlgorithms", "ProximalOperators", "StructuredOptimization", "NFFT", "OperatorCore")
    ),
    "julia" => string(VERSION), "blas" => string(BLAS.get_config()), "cpu" => Sys.cpu_info()[1].model,
    "date" => string(now()), "image_n" => image_n(),
)
mkpath(dirname(OUT))
open(io -> JSON.print(io, Dict("meta" => meta, "rows" => rows), 2), OUT, "w")
