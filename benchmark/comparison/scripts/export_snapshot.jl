# Write the committed snapshot: `results/benchmark_<backend>_<n>threads.json`, one per (backend,
# threads) pair found in `results/runs/`, each holding the latest `source = "slurm"` row per (case,
# category, method, framework). The snapshot is the reviewable, versioned record of a full cluster
# run; `results/runs/` itself is local working data. There is no merge of raw fragments, only a
# query (`ResultsStore.latest_per_case`) written out to a stable filename.
#
# Snapshot schema 3 adds a `run` record next to the rows: when the rows were measured, on which
# hardware (CPU model and thread count, GPU), Julia version and BLAS library, gathered from the
# run files the rows come from. Runs recorded before the harness stored the CPU model take it from
# `--cpu-model` (`AMD EPYC 7763` for the cluster the committed snapshots come from).
#
#   julia --project=benchmark/comparison benchmark/comparison/scripts/export_snapshot.jl
#   julia --project=benchmark/comparison benchmark/comparison/scripts/export_snapshot.jl --backend=mkl --threads=16
#   julia --project=benchmark/comparison benchmark/comparison/scripts/export_snapshot.jl --cpu-model="AMD EPYC 7763 64-Core Processor"
#   julia --project=benchmark/comparison benchmark/comparison/scripts/export_snapshot.jl --machine=workstation --host=<hostname>
#
# Without `--machine`, the cluster's rows (`source = "slurm"`) go to `results/`. With it, the rows run on
# one other computer (`source = "other"`, recorded on host `--host`) go to `results/machines/<machine>/`,
# which the site shows as a machine of its own.
using JSON

include(joinpath(@__DIR__, "..", "..", "..", "Ristretto", "benchmark", "utils", "results_store.jl"))
using .ResultsStore: load_rows, latest_per_case, load_run_files
const RESULTS_DIR = normpath(joinpath(@__DIR__, "..", "results"))

const SNAPSHOT_SCHEMA_VERSION = 3

const ARG = Dict(
    m.captures[1] => m.captures[2] for m in (match(r"^--([\w-]+)=(.*)$", a) for a in ARGS) if m !== nothing
)

const RUN_FILES = load_run_files(RESULTS_DIR)
rows = load_rows(RUN_FILES)
isempty(rows) && (@info "no rows in results/runs/ -- nothing to export"; exit(0))

# The metadata of every run file, by run id: what a row records of its run.
const RUNS = Dict(get(d, "run_id", "") => d for d in RUN_FILES)

const MACHINE = get(ARG, "machine", nothing)
const OUT_DIR = MACHINE === nothing ? RESULTS_DIR : joinpath(RESULTS_DIR, "machines", MACHINE)
const SOURCE = MACHINE === nothing ? "slurm" : "other"
if MACHINE !== nothing
    haskey(ARG, "host") || error("--machine=$MACHINE needs --host=<hostname of that machine's run files>")
    filter!(r -> r.source == SOURCE && get(get(RUNS, r.run_id, Dict{String, Any}()), "hostname", "") == ARG["host"], rows)
end

haskey(ARG, "backend") && filter!(r -> r.backend == ARG["backend"], rows)
haskey(ARG, "threads") && filter!(r -> r.threads == parse(Int, ARG["threads"]), rows)

values_of(metas, key) = sort(unique(string(m[key]) for m in metas if get(m, key, nothing) !== nothing))
date_of(ts) = "$(ts[1:4])-$(ts[5:6])-$(ts[7:8])"

# The versions of the runs recorded before the harness stored them, per backend family.
const INJECTED_VERSIONS = JSON.parsefile(joinpath(RESULTS_DIR, "toolkit_versions.json"))

# A row's toolkit is the first word of its framework label; its version is the one its run
# recorded, or for a run that recorded none, the injected one.
toolkit(r) = first(split(r.framework))
function toolkit_version(r)
    recorded = get(get(RUNS, r.run_id, Dict{String, Any}()), "toolkit_versions", nothing)
    recorded === nothing && (recorded = INJECTED_VERSIONS[r.backend == "cuda" ? "cuda" : "cpu"])
    v = get(recorded, toolkit(r), nothing)
    return v === nothing ? nothing : string(v)
end
# A Ristretto version carries the commit it was measured at; the release is what identifies it.
release(v) = replace(v, r" \(.*\)$" => "")

# A toolkit's rows measured with an older release than its latest run's are left out, also where
# the latest release recorded no row for the case (a solver that no longer reaches the accuracy
# target, say): a table would otherwise mix releases and show a time the current one cannot reach.
function current_release_rows(rows)
    newest = Dict{Tuple{String, String}, Tuple{String, String}}()
    for r in rows
        v = toolkit_version(r)
        v === nothing && continue
        key = (r.backend == "cuda" ? "cuda" : "cpu", toolkit(r))
        (!haskey(newest, key) || r.ts > newest[key][1]) && (newest[key] = (r.ts, release(v)))
    end
    return filter(rows) do r
        v = toolkit_version(r)
        key = (r.backend == "cuda" ? "cuda" : "cpu", toolkit(r))
        v === nothing || !haskey(newest, key) || release(v) == newest[key][2]
    end
end

# A run restricted to some competitors (`--frameworks=`) still times Ristretto, as the reference
# its rows are compared against; those Ristretto rows are a by-product of the competitors' rerun,
# not a measurement of Ristretto, and are left out.
function measured(r)
    patterns = get(get(RUNS, r.run_id, Dict{String, Any}()), "frameworks_filter", nothing)
    return patterns === nothing || any(p -> occursin(p, lowercase(r.framework)), patterns)
end

# The cases some run scored by held-out k-space prediction (`HELDOUT_CASES` in _setup.jl). A row of
# such a case from a run that scored it otherwise (an image NRMSE, recorded before the case had held-
# out scoring) is left out, also where no newer row replaces it, so one column never mixes metrics.
const HELDOUT = Set(String(id) for d in RUN_FILES for id in get(d, "heldout_cases", String[]))
function same_metric(r)
    r.case_id in HELDOUT || return true
    return r.case_id in get(get(RUNS, r.run_id, Dict{String, Any}()), "heldout_cases", String[])
end

# Cases the harness no longer runs (`EXCLUDED_CASES` in _setup.jl); their recorded rows are left out.
const EXCLUDED_CASES = ("real_cine_multichannel_radial",)
# Cases the accuracy race no longer runs (`EXCLUDED_RACE_CASES` in _setup.jl); their recorded race rows
# are left out.
const EXCLUDED_RACE_CASES = ("real_2d_1ch_cartesian",)
excluded_race(r) = r.category == "Accuracy race" && r.case_id in EXCLUDED_RACE_CASES

latest = latest_per_case(
    current_release_rows(filter(r -> !(r.case_id in EXCLUDED_CASES) && !excluded_race(r) && measured(r) && same_metric(r), rows));
    prefer_source = SOURCE,
)
isempty(latest) && (@info "no source=\"$SOURCE\" rows match; nothing exported"; exit(0))

# A snapshot's BART GPU time is the whole `pics -g` call, CUDA start-up included. Runs that record
# `bart_gpu_init_s` measured it that way. Older runs subtracted a start-up estimate made once per section
# process (`BART_GPU_INIT`), which varied between processes by more than many solves take; their
# estimate is added back. Those run files do not record it; each section process logs it before the run
# files it writes, so it is read from the job logs under `--logs` (default `benchmark/results/`). Where
# the older harness clamped a call shorter than its estimate, only that bound is known: the row's time
# is the estimate and `bart_gpu_upper_bound` is true.
const LOG_DIR = get(ARG, "logs", normpath(joinpath(RESULTS_DIR, "..", "..", "results")))
function bart_gpu_startups(dir)
    out = Dict{String, Float64}()
    isdir(dir) || return out
    for (root, _, files) in walkdir(dir), f in files
        (endswith(f, ".txt") || endswith(f, ".log")) || continue
        init = nothing
        for line in eachline(joinpath(root, f))
            m = match(r"BART GPU initialisation: ([\d.]+) ms", line)
            m === nothing || (init = parse(Float64, m.captures[1]); continue)
            m = match(r"path = \"(.*/runs/([^/\"]+)\.json)\"", line)
            (m === nothing || init === nothing) || (out[m.captures[2]] = init)
        end
    end
    return out
end
is_bart_gpu(r) = r.backend == "cuda" && startswith(r.framework, "BART")
whole_call(r) = haskey(get(RUNS, r.run_id, Dict{String, Any}()), "bart_gpu_init_s")
const BART_GPU_STARTUP = any(r -> is_bart_gpu(r) && !whole_call(r), latest) ? bart_gpu_startups(LOG_DIR) : Dict{String, Float64}()
for r in latest
    is_bart_gpu(r) && !whole_call(r) && !haskey(BART_GPU_STARTUP, r.run_id) &&
        error("no logged BART GPU start-up for run $(r.run_id) under $LOG_DIR (pass --logs=<dir of the job logs>)")
end

function row_record(r)
    d = Dict{String, Any}(
        "case_id" => r.case_id, "data_source" => r.data_source,
        "category" => r.category, "method" => r.method, "framework" => r.framework,
        "threads" => r.threads, "time_ms" => r.time_ms,
        "nrmse_gt" => r.nrmse_gt, "nrmse_ristretto" => r.nrmse_ristretto,
    )
    if is_bart_gpu(r) && !whole_call(r)
        s = BART_GPU_STARTUP[r.run_id]
        clamped = r.time_ms <= 0.01
        d["time_ms"] = clamped ? s : r.time_ms + s
        clamped && (d["bart_gpu_upper_bound"] = true)
    end
    return d
end

# Per toolkit, the versions of the runs behind its rows.
function toolkit_versions(section_rows)
    out = Dict{String, Vector{String}}()
    for r in section_rows
        v = toolkit_version(r)
        v === nothing || union!(get!(out, toolkit(r), String[]), [v])
    end
    return Dict(k => sort(v) for (k, v) in out)
end

function run_record(section_rows)
    metas = [RUNS[r.run_id] for r in section_rows if haskey(RUNS, r.run_id)]
    dates = sort(unique(date_of(r.ts) for r in section_rows))
    cpu = values_of(metas, "cpu_model")
    isempty(cpu) && haskey(ARG, "cpu-model") && (cpu = [ARG["cpu-model"]])
    return Dict(
        "dates" => [first(dates), last(dates)],
        "cpu_model" => cpu,
        "cpu_threads" => values_of(metas, "cpu_threads"),
        "gpu" => values_of(metas, "gpu"),
        "hostnames" => values_of(metas, "hostname"),
        "julia_version" => values_of(metas, "julia_version"),
        "blas_vendor" => unique(basename.(values_of(metas, "blas_vendor"))),
        "toolkit_versions" => toolkit_versions(section_rows),
        "heldout_cases" => sort(unique(r.case_id for r in section_rows if r.case_id in HELDOUT)),
    )
end

for backend in sort(unique(r.backend for r in latest))
    for threads in sort(unique(r.threads for r in latest if r.backend == backend))
        section_rows = filter(r -> r.backend == backend && r.threads == threads, latest)
        isempty(section_rows) && continue
        mkpath(OUT_DIR)
        path = joinpath(OUT_DIR, "benchmark_$(backend)_$(threads)threads.json")
        open(path, "w") do io
            JSON.print(
                io,
                Dict(
                    "backend" => backend, "threads" => threads, "schema_version" => SNAPSHOT_SCHEMA_VERSION,
                    "run" => run_record(section_rows),
                    "benchmarks" => [
                        row_record(r) for r in sort(section_rows; by = r -> (r.case_id, r.category, r.method, r.framework))
                    ],
                ),
                4,
            )
        end
        @info "exported" path n = length(section_rows)
    end
end
