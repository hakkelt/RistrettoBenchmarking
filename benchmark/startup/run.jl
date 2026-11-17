# Startup cost of every toolkit of the cross-toolkit comparison, each measured in fresh processes:
#
#   julia --project=benchmark/comparison benchmark/startup/run.jl
#
# What a user pays before the first image (runtime start, package load, first-call compilation,
# end-to-end process) for every toolkit of the cross-toolkit comparison, each in fresh pinned
# processes. The quantities, the placement and the `STARTUP_*` overrides are described in
# `README.md` next to this file. Machine paths (the BART build, the Python interpreter) come from
# `benchmark/slurm/site.env`; run it through `benchmark/startup/startup.sh` on a compute node.

using Dates, JSON, Printf, Statistics, TOML

include(joinpath(@__DIR__, "..", "..", "Ristretto", "benchmark", "utils", "config.jl"))
load_site_env!()

const REPO = normpath(joinpath(@__DIR__, "..", ".."))
const PROJECT = joinpath(REPO, "benchmark", "comparison")
const THREADS = parse(Int, get(ENV, "STARTUP_THREADS", "8"))
const REPS = parse(Int, get(ENV, "STARTUP_REPS", "5"))
const WARM_REPS = parse(Int, get(ENV, "STARTUP_WARM_REPS", "3"))
const NWARM = parse(Int, get(ENV, "STARTUP_NWARM", "10"))
const DATADIR = get(ENV, "STARTUP_DATADIR", joinpath(tempdir(), "ristretto-startup"))
const OUT = get(ENV, "STARTUP_OUT", joinpath(@__DIR__, "results.json"))
const CASE = "shepp_logan_2d_8ch_cartesian"
const JULIA = joinpath(Sys.BINDIR, Base.julia_exename())
const PYTHON = get(ENV, "RISTRETTO_BENCH_SIGPY_PYTHON", "")
const BART = get(ENV, "RISTRETTO_BENCH_BART_OPENBLAS", "")

# ---------------------------------------------------------------- placement

"""
    pick_cpus(n) -> (cpus, node)

`n` allowed CPUs on distinct physical cores of one NUMA node (the first one that has enough).
"""
function pick_cpus(n)
    allowed = Set{Int}()
    for l in eachline("/proc/self/status")
        startswith(l, "Cpus_allowed_list:") || continue
        for r in split(strip(split(l, ":")[2]), ",")
            p = parse.(Int, split(r, "-"))
            union!(allowed, p[1]:p[end])
        end
    end
    seen = Set{Int}()
    bynode = Dict{Int, Vector{Int}}()
    for l in eachline(`lscpu -p=CPU,CORE,NODE`)
        startswith(l, "#") && continue
        cpu, core, node = parse.(Int, split(l, ","))
        (cpu in allowed && !(core in seen)) || continue
        push!(seen, core)
        push!(get!(bynode, node, Int[]), cpu)
    end
    for node in sort!(collect(keys(bynode)))
        length(bynode[node]) >= n && return bynode[node][1:n], node
    end
    error("no NUMA node has $n allowed physical cores: $bynode")
end

const CPUS, NODE = pick_cpus(THREADS)
const CPU_STR = join(CPUS, ",")
const PIN = Sys.which("numactl") === nothing ? `taskset -c $CPU_STR` : `numactl --physcpubind=$CPU_STR --membind=$NODE`
const CHILD_ENV = merge(
    filter(p -> !startswith(p.first, "JULIA_NUM_THREADS"), Dict(ENV)),
    Dict(
        "OMP_NUM_THREADS" => string(THREADS), "OPENBLAS_NUM_THREADS" => string(THREADS),
        "MKL_NUM_THREADS" => string(THREADS), "OMP_PROC_BIND" => "close", "OMP_PLACES" => "{$CPU_STR}",
        "GOMP_CPU_AFFINITY" => CPU_STR, "BART_USE_FFTW_WISDOM" => "0", "PYTHONWARNINGS" => "ignore",
    ),
)

const JL = `$JULIA --startup-file=no --project=$PROJECT -t $THREADS`

"""
    timed(cmd) -> (wall_s, stdout)

Run `cmd` pinned, in the child environment, and return its wall time and output.
"""
function timed(cmd; dir = DATADIR)
    out = IOBuffer()
    err = IOBuffer()
    t0 = time_ns()
    p = run(pipeline(ignorestatus(setenv(`$PIN $cmd`, CHILD_ENV; dir)); stdout = out, stderr = err))
    t = (time_ns() - t0) / 1.0e9
    success(p) || error("$cmd failed:\n$(String(take!(err)))")
    return t, String(take!(out))
end

# ---------------------------------------------------------------- the case

# A data directory written by an earlier version of prepare.jl (without the harness's NRMSE) is rewritten.
isfile(joinpath(DATADIR, "meta.json")) && haskey(JSON.parsefile(joinpath(DATADIR, "meta.json")), "ristretto_nrmse") ||
    run(`$JULIA --startup-file=no --project=$PROJECT $(joinpath(@__DIR__, "prepare.jl")) $DATADIR $CASE`)
const META = JSON.parsefile(joinpath(DATADIR, "meta.json"))
(META["wavelet_name"], META["wavelet_levels"]) == ("db2", 3) ||
    error("the solve scripts assume 3 levels of db2 wavelets, the harness uses $(META["wavelet_levels"]) of $(META["wavelet_name"])")
const NX, NY, NC = META["nx"], META["ny"], META["coils"]
const MAXIT = Dict("wavelet" => META["wavelet_iterations"], "cgsense" => META["cgsense_iterations"])

# ---------------------------------------------------------------- the toolkits

# `runner` runs the toolkit's solve script, `load` is a process that only loads the toolkit, `runtime`
# the bare runtime its numbers are set against, `needs` the executable without which it is skipped.
const PY = isempty(PYTHON) ? "python3" : PYTHON
const TOOLKITS = [
    (name = "Ristretto", runner = JL, script = "solve_ristretto.jl", load = `$JL -e "using Ristretto"`, runtime = "Julia", needs = JULIA, methods = ("wavelet", "cgsense")),
    (name = "MRIReco", runner = JL, script = "solve_mrireco.jl", load = `$JL -e "using MRIReco"`, runtime = "Julia", needs = JULIA, methods = ("wavelet", "cgsense")),
    (name = "MIRT", runner = JL, script = "solve_mirt.jl", load = `$JL -e "using MIRT"`, runtime = "Julia", needs = JULIA, methods = ("cgsense",)),
    (name = "SigPy", runner = `$PY`, script = "solve_sigpy.py", load = `$PY -c "import sigpy, sigpy.mri.app"`, runtime = "Python", needs = PYTHON, methods = ("wavelet", "cgsense")),
    (name = "MRpro", runner = `$PY`, script = "solve_mrpro.py", load = `$PY -c "import mrpro"`, runtime = "Python", needs = PYTHON, methods = ("wavelet", "cgsense")),
    (name = "BART", runner = `bash`, script = "solve_bart.sh", load = `$BART version`, runtime = nothing, needs = BART, methods = ("wavelet", "cgsense")),
]

const ACTIVE = filter(tk -> isfile(tk.needs), TOOLKITS)
for tk in TOOLKITS
    tk in ACTIVE || @warn "$(tk.name) is not configured on this machine (benchmark/slurm/site.env), skipped"
end

λ(name, m) = m == "cgsense" ? 0.0 : Float64(META["lambda_wavelet"][name])

function solve_cmd(tk, m, nwarm)
    args = [DATADIR, m, string(nwarm), string(NX), string(NY), string(NC), string(MAXIT[m]), string(λ(tk.name, m))]
    return `$(tk.runner) $(joinpath(@__DIR__, tk.script)) $args`
end

# A script prints `nan` for the NRMSE of a run it does not score (BART's, with no further solves).
function parse_result(out)
    m = match(r"RESULT (\S+) (\S+) (\S+) (\S+) (\S+)", out)
    m === nothing && error("no RESULT line in\n$out")
    warm = m[5] == "-" ? Float64[] : parse.(Float64, split(m[5], ","))
    return (import_s = parse(Float64, m[1]), setup_s = parse(Float64, m[2]), first_s = parse(Float64, m[3]), nrmse = parse(Float64, m[4]), warm_s = warm)
end

# Ristretto's solve script builds its reconstruction itself; it must reach the NRMSE the harness's own
# reconstruction reaches (`prepare.jl`), or the two definitions have drifted apart.
function check_ristretto(tk, m, r)
    (tk.name == "Ristretto" && !isnan(r.nrmse)) || return nothing
    ref = META["ristretto_nrmse"][m]
    isapprox(r.nrmse, ref; rtol = 1.0e-3) ||
        error("solve_ristretto.jl reaches NRMSE $(r.nrmse) on $m, the harness's reconstruction $ref: the two definitions differ")
    return nothing
end

# ---------------------------------------------------------------- measuring

raw = Dict{String, Any}()
rec!(keys...; value) = push!(get!(raw, join(keys, "/"), Any[]), value)

# One run of each command first, untimed: page cache, and a precompile check of the Julia envs.
println("warming the file system cache...")
for tk in ACTIVE
    timed(tk.load)
end

# Precompiling Ristretto into a fresh depot ahead of the real one: `compilecache` writes the new
# cache there and finds the dependencies' caches in the real depot. `STARTUP_PRECOMPILE=0` skips it.
precompile_s = get(ENV, "STARTUP_PRECOMPILE", "1") == "0" ? nothing : let depot = mktempdir(DATADIR)
        env = merge(CHILD_ENV, Dict("JULIA_DEPOT_PATH" => depot * ":" * join(DEPOT_PATH, ":")))
        code = "t = @elapsed Base.compilecache(Base.identify_package(\"Ristretto\")); println(\"PRECOMPILE \", t)"
        out = read(setenv(`$PIN $JL -e $code`, env; dir = DATADIR), String)
        rm(depot; recursive = true, force = true)
        t = parse(Float64, match(r"PRECOMPILE (\S+)", out)[1])
        @printf("Ristretto precompile into an empty depot: %.1f s\n", t)
        t
end

for rep in 1:REPS
    println("repetition $rep/$REPS")
    rec!("runtime", "Julia"; value = first(timed(`$JL -e 0`)))
    isfile(PYTHON) && rec!("runtime", "Python"; value = first(timed(`$PYTHON -c pass`)))
    for tk in ACTIVE
        rec!("import", tk.name; value = first(timed(tk.load)))
        for m in tk.methods
            # `nwarm = 0`: the fresh process that loads the toolkit, reads the case and solves once.
            t, out = timed(solve_cmd(tk, m, 0))
            r = parse_result(out)
            check_ristretto(tk, m, r)
            rec!("end_to_end", tk.name, m; value = t)
            rec!("first", tk.name, m; value = r.first_s)
            rec!("setup", tk.name, m; value = r.setup_s)
            isnan(r.nrmse) || rec!("nrmse", tk.name, m; value = r.nrmse)
            rec!("import_in_process", tk.name; value = r.import_s)
            if rep <= WARM_REPS
                _, out = timed(solve_cmd(tk, m, NWARM))
                r = parse_result(out)
                check_ristretto(tk, m, r)
                rec!("first", tk.name, m; value = r.first_s)
                rec!("warm", tk.name, m; value = r.warm_s)
                isnan(r.nrmse) || rec!("nrmse", tk.name, m; value = r.nrmse)
            end
        end
    end
end

# ---------------------------------------------------------------- summary

med(k) = haskey(raw, k) ? median(reduce(vcat, raw[k])) : nothing
summary = Any[]
for tk in ACTIVE, m in tk.methods
    push!(
        summary, Dict(
            "toolkit" => tk.name, "method" => m,
            "runtime_s" => tk.runtime === nothing ? nothing : med("runtime/$(tk.runtime)"),
            "import_s" => med("import/$(tk.name)"),
            "setup_s" => med("setup/$(tk.name)/$m"),
            "first_solve_s" => med("first/$(tk.name)/$m"),
            "warm_solve_s" => med("warm/$(tk.name)/$m"),
            "end_to_end_s" => med("end_to_end/$(tk.name)/$m"),
            "nrmse" => med("nrmse/$(tk.name)/$m"),
        )
    )
end

fmt(x) = x === nothing ? "—" : @sprintf("%.3f", x)
println()
println("| toolkit | method | import s | first solve s | warm solve s | end to end s | NRMSE |")
println("|---|---|--:|--:|--:|--:|--:|")
for s in summary
    println("| $(s["toolkit"]) | $(s["method"]) | $(fmt(s["import_s"])) | $(fmt(s["first_solve_s"])) | $(fmt(s["warm_solve_s"])) | $(fmt(s["end_to_end_s"])) | $(fmt(s["nrmse"])) |")
end

lscpu = Dict(strip(a) => strip(b) for (a, b) in (split(l, ":"; limit = 2) for l in eachline(`lscpu`) if occursin(":", l)))
manifest = TOML.parsefile(joinpath(PROJECT, "Manifest.toml"))["deps"]
pyversions = isfile(PYTHON) ? strip(read(setenv(`$PYTHON -c "import sys, sigpy, mrpro, torch, numpy; print(sys.version.split()[0], sigpy.__version__, mrpro.__version__, torch.__version__, numpy.__version__)"`, CHILD_ENV), String)) : ""
gitref = strip(read(Cmd(`git rev-parse --short HEAD`; dir = REPO), String))

result = Dict(
    "case" => CASE,
    "date" => string(now()),
    "host" => gethostname(),
    "cpu_model" => get(lscpu, "Model name", ""),
    "threads" => THREADS,
    "cpus" => CPUS,
    "numa_node" => NODE,
    "pinning" => string(PIN),
    "julia_version" => string(VERSION),
    "ristretto_commit" => gitref,
    "julia_packages" => Dict(p => get(manifest[p][1], "version", "dev") for p in ("MRIReco", "MIRT") if haskey(manifest, p)),
    "python" => pyversions == "" ? nothing : Dict(zip(("python", "sigpy", "mrpro", "torch", "numpy"), split(pyversions))),
    "bart_version" => isfile(BART) ? strip(read(`$BART version`, String)) : nothing,
    "reps" => REPS, "warm_reps" => WARM_REPS, "nwarm" => NWARM,
    "iterations" => MAXIT,
    "ristretto_precompile_s" => precompile_s,
    "summary" => summary,
    "raw" => raw,
)
open(io -> JSON.print(io, result, 2), OUT, "w")
println("\nwrote $OUT")
