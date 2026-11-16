# Kernel-level numbers behind probe.jl, on the arrays of the 3D catalog case (128³ image, 8 coils,
# ComplexF32), at the thread count the process was started with:
#   - memory bandwidth of a threaded copy of one 128³×8 array (134 MB each way)
#   - one batched 3D FFT of all 8 coils, FFTW threads = nthreads (MEASURE plan)
#   - the same 8 FFTs as 8 single-threaded 3D plans run concurrently, one per task (a loop over
#     coils, as BART structures it)
#   - CG's level-1 updates on a 128³×8 vector: axpy! and dot, serial and threaded BLAS
#
#   julia --project=benchmark/comparison -t N benchmark/thread_scaling/kernels.jl --out=x.json
using LinearAlgebra, FFTW, ThreadPinning, JSON, Dates, Statistics
const ARGD = Dict(split(a[3:end], "="; limit = 2)[1] => split(a, "="; limit = 2)[2] for a in ARGS if startswith(a, "--") && occursin("=", a))
const NT = Threads.nthreads()
let m = match(r"Cpus_allowed_list:\s*(\S+)", read("/proc/self/status", String)), allowed = Int[]
    for part in split(m.captures[1], ',')
        lo, hi = occursin('-', part) ? split(part, '-') : (part, part)
        append!(allowed, parse(Int, lo):parse(Int, hi))
    end
    phys = filter(!ThreadPinning.ishyperthread, allowed)
    global const CPUS = phys[1:NT]
end
pinthreads(CPUS)

best(f; n = 7) = (f(); minimum(@elapsed(f()) for _ in 1:n))

n, nc = 128, 8
x = rand(ComplexF32, n, n, n, nc)
y = similar(x)
res = Dict{String, Any}("threads" => NT, "cpus" => CPUS, "host" => gethostname(), "date" => string(now()))

function tcopy!(y, x)
    chunks = collect(Iterators.partition(eachindex(x, y), cld(length(x), NT)))
    Threads.@threads :static for r in chunks
        for i in r
            y[i] = x[i]
        end
    end
end
t = best(() -> tcopy!(y, x))
res["copy_GBps"] = 2 * sizeof(x) / t / 1e9

FFTW.set_num_threads(NT)
p = plan_fft!(y, 1:3; flags = FFTW.MEASURE)
copyto!(y, x)
res["fft_batched_ms"] = 1000 * best(() -> p * y)

FFTW.set_num_threads(1)
ys = [y[:, :, :, k] for k in 1:nc]
ps = [plan_fft!(ys[k], 1:3; flags = FFTW.MEASURE) for k in 1:nc]
res["fft_percoil_tasks_ms"] = 1000 * best(() -> begin
    Threads.@threads :dynamic for k in 1:nc
        ps[k] * ys[k]
    end
end)
res["fft_percoil_serial_ms"] = 1000 * best(() -> foreach(k -> ps[k] * ys[k], 1:nc))

v, w = vec(x), vec(y)
for (lab, nb) in (("blas1", 1), ("blasN", NT))
    BLAS.set_num_threads(nb)
    res["axpy_ms_" * lab] = 1000 * best(() -> axpy!(0.5f0, v, w))
    res["dot_ms_" * lab] = 1000 * best(() -> dot(v, w))
end
res["blas"] = string(BLAS.get_config())
out = get(ARGD, "out", "kernels.json")
mkpath(dirname(abspath(out)))
open(io -> JSON.print(io, res, 2), out, "w")
println(res)
