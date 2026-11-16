# Thread-scaling probe: where the wall time of one Ristretto reconstruction goes.
#
#   julia --project=benchmark/comparison -t N benchmark/thread_scaling/probe.jl \
#       --case=shepp_logan_3d_8ch_cartesian --method=tv --out=results/x.json [--variant=NAME]
#
# The reconstruction is the comparison suite's Ristretto row (ristretto_reconstructor), timed with
# the suite's protocol (time_run: one warm-up, FFTW wisdom dropped before every run), then run once
# more under the sampling profiler. Every sample of every Julia thread is put in one category by
# the stack it was taken in (see CATEGORIES), so the category shares of all samples, times the
# wall time and the thread count, are thread-seconds.
#
# Placement comes from outside (numactl in probe.sh); the Julia threads are pinned to the allowed
# physical cores in order, or round-robin over NUMA nodes with PROBE_SPREAD=1.
#
# Variants (--variant), each one change against the default:
#   default           nothing changed
#   cg_blas_grant     ProximalAlgorithms.CG_BLAS_THREAD_BYTES = 8 MiB: CG's dot/axpy! take BLAS threads
#   no_inner_threads  reconstruct(...; threaded = false)
#   gc_off            GC disabled during each timed run (collected between runs)
#   variation_serial  the TV gradient (AbstractOperators' Variation) never threads: its
#                     threading_threshold is raised to typemax(Int) before anything is built
#
# Categories (first match wins): gc, fft_plan, fft, nfft, blas, alloc, prox (proximal maps),
# finite_diff (the TV gradient and its adjoint), solver_vec (the solver's own vector updates, no
# operator on the stack), pointwise (fused element-wise runs, diagonals, broadcasts),
# operators_other, solver_other, idle (thread asleep or in the scheduler), other (mostly
# Polyester workers spin-waiting). "where" lists, per category, the innermost frame in
# Ristretto's own or vendored code, for the main thread and the workers apart.

const ARGD = Dict(split(a[3:end], "="; limit = 2)[1] => (occursin("=", a) ? split(a, "="; limit = 2)[2] : "1") for a in ARGS if startswith(a, "--"))
const CASE = get(ARGD, "case", "shepp_logan_3d_8ch_cartesian")
const METHOD = Symbol(get(ARGD, "method", "tv"))
const VARIANT = get(ARGD, "variant", "default")
const OUT = get(ARGD, "out", "probe.json")
const PROFILE_DELAY = parse(Float64, get(ARGD, "delay", "0.005"))

include(joinpath(@__DIR__, "..", "..", "Ristretto", "benchmark", "utils", "config.jl"))
load_site_env!()
using LinearAlgebra, FFTW, ThreadPinning, JSON, Profile, Dates, Printf

const NT = Threads.nthreads()

# Physical cores allowed to this process, optionally interleaved across NUMA nodes.
function pick_cpus()
    m = match(r"Cpus_allowed_list:\s*(\S+)", read("/proc/self/status", String))
    allowed = Int[]
    for part in split(m.captures[1], ',')
        lo, hi = occursin('-', part) ? split(part, '-') : (part, part)
        append!(allowed, parse(Int, lo):parse(Int, hi))
    end
    phys = filter(!ThreadPinning.ishyperthread, allowed)
    if get(ENV, "PROBE_SPREAD", "0") == "1"
        node_of = Dict{Int, Int}()
        for d in readdir("/sys/devices/system/node"; join = true)
            mm = match(r"node(\d+)$", d)
            mm === nothing && continue
            for part in split(strip(read(joinpath(d, "cpulist"), String)), ',')
                lo, hi = occursin('-', part) ? split(part, '-') : (part, part)
                for c in parse(Int, lo):parse(Int, hi)
                    node_of[c] = parse(Int, mm.captures[1])
                end
            end
        end
        groups = [filter(c -> node_of[c] == n, phys) for n in sort(unique(node_of[c] for c in phys))]
        rr = Int[]
        i = 1
        while length(rr) < length(phys)
            for g in groups
                i <= length(g) && push!(rr, g[i])
            end
            i += 1
        end
        phys = rr
    end
    length(phys) >= NT || error("only $(length(phys)) physical cores allowed, $NT threads")
    return phys[1:NT]
end
const CPUS = pick_cpus()
pinthreads(CPUS)
BLAS.set_num_threads(NT)
FFTW.set_num_threads(NT)

using Ristretto
include(joinpath(@__DIR__, "..", "..", "Ristretto", "benchmark", "utils", "bench_utils.jl"))
using .BenchUtils

const PA = Ristretto.ProximalAlgorithms
VARIANT == "cg_blas_grant" && (PA.CG_BLAS_THREAD_BYTES[] = 8 * 2^20)
if VARIANT == "variation_serial"
    @eval Ristretto.AbstractOperators.threading_threshold(::Type{<:Ristretto.AbstractOperators.Variation}) = typemax(Int)
end

c = get_case(CASE)
acq = ristretto_acquisition(c)
f0 = ristretto_reconstructor(c, METHOD; acq)
f = if VARIANT == "no_inner_threads"
    method = METHOD
    reg = method === :cgsense ? () : ristretto_regularizer(c, method, default_lambda(c, method))
    m = IterativeReconstruction(; regularization = reg, algorithm = ristretto_algorithm(method, default_maxit(method); rho = admm_rho(c)), maxit = default_maxit(method), reltol = 0.0)
    () -> reconstruct(acq, m; verbosity = Silent(), threaded = false)
elseif VARIANT == "gc_off"
    () -> (GC.enable(false); try f0() finally GC.enable(true) end)
else
    f0
end

# --- timing, the suite's protocol --------------------------------------------------------------
gc0 = Base.gc_num()
t_wall = @elapsed tmin, tmed, img = time_run(f; runs = timed_runs(c))
gcd = Base.GC_Diff(Base.gc_num(), gc0)
nrmse = BenchUtils.mag_nrmse(img, c.reference)

# one more run, for GC and allocation totals of a single solve
GC.gc()
FFTW.forget_wisdom()
st = @timed f()

# --- profile ------------------------------------------------------------------------------------
Profile.init(n = 10^8, delay = PROFILE_DELAY)
Profile.clear()
FFTW.forget_wisdom()
t_prof = @elapsed @profile f()
data = Profile.fetch(; include_meta = true)

const CATEGORIES = [
    # (name, predicate over the frames of one sample), first match wins
    "gc" => fr -> any(s -> occursin(r"jl_gc_collect|gc_collect|jl_gc_mark|gc_sweep|_jl_gc_collect|gc_mark_loop", s.func_s), fr),
    "fft_plan" => fr -> any(s -> occursin(r"fftwf?_plan|plan_fft|plan_bfft|plan_ifft|_plan_|cFFTWPlan", s.func_s) , fr),
    "fft" => fr -> any(s -> occursin(r"fftwf?_execute|unsafe_execute!|spawnloop", s.func_s), fr),
    "nfft" => fr -> any(s -> occursin("NFFT", s.file_s), fr),
    "blas" => fr -> any(s -> occursin(r"libopenblas|libmkl", s.file_s) || occursin(r"^(c|z|s|d)(axpy|dot|scal|nrm2|copy)|_k$|axpy!|dotc|BLAS\.", s.func_s), fr),
    "alloc" => fr -> any(s -> occursin(r"jl_gc_alloc|jl_alloc_genericmemory|jl_alloc_array|_new_genericmemory|ijl_gc_|malloc|calloc|memset|__memset|jl_gc_pool_alloc|jl_gc_big_alloc", s.func_s), fr),
    "prox" => fr -> any(s -> occursin("ProximalOperators", s.file_s), fr),
    "finite_diff" => fr -> any(s -> occursin(r"Variation\.jl|FiniteDiff\.jl", s.file_s), fr),
    "solver_vec" => fr -> any(s -> occursin(r"ProximalAlgorithms|StructuredOptimization", s.file_s), fr) &&
        !any(s -> occursin(r"AbstractOperators|FFTWOperators|NFFT", s.file_s), fr),
    "pointwise" => fr -> any(s -> occursin(r"pointwise\.jl|DiagOp\.jl|broadcast\.jl", s.file_s), fr),
    "operators_other" => fr -> any(s -> occursin(r"AbstractOperators|FFTWOperators", s.file_s), fr),
    "solver_other" => fr -> any(s -> occursin(r"ProximalAlgorithms|StructuredOptimization", s.file_s), fr),
    "idle" => fr -> isempty(fr) || any(s -> occursin(r"jl_task_wait|ijl_task_get_next|poptask|jl_safepoint|wait_forever|task_done_hook|jl_wait|uv_run|sched_yield|futex|pthread_cond|epoll", s.func_s), fr),
]

const LOOKUP = Dict{UInt64, Vector{NamedTuple{(:func_s, :file_s, :line), Tuple{String, String, Int}}}}()
function frames(ip)
    get!(LOOKUP, ip) do
        [(func_s = string(s.func), file_s = string(s.file), line = s.line) for s in Profile.lookup(ip)]
    end
end

# Profile.jl's raw buffer: each sample is its instruction pointers, then the metadata
# (META_OFFSET_* from the end), then two zeros.
function samples(data)
    out = Tuple{Int, Bool, Vector{UInt64}}[]
    i = 1
    n = length(data)
    start = 1
    while i <= n
        if i < n && data[i] == 0 && data[i + 1] == 0
            last = i + 1
            tid = Int(data[last - Profile.META_OFFSET_THREADID])
            sleeping = data[last - Profile.META_OFFSET_SLEEPSTATE] == 2
            ips = data[start:(last - Profile.nmeta - 2)]
            push!(out, (tid, sleeping, ips))
            i = last + 1
            start = i
        else
            i += 1
        end
    end
    return out
end

# The innermost frame of the stack that lies in Ristretto or one of its vendored packages, as
# func @ file:line: where in the reconstruction's own code a sample was spent.
function attribution_frame(fr)
    for s in fr
        if occursin(r"/(src|deps|ext)/", s.file_s) && occursin(r"Ristretto|AbstractOperators|FFTWOperators|ProximalOperators|ProximalAlgorithms|StructuredOptimization|NestedThreading|NFFT", s.file_s)
            m = match(r"(deps/[^/]+/.*|src/.*|ext/.*)$", s.file_s)
            return s.func_s * " @ " * (m === nothing ? basename(s.file_s) : m.captures[1]) * ":" * string(s.line)
        end
    end
    return isempty(fr) ? "(empty)" : fr[end].func_s
end
where_t = Dict{String, Dict{String, Int}}()
S = samples(data)
counts = Dict{Int, Dict{String, Int}}()
other_leaf = Dict{String, Int}()
for (tid, sleeping, ips) in S
    fr = reduce(vcat, (frames(ip) for ip in ips); init = NamedTuple{(:func_s, :file_s, :line), Tuple{String, String, Int}}[])
    cat = sleeping ? "idle" : "other"
    if !sleeping
        for (name, pred) in CATEGORIES
            if pred(fr)
                cat = name
                break
            end
        end
    end
    if cat != "idle" && cat != "gc"
        k = attribution_frame(fr)
        dd = get!(where_t, (tid == 1 ? "main" : "workers") * ":" * cat, Dict{String, Int}())
        dd[k] = get(dd, k, 0) + 1
    end
    if cat == "other" && !isempty(fr)
        k = fr[1].func_s * " @ " * basename(fr[1].file_s)
        other_leaf[k] = get(other_leaf, k, 0) + 1
    end
    d = get!(counts, tid, Dict{String, Int}())
    d[cat] = get(d, cat, 0) + 1
end

# Julia threads 1 .. nthreads(:interactive) + nthreads(:default) run tasks; the profiler also
# samples the GC's own threads, which are counted apart.
const NCOMPUTE = Threads.nthreads(:interactive) + Threads.nthreads(:default)
total = Dict{String, Int}()
for (tid, d) in counts, (k, v) in d
    tid <= NCOMPUTE || continue
    total[k] = get(total, k, 0) + v
end
nsamp = sum(values(total); init = 0)
thread_seconds = Dict(k => v / nsamp * t_prof * NCOMPUTE for (k, v) in total)

# --- provenance ----------------------------------------------------------------------------------
_sh(cmd) = try strip(read(pipeline(cmd; stderr = devnull), String)) catch; "" end
rdir = normpath(joinpath(@__DIR__, "..", "..", "Ristretto"))
function subtree_split(p)
    msg = _sh(`git -C $rdir log -1 --format=%B --grep=git-subtree-dir:.deps/$p`)
    m = match(r"git-subtree-split:\s*(\S+)", msg)
    return m === nothing ? "" : m.captures[1]
end
subtree = Dict(p => subtree_split(p) for p in ("AbstractOperators", "ProximalOperators", "ProximalAlgorithms", "StructuredOptimization", "OperatorCore", "NFFT"))

res = Dict(
    "case" => CASE, "method" => string(METHOD), "variant" => VARIANT, "threads" => NT,
    "time_min_s" => tmin, "time_median_s" => tmed, "nrmse" => nrmse,
    "single_run" => Dict("time_s" => st.time, "gc_s" => st.gctime, "bytes" => st.bytes, "compile_s" => st.compile_time),
    "profile" => Dict("wall_s" => t_prof, "delay_s" => PROFILE_DELAY, "samples" => nsamp,
        "share" => Dict(k => v / nsamp for (k, v) in total), "thread_seconds" => thread_seconds,
        "per_thread" => Dict(string(k) => v for (k, v) in counts),
        "other_top" => first(sort(collect(other_leaf); by = last, rev = true), min(25, length(other_leaf))),
        "compute_threads" => NCOMPUTE,
        "where" => Dict(k => first(sort(collect(v); by = last, rev = true), min(15, length(v))) for (k, v) in where_t)),
    "provenance" => Dict(
        "ristretto" => BenchUtils.git_ref(rdir), "benchmarking" => BenchUtils.git_ref(normpath(joinpath(@__DIR__, "..", ".."))),
        "deps_subtree_split" => subtree, "host" => gethostname(), "node_class" => BenchUtils.node_class(),
        "slurm_job" => get(ENV, "SLURM_JOB_ID", ""), "cpus" => CPUS, "spread" => get(ENV, "PROBE_SPREAD", "0"),
        "numactl" => _sh(`numactl --show`), "julia" => string(VERSION),
        "blas" => string(BLAS.get_config()), "blas_threads" => BLAS.get_num_threads(), "fftw_threads" => FFTW.get_num_threads(),
        "fftw_provider" => FFTW.get_provider(), "env" => BenchUtils.recorded_env(), "date" => string(now()),
        "small" => get(ENV, "RISTRETTO_BENCH_SMALL", ""),
    ),
)
mkpath(dirname(abspath(OUT)))
open(io -> JSON.print(io, res, 2), OUT, "w")
@printf("%s %s %s T=%d  min %.2f s  median %.2f s  nrmse %.4f  gc %.2f s  alloc %.1f GB
", CASE, METHOD, VARIANT, NT, tmin, tmed, nrmse, st.gctime, st.bytes / 1e9)
for (k, v) in sort(collect(thread_seconds); by = last, rev = true)
    @printf("  %-16s %6.1f%%  %8.2f thread-s
", k, 100 * total[k] / nsamp, v)
end
