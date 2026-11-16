# Peak resident memory of each toolkit's solve, every one in a fresh process, at a given thread
# count: the startup benchmark's solve scripts (`../startup/solve_*`, BART's `pics`) on the case
# `../startup/prepare.jl` wrote to <datadir>, run under `/usr/bin/time`, whose "maximum resident
# set size" is the largest RSS the process reached (load, setup, one solve and one warm solve).
#
#   julia --project=benchmark/comparison benchmark/sizes/peak_memory.jl <datadir> <threads> <out.json>
#
# Placement comes from outside (numactl in part5.sh); the children inherit it.

using JSON, Dates
include(joinpath(@__DIR__, "..", "..", "Ristretto", "benchmark", "utils", "config.jl"))
load_site_env!()

const DATADIR, THREADS, OUTFILE = ARGS[1], parse(Int, ARGS[2]), ARGS[3]
const JULIA = joinpath(Sys.BINDIR, "julia")
const PROJECT = normpath(joinpath(@__DIR__, "..", "comparison"))
const PYTHON = get(ENV, "RISTRETTO_BENCH_SIGPY_PYTHON", "")
const BART = get(ENV, "RISTRETTO_BENCH_BART_OPENBLAS", "")
const STARTUP = normpath(joinpath(@__DIR__, "..", "startup"))
const META = JSON.parsefile(joinpath(DATADIR, "meta.json"))
const NX, NY, NC = META["nx"], META["ny"], META["coils"]
const MAXIT = Dict("wavelet" => META["wavelet_iterations"], "cgsense" => META["cgsense_iterations"])
λ(name, m) = m == "cgsense" ? 0.0 : Float64(META["lambda_wavelet"][name])

const CHILD_ENV = merge(
    filter(p -> !startswith(p.first, "JULIA_NUM_THREADS"), Dict(ENV)),
    Dict(
        "OMP_NUM_THREADS" => string(THREADS), "OPENBLAS_NUM_THREADS" => string(THREADS),
        "BART_USE_FFTW_WISDOM" => "0", "PYTHONWARNINGS" => "ignore",
    ),
)
const JL = `$JULIA --startup-file=no --project=$PROJECT -t $THREADS`

function solve_cmd(name, m)
    args = [DATADIR, m, "1", string(NX), string(NY), string(NC), string(MAXIT[m]), string(λ(name, m))]
    name == "BART" && return m == "wavelet" ?
        `$BART pics -S -w 1 -e -i $(MAXIT[m]) -R W:3:0:$(λ("BART", m)) ksp sens out_$m` :
        `$BART pics -S -w 1 -i $(MAXIT[m]) ksp sens out_$m`
    script = joinpath(
        STARTUP, Dict(
            "Ristretto" => "solve_ristretto.jl", "MRIReco" => "solve_mrireco.jl",
            "SigPy" => "solve_sigpy.py", "MRpro" => "solve_mrpro.py"
        )[name]
    )
    return endswith(script, ".jl") ? `$JL $script $args` : `$PYTHON $script $args`
end

rows = Any[]
for name in ("Ristretto", "BART", "MRIReco", "SigPy", "MRpro"), m in ("cgsense", "wavelet")
    (name in ("SigPy", "MRpro") && !isfile(PYTHON)) && continue
    (name == "BART" && !isfile(BART)) && continue
    timefile = tempname()
    cmd = `/usr/bin/time -o $timefile -f "MAXRSS_KB %M WALL_S %e" $(solve_cmd(name, m))`
    out = IOBuffer(); err = IOBuffer()
    p = run(pipeline(ignorestatus(setenv(cmd, CHILD_ENV; dir = DATADIR)); stdout = out, stderr = err))
    t = read(timefile, String)
    rss = match(r"MAXRSS_KB (\d+)", t)
    wall = match(r"WALL_S (\S+)", t)
    res = match(r"RESULT \S+ \S+ \S+ (\S+)", String(take!(out)))
    push!(
        rows, Dict(
            "toolkit" => name, "method" => m, "status" => success(p) ? "ok" : "error",
            "max_rss_mb" => rss === nothing ? nothing : parse(Int, rss[1]) / 1024,
            "wall_s" => wall === nothing ? nothing : parse(Float64, wall[1]),
            "nrmse" => res === nothing ? nothing : parse(Float64, res[1]),
            "error" => success(p) ? nothing : first(String(take!(err)), 2000),
        )
    )
    @info name m rows[end]
end
open(
    io -> JSON.print(
        io, Dict(
            "nx" => NX, "ny" => NY, "coils" => NC, "threads" => THREADS, "rows" => rows,
            "host" => gethostname(), "slurm_job" => get(ENV, "SLURM_JOB_ID", ""), "date" => string(now()),
            "numactl" => (
                try
                    read(`numactl --show`, String)
                catch
                    ""
                end
            ),
        ), 2
    ), OUTFILE, "w"
)
