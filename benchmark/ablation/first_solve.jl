# First solve in a fresh process: the time to load the comparison environment (Ristretto included)
# and to run one reconstruction, compilation included. Run once with Ristretto's precompile
# workload (the default) and once with `precompile_workload = false` (PrecompileTools'
# preference, set in a copy of the environment by ablation.sh) to time what the workload saves.
#
#   julia --project=<env> -t N benchmark/ablation/first_solve.jl --case=<id> --method=<m> --out=<file.json>

const T0 = time()
const ARGD = Dict(split(a[3:end], "="; limit = 2)[1] => (occursin("=", a) ? split(a, "="; limit = 2)[2] : "1") for a in ARGS if startswith(a, "--"))
const T_LOAD = @elapsed begin
    include(joinpath(@__DIR__, "..", "..", "Ristretto", "benchmark", "utils", "config.jl"))
    load_site_env!()
    using Ristretto
    include(joinpath(@__DIR__, "..", "..", "Ristretto", "benchmark", "utils", "bench_utils.jl"))
    using .BenchUtils
end
using JSON, Dates
c = get_case(ARGD["case"])
method = Symbol(ARGD["method"])
f = ristretto_reconstructor(c, method)
t_first = @elapsed img = f()
t_second = @elapsed f()
prefs = Base.get_preferences(Base.PkgId(Ristretto).uuid)
open(ARGD["out"], "w") do io
    JSON.print(
        io, Dict(
            "case" => c.id, "method" => String(method), "threads" => Threads.nthreads(),
            "load_s" => T_LOAD, "first_solve_s" => t_first, "second_solve_s" => t_second,
            "process_s" => time() - T0, "nrmse_gt" => BenchUtils.mag_nrmse(Array(img), c.reference),
            "precompile_workload" => get(prefs, "precompile_workload", true),
            "project" => Base.active_project(), "depot" => DEPOT_PATH,
            "host" => gethostname(), "slurm_job" => get(ENV, "SLURM_JOB_ID", ""), "date" => string(now()),
        ), 2
    )
end
