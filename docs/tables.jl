# Markdown tables for the site, generated when the site is built from the result files committed in
# this repository. Nothing here measures anything: re-exporting a snapshot or adding a result file
# changes the pages without touching their prose.
module Tables

using JSON: JSON
using Markdown: Markdown
using Printf: @sprintf

const ROOT = normpath(joinpath(@__DIR__, ".."))
const BENCH = joinpath(ROOT, "benchmark")
const RESULTS = joinpath(BENCH, "comparison", "results")
const REPO = "https://github.com/hakkelt/RistrettoBenchmarking/blob/master/"

const TOOLKITS = ("Ristretto", "BART", "BART (MEASURE)", "SigPy", "MRIReco", "MIRT", "MRpro")
toolkit_rank(t) = something(findfirst(==(t), collect(TOOLKITS)), 99)

# ------------------------------------------------------------------ formatting

function fmt_ms(t)
    t < 0 && return "n/m"
    t < 10 && return @sprintf("%.2f ms", t)
    t < 1000 && return @sprintf("%.0f ms", t)
    t < 100_000 && return @sprintf("%.2f s", t / 1000)
    return @sprintf("%.0f s", t / 1000)
end
fmt_s(t) = t === nothing ? "—" : fmt_ms(1000 * t)
fmt_err(e) = e === nothing || e < 0 ? "" : e < 1.0e-3 ? @sprintf("%.1e", e) : @sprintf("%.3f", e)
fmt_x(r) = @sprintf("%.2f×", r)

function md_table(header, rows; align = ["---"; fill("---:", length(header) - 1)])
    io = IOBuffer()
    println(io, "| ", join(header, " | "), " |")
    println(io, "|", join(align, "|"), "|")
    for r in rows
        println(io, "| ", join(r, " | "), " |")
    end
    return String(take!(io))
end

# A collapsed block (Documenter's "details" admonition).
details(title, body) = "!!! details \"$title\"\n" * join(("    " * l for l in split(body, '\n')), '\n') * "\n\n"

link(path, text = path) = "[$text]($(REPO)$(path))"
code(x) = "`$(x)`"

# ------------------------------------------------------------------ cases

const CASES = [
    "shepp_logan_2d_1ch_cartesian" => "Shepp–Logan 2D, 1 coil, Cartesian",
    "shepp_logan_2d_8ch_cartesian" => "Shepp–Logan 2D, 8 coils, Cartesian",
    "shepp_logan_2d_8ch_cartesian__regular" => "Shepp–Logan 2D, 8 coils, Cartesian, regular undersampling",
    "shepp_logan_2d_8ch_radial" => "Shepp–Logan 2D, 8 coils, radial",
    "shepp_logan_multislice_8ch_cartesian" => "Shepp–Logan multi-slice, 8 coils, Cartesian",
    "shepp_logan_multislice_8ch_cartesian__regular" => "Shepp–Logan multi-slice, 8 coils, Cartesian, regular undersampling",
    "shepp_logan_3d_8ch_cartesian" => "Shepp–Logan 3D, 8 coils, Cartesian",
    "torso_cine_8ch_cartesian" => "torso cine, 8 coils, Cartesian",
    "torso_cine_8ch_radial" => "torso cine, 8 coils, radial",
    "real_2d_1ch_cartesian" => "knee 2D, 1 coil, Cartesian (fastMRI)",
    "real_2d_multichannel_cartesian" => "brain 2D, multi-coil, Cartesian (M4Raw)",
    "real_2d_multichannel_radial" => "breast 2D, multi-coil, radial (fastMRI breast)",
    "real_multislice_multichannel_cartesian" => "brain multi-slice, multi-coil, Cartesian (M4Raw)",
    "real_3d_multichannel_cartesian" => "knee 3D, multi-coil, Cartesian (mridata.org)",
    "real_cine_multichannel_cartesian" => "cardiac cine, multi-coil, Cartesian (OCMR)",
]
case_label(id) = (i = findfirst(p -> p.first == id, CASES); i === nothing ? id : CASES[i].second)
case_rank(id) = (something(findfirst(p -> p.first == id, CASES), 99), id)
is_real(id) = startswith(id, "real_")

const METHOD_NAMES = Dict(
    "tv" => "TV (ADMM)", "atv" => "anisotropic TV (ADMM)", "tv_pd" => "TV (PDHG)", "atv_pd" => "anisotropic TV (PDHG)",
    "tgv" => "TGV", "wavelet" => "ℓ₁-wavelet", "lowrank" => "global low rank", "llr" => "locally low rank",
    "ttv" => "temporal TV (ADMM)", "ttv_pd" => "temporal TV (PDHG)", "cgsense" => "CG-SENSE",
)
method_name(m) = get(METHOD_NAMES, m, m)

# ------------------------------------------------------------------ snapshots

# A machine's snapshots: the cluster's in benchmark/comparison/results/, any other computer's in
# benchmark/comparison/results/machines/<name>/ (export_snapshot.jl --machine=<name>).
struct Snapshot
    machine::String
    backend::String
    threads::Int
    path::String
end

const CLUSTER = "Komondor"
# The MKL snapshots in the repository were measured with older toolbox releases than the rest, so
# the site shows the OpenBLAS and GPU ones only.
const SHOWN_BACKENDS = ("openblas", "cuda")

function snapshots_in(dir, machine)
    out = Snapshot[]
    isdir(dir) || return out
    for f in readdir(dir)
        m = match(r"^benchmark_(\w+)_(\d+)threads\.json$", f)
        (m === nothing || !(m.captures[1] in SHOWN_BACKENDS)) && continue
        push!(out, Snapshot(machine, m.captures[1], parse(Int, m.captures[2]), joinpath(dir, f)))
    end
    return sort!(out; by = s -> (s.backend == "cuda", s.threads))
end

function snapshots()
    out = snapshots_in(RESULTS, CLUSTER)
    mdir = joinpath(RESULTS, "machines")
    isdir(mdir) && for m in sort(readdir(mdir))
        append!(out, snapshots_in(joinpath(mdir, m), m))
    end
    return out
end

machines() = unique(s.machine for s in snapshots())
other_machines() = filter(!=(CLUSTER), machines())
cpu_snapshots(machine) = filter(s -> s.machine == machine && s.backend != "cuda", snapshots())
gpu_snapshots(machine) = filter(s -> s.machine == machine && s.backend == "cuda", snapshots())

const _CACHE = Dict{String, Any}()
load(s::Snapshot) = get!(() -> JSON.parsefile(s.path), _CACHE, s.path)
rows(s::Snapshot) = load(s)["benchmarks"]
run_record(s::Snapshot) = get(load(s), "run", Dict{String, Any}())
heldout_cases(s::Snapshot) = get(run_record(s), "heldout_cases", String[])

device_label(s::Snapshot) = s.backend == "cuda" ? "GPU" : "$(s.threads) thread" * (s.threads == 1 ? "" : "s")

# "Ristretto (OpenBLAS)" is column Ristretto, "BART (OpenBLAS, MEASURE)" column "BART (MEASURE)",
# "SigPy (CUDA)" column SigPy. A variant such as "Ristretto (OpenBLAS) (m=3, σ=1.25)" goes in
# Ristretto's column, on a row of its own.
function split_framework(label)
    m = match(r"^(\w+)(?: \((?:OpenBLAS|MKL|CUDA)(, MEASURE)?\))?(?: \((.*)\))?$", label)
    m === nothing && return (label, "")
    return (m.captures[1] * (m.captures[2] === nothing ? "" : " (MEASURE)"), something(m.captures[3], ""))
end

# "Total Variation (NRMSE≤0.0805, 80 it)" -> ("Total Variation", 0.0805, 80)
function race_parts(method)
    m = match(r"^(.*) \(NRMSE≤([\d.eE+-]+), (\d+) it\)$", method)
    m === nothing && return (method, nothing, nothing)
    return (m.captures[1], parse(Float64, m.captures[2]), parse(Int, m.captures[3]))
end
budget_base(method) = replace(method, r" \(\d+ it\)$" => "")

# ------------------------------------------------------------------ provenance

joinv(x) = x isa AbstractVector ? join(x, ", ") : string(x)

"""
    provenance(s) -> String

Where and when snapshot `s` was measured, from its run record.
"""
function provenance(s::Snapshot)
    r = run_record(s)
    isempty(r) && return "*No run record.*"
    cpu = joinv(get(r, "cpu_model", "unrecorded CPU"))
    gpu = isempty(get(r, "gpu", [])) ? "" : ", $(joinv(r["gpu"]))"
    nodes = length(get(r, "hostnames", []))
    cores = join(get(r, "cpu_threads", []), " or ")
    dates = unique(get(r, "dates", ["?"]))
    blas = join(unique(replace(b, r"^lib(\w+?)(64_)?\.so.*$" => s"\1") for b in get(r, "blas_vendor", [])), ", ")
    place = s.backend == "cuda" ? "1 host thread" :
        "$(s.threads) thread" * (s.threads == 1 ? "" : "s") * (s.machine == CLUSTER ? " in one NUMA domain" : "")
    return "$(s.machine): $cpu$gpu; $place; $nodes node" * (nodes == 1 ? "" : "s") *
        (isempty(cores) ? "" : " with $cores hardware threads") *
        "; Julia $(joinv(get(r, "julia_version", "?"))), $blas; measured $(join(dates, " to "))."
end

function versions_line(s::Snapshot)
    v = get(run_record(s), "toolkit_versions", Dict())
    isempty(v) && return ""
    return "Versions: " * join(("$k $(joinv(v[k]))" for k in sort!(collect(keys(v)); by = toolkit_rank)), "; ") * "."
end

header(s::Snapshot) = "*" * provenance(s) * "* " * versions_line(s) * "\n\n"

# ------------------------------------------------------------------ comparison tables

columns(rs) = sort!(unique(first(split_framework(r["framework"])) for r in rs); by = toolkit_rank)

function error_note(s::Snapshot, cases)
    ho = filter(in(cases), heldout_cases(s))
    txt = "In brackets: the error against the reference (the phantom for a synthetic case"
    any(is_real, cases) && (txt *= ", the reconstruction of the fully sampled acquisition for a real Cartesian case")
    isempty(ho) || (txt *= ", the held-out k-space error for $(join(case_label.(ho), " and "))")
    return txt * "; see [Error measures](@ref)).\n"
end

# The harness clamps a time at 1e-5 s; anything at the clamp is no measurement.
measured_ms(t) = t > 0.01
fastest(cells) = (ts = [c["time_ms"] for c in values(cells) if measured_ms(c["time_ms"])]; length(ts) > 1 ? minimum(ts) : -1.0)

"""
    fixed_budget_markdown(s, category) -> String

One row per (case, method), one column per toolkit: time and, in brackets, error. The fastest time
of a row is bold.
"""
function fixed_budget_markdown(s::Snapshot, category)
    rs = filter(r -> r["category"] == category, rows(s))
    isempty(rs) && return "*No rows.*\n"
    cols = columns(rs)
    groups = Dict{Tuple{String, String}, Dict{String, Any}}()
    for r in rs
        tk, variant = split_framework(r["framework"])
        method = isempty(variant) ? r["method"] : "$(r["method"]), $variant"
        get!(groups, (r["case_id"], method), Dict{String, Any}())[tk] = r
    end
    out = Vector{Vector{String}}()
    for key in sort!(collect(keys(groups)); by = k -> (case_rank(k[1]), k[2]))
        cells = groups[key]
        best = fastest(cells)
        row = [case_label(key[1]), key[2]]
        for t in cols
            haskey(cells, t) || (push!(row, "·"); continue)
            c = cells[t]
            x = fmt_ms(c["time_ms"])
            c["time_ms"] == best && (x = "**$x**")
            e = fmt_err(c["nrmse_gt"])
            push!(row, isempty(e) ? x : "$x ($e)")
        end
        push!(out, row)
    end
    return md_table(["case", "method", cols...], out; align = ["---", "---", fill("---:", length(cols))...]) *
        "\n" * error_note(s, unique(first.(collect(keys(groups)))))
end

"""
    race_markdown(s) -> String

Per (case, method), the target error, then per toolkit the time to reach it, the iterations that took
and, in brackets, the error reached. "not reached": the toolkit has a fixed-budget row of the method
but no race row. "·": no row of the method at all.
"""
function race_markdown(s::Snapshot)
    all_ = rows(s)
    rs = filter(r -> r["category"] == "Accuracy race", all_)
    isempty(rs) && return "*No rows.*\n"
    cols = columns(rs)
    budget = Set((r["case_id"], budget_base(r["method"]), first(split_framework(r["framework"])))
        for r in all_ if r["category"] in ("Sparsity", "Dynamic"))
    groups = Dict{Tuple{String, String}, Dict{String, Any}}()
    targets = Dict{Tuple{String, String}, Float64}()
    for r in rs
        base, target, _ = race_parts(r["method"])
        key = (r["case_id"], base)
        get!(groups, key, Dict{String, Any}())[first(split_framework(r["framework"]))] = r
        target === nothing || (targets[key] = target)
    end
    out = Vector{Vector{String}}()
    for key in sort!(collect(keys(groups)); by = k -> (case_rank(k[1]), k[2]))
        cells = groups[key]
        best = fastest(cells)
        row = [case_label(key[1]), key[2], haskey(targets, key) ? fmt_err(targets[key]) : "?"]
        for t in cols
            if !haskey(cells, t)
                push!(row, (key[1], key[2], t) in budget ? "not reached" : "·")
                continue
            end
            c = cells[t]
            x = fmt_ms(c["time_ms"])
            c["time_ms"] == best && (x = "**$x**")
            push!(row, "$x, $(race_parts(c["method"])[3]) it ($(fmt_err(c["nrmse_gt"])))")
        end
        push!(out, row)
    end
    return md_table(["case", "method", "target", cols...], out; align = ["---", "---", "---:", fill("---:", length(cols))...]) *
        "\n" * error_note(s, unique(first.(collect(keys(groups)))))
end

const DEFAULT_THREADS = 8

"""
    by_threads(f, machine; gpu = false) -> String

`f(s)` for every CPU (or GPU) snapshot of `machine`, each under its provenance: the 8-thread
snapshot shown, the others collapsed.
"""
function by_threads(f, machine; gpu::Bool = false)
    snaps = gpu ? gpu_snapshots(machine) : cpu_snapshots(machine)
    isempty(snaps) && return "*No $(gpu ? "GPU" : "CPU") snapshot of $machine.*\n"
    i = gpu ? nothing : findfirst(s -> s.threads == DEFAULT_THREADS, snaps)
    main = snaps[something(i, 1)]
    io = IOBuffer()
    print(io, header(main), f(main), "\n")
    for s in snaps
        s === main || print(io, details(device_label(s), header(s) * f(s)))
    end
    return String(take!(io))
end

# ------------------------------------------------------------------ thread scaling

"""
    scaling_markdown(machine, category) -> String

Every toolkit's time for each (case, method) of `category` at each thread count of `machine`, and the
speed-up from the fewest to the most threads.
"""
function scaling_markdown(machine, category)
    snaps = cpu_snapshots(machine)
    isempty(snaps) && return "*No CPU snapshots of $machine.*\n"
    ths = [s.threads for s in snaps]
    data = Dict{Tuple{String, String, String}, Dict{Int, Float64}}()
    for s in snaps, r in rows(s)
        r["category"] == category || continue
        tk, variant = split_framework(r["framework"])
        method = category == "Accuracy race" ? first(race_parts(r["method"])) : r["method"]
        isempty(variant) || (method *= ", $variant")
        get!(data, (r["case_id"], method, tk), Dict{Int, Float64}())[s.threads] = r["time_ms"]
    end
    out = Vector{Vector{String}}()
    for (k, times) in sort!(collect(data); by = p -> (case_rank(p[1][1]), p[1][2], toolkit_rank(p[1][3])))
        a, b = get(times, ths[1], -1.0), get(times, ths[end], -1.0)
        push!(out, [case_label(k[1]), k[2], k[3], (haskey(times, t) ? fmt_ms(times[t]) : "·" for t in ths)...,
            measured_ms(a) && measured_ms(b) ? fmt_x(a / b) : "—"])
    end
    return md_table(["case", "method", "toolkit", ("$t" for t in ths)..., "$(ths[1]) → $(ths[end])"], out;
        align = ["---", "---", "---", fill("---:", length(ths) + 1)...])
end

# ------------------------------------------------------------------ overview tables

function machines_markdown()
    out = Vector{Vector{String}}()
    for m in machines(), s in [cpu_snapshots(m); gpu_snapshots(m)]
        r = run_record(s)
        push!(out, [m, s.backend == "cuda" ? "GPU" : "CPU, " * device_label(s), joinv(get(r, "cpu_model", "")),
            joinv(get(r, "gpu", [])), string(length(get(r, "hostnames", []))), joinv(get(r, "julia_version", "")),
            join(unique(get(r, "dates", [])), " to ")])
    end
    return md_table(["machine", "snapshot", "CPU", "GPU", "nodes", "Julia", "measured"], out;
        align = ["---", "---", "---", "---", "---:", "---", "---"])
end

function cases_markdown()
    seen = Dict{String, String}()
    for s in snapshots(), r in rows(s)
        get!(seen, r["case_id"], r["data_source"])
    end
    ho = Set(id for s in snapshots() for id in heldout_cases(s))
    out = [[case_label(id), code(id), src == "synthetic" ? "synthetic" : code(src),
        src == "synthetic" ? "NRMSE against the phantom" : id in ho ? "held-out k-space error" : "NRMSE against the fully sampled reconstruction"]
        for (id, src) in sort!(collect(seen); by = p -> case_rank(p[1]))]
    return md_table(["case", "id", "data", "error measure"], out; align = fill("---", 4))
end

function lambda_markdown()
    dir = joinpath(RESULTS, "lambda")
    io = IOBuffer()
    for f in sort(filter(f -> endswith(f, ".json"), readdir(dir)); by = f -> case_rank(replace(f, ".json" => "")))
        d = JSON.parsefile(joinpath(dir, f))
        lam = get(d, "lambda", Dict()); rho = get(d, "rho", Dict()); tgt = get(d, "race_target", Dict())
        tks = sort!(unique(t for m in keys(lam) for t in keys(lam[m])); by = toolkit_rank)
        out = Vector{Vector{String}}()
        for m in sort(collect(keys(lam)); by = method_name)
            cells = map(tks) do t
                haskey(lam[m], t) || return "·"
                r = get(get(rho, m, Dict()), t, nothing)
                @sprintf("%.3g", lam[m][t]) * (r === nothing ? "" : @sprintf(" (ρ %.3g)", r))
            end
            tg = get(tgt, m, nothing)
            push!(out, [method_name(m), cells..., tg === nothing ? "—" : fmt_err(tg)])
        end
        meta = get(d, "meta", Dict())
        body = md_table(["method", tks..., "race target"], out; align = ["---", fill("---:", length(tks) + 1)...]) *
            "\nCalibration solves of $(get(meta, "iterations", "?")) iterations; error measure: $(get(meta, "error_metric", "image NRMSE")); " *
            link("benchmark/comparison/results/lambda/$f", "file") * "."
        print(io, details(case_label(replace(f, ".json" => "")), body))
    end
    return String(take!(io))
end

# ------------------------------------------------------------------ problem size

const SIZES = joinpath(BENCH, "sizes", "results", "15137010")

function size_rows()
    out = Dict{Tuple{String, String, Int, Int}, Any}()   # (category, toolkit, threads, n) => row
    for f in readdir(joinpath(SIZES, "runs"))
        d = JSON.parsefile(joinpath(SIZES, "runs", f))
        for r in d["benchmarks"]
            out[(r["category"], first(split_framework(r["framework"])), r["threads"], d["image_n"])] = r
        end
    end
    return out
end

function sizes_markdown(category; what = :time)
    rs = size_rows()
    ns = sort(unique(k[4] for k in keys(rs)))
    ths = sort(unique(k[3] for k in keys(rs)))
    tks = sort!(unique(k[2] for k in keys(rs) if k[1] == category); by = toolkit_rank)
    out = Vector{Vector{String}}()
    for t in tks, th in (what == :time ? ths : ths[end:end])
        cells = map(ns) do n
            r = get(rs, (category, t, th, n), nothing)
            r === nothing ? "error" : what == :time ? fmt_ms(r["time_ms"]) : fmt_err(r["nrmse_gt"])
        end
        push!(out, what == :time ? [t, string(th), cells...] : [t, cells...])
    end
    return md_table([what == :time ? ["toolbox", "threads"] : ["toolbox"]; ["$(n)²" for n in ns]], out;
        align = [what == :time ? ["---", "---:"] : ["---"]; fill("---:", length(ns))])
end

function memory_markdown()
    ds = sort([JSON.parsefile(joinpath(SIZES, f)) for f in readdir(SIZES) if startswith(f, "memory_n") && endswith(f, ".json")]; by = d -> d["nx"])
    tks = sort!(unique(r["toolkit"] for d in ds for r in d["rows"]); by = toolkit_rank)
    out = map(tks) do t
        cells = map(ds) do d
            v = Dict(r["method"] => r for r in d["rows"] if r["toolkit"] == t)
            c(m) = haskey(v, m) && v[m]["status"] == "ok" ? @sprintf("%.0f", v[m]["max_rss_mb"]) : "error"
            "$(c("cgsense")) / $(c("wavelet"))"
        end
        [t, cells...]
    end
    return md_table(["toolbox", ("$(d["nx"])²" for d in ds)...], out)
end

function sizes_meta_markdown()
    d = JSON.parsefile(joinpath(SIZES, first(f for f in readdir(SIZES) if startswith(f, "memory_n") && endswith(f, ".json"))))
    return "Node $(d["host"]), measured $(d["date"][1:10])."
end

# ------------------------------------------------------------------ large datasets

const LARGE = joinpath(BENCH, "paper_part6", "large_datasets")

function large_markdown()
    order(f) = f == "cuda.json" ? 1000 : parse(Int, match(r"(\d+)threads", f).captures[1])
    ds = [JSON.parsefile(joinpath(LARGE, f)) for f in sort(filter(f -> endswith(f, ".json"), readdir(LARGE)); by = order)]
    label(d) = d["backend"] == "cuda" ? "GPU" : replace(replace(d["backend"], r"^openblas_(\d+)threads$" => s"\1 threads"), r"^1 threads$" => "1 thread")
    keys_ = sort!(unique((r["case_id"], r["method"]) for d in ds for r in d["rows"]))
    cell(d, key, k) = (i = findfirst(r -> (r["case_id"], r["method"]) == key, d["rows"]); i === nothing ? nothing : d["rows"][i][k])
    name(case) = replace(case, "large_" => "")
    t_rows = Vector{Vector{String}}(); e_rows = Vector{Vector{String}}()
    for key in keys_
        it = first(x for x in (cell(d, key, "maxit") for d in ds) if x !== nothing)
        push!(t_rows, [name(key[1]), method_name(key[2]), string(it), (fmt_s(cell(d, key, "time_s")) for d in ds)...])
        push!(e_rows, [name(key[1]), method_name(key[2]), string(it), map(ds) do d
            e = cell(d, key, "nrmse"); m = cell(d, key, "maxrss_gb")
            e === nothing ? "·" : fmt_err(e) * (m === nothing ? "" : @sprintf(" / %.1f GB", m))
        end...])
    end
    hdr = ["case", "method", "iterations", label.(ds)...]
    al = ["---", "---", "---:", fill("---:", length(ds))...]
    sizes = unique((name(r["case_id"]), r["image_size"], r["coils"]) for d in ds for r in d["rows"])
    hosts = join(unique(d["hostname"] * (d["gpu"] === nothing ? "" : " ($(d["gpu"]))") for d in ds), ", ")
    return "Ristretto $(first(ds)["ristretto_commit"]["commit"][1:9]); nodes $hosts.\n\n" *
        join(("- $(code(c)): $(join(sz, "×")) voxels, $(nc) coils" for (c, sz, nc) in sizes), "\n") * "\n\n" *
        "**Time**\n\n" * md_table(hdr, t_rows; align = al) *
        "\n**Error against the reference / peak resident memory**\n\n" * md_table(hdr, e_rows; align = al)
end

# ------------------------------------------------------------------ start-up and footprint

function startup_markdown()
    d = JSON.parsefile(joinpath(BENCH, "startup", "results.json"))
    rs = d["summary"]
    s(x) = x >= 10 ? @sprintf("%.1f", x) : x >= 0.1 ? @sprintf("%.2f", x) : @sprintf("%.3f", x)
    get_(tk, m, k) = (i = findfirst(r -> r["toolkit"] == tk && r["method"] == m, rs); i === nothing ? "—" : s(rs[i][k]))
    pair(tk, k) = get_(tk, "wavelet", k) * " / " * get_(tk, "cgsense", k)
    out = [[tk, s(rs[findfirst(r -> r["toolkit"] == tk, rs)]["import_s"]), pair(tk, "first_solve_s"), pair(tk, "warm_solve_s"), pair(tk, "end_to_end_s")]
        for tk in unique(r["toolkit"] for r in rs)]
    head = "Node $(d["host"]) ($(d["cpu_model"])), $(d["threads"]) threads pinned to NUMA domain $(d["numa_node"]), measured $(d["date"][1:10]); " *
        "Julia $(d["julia_version"]), BART $(d["bart_version"]), " *
        join(("$k $v" for (k, v) in sort(collect(d["python"]))), ", ") * ", " *
        join(("$k $v" for (k, v) in sort(collect(d["julia_packages"]))), ", ") * ".\n\n"
    return head * md_table(["toolbox", "import (s)", "first solve (s)", "warm solve (s)", "fresh process: load and solve (s)"], out)
end

function footprint_markdown()
    d = JSON.parsefile(joinpath(BENCH, "sizes", "footprint.json"))
    return "Measured on $(d["host"]), $(d["date"]).\n\n" *
        md_table(["artifact", "size on disk", "what it contains"], [[r["artifact"], r["size"], r["contents"]] for r in d["rows"]];
        align = ["---", "---:", "---"])
end

# ------------------------------------------------------------------ ablation

const ABL = joinpath(BENCH, "ablation", "results", "15137089")
const ABL_VARIANTS = ("default", "no_task_splitting", "no_fusion", "no_inner_threading", "fft_estimate", "fft_measure")
const ABL_CASES = ("shepp_logan_multislice_8ch_cartesian", "shepp_logan_2d_8ch_radial", "shepp_logan_3d_8ch_cartesian",
    "torso_cine_8ch_cartesian", "torso_cine_8ch_radial", "shepp_logan_2d_8ch_cartesian")
abl_rank(case) = something(findfirst(==(case), ABL_CASES), 99)

function ablation_files()
    ds = [JSON.parsefile(joinpath(ABL, f)) for f in readdir(ABL) if endswith(f, ".json") && !startswith(f, "first_")]
    return sort(ds; by = d -> (abl_rank(d["meta"]["case"]), d["meta"]["reltol"] > 0, d["meta"]["threads"]))
end
abl_label(m) = case_label(m["case"]) * ", " * method_name(m["method"]) *
    (m["reltol"] > 0 ? ", reltol $(m["reltol"]), at most $(m["maxit"]) it" : ", $(m["maxit"]) it")

function ablation_markdown()
    out = Vector{Vector{String}}(); err = Vector{Vector{String}}()
    for d in ablation_files()
        v = Dict(r["variant"] => r for r in d["rows"] if r["status"] == "ok")
        t0 = v["default"]["time_min_s"]
        cells = map(ABL_VARIANTS) do k
            haskey(v, k) || return "·"
            t = v[k]["time_min_s"]
            k == "default" ? fmt_s(t) : "$(fmt_s(t)) ($(fmt_x(t / t0)))"
        end
        push!(out, [abl_label(d["meta"]), string(d["meta"]["threads"]), string(d["meta"]["tasks"]), cells...])
        worst = argmax(k -> v[k]["nrmse_vs_default"], [k for k in ABL_VARIANTS if haskey(v, k)])
        push!(err, [abl_label(d["meta"]), string(d["meta"]["threads"]), fmt_err(v["default"]["nrmse_gt"]),
            @sprintf("%.1e (%s)", v[worst]["nrmse_vs_default"], worst)])
    end
    return "**Time (minimum of the timed runs) and ratio to the default**\n\n" *
        md_table(["case", "threads", "tasks", ABL_VARIANTS...], out; align = ["---", "---:", "---:", fill("---:", length(ABL_VARIANTS))...]) *
        "\n**Error.** The default's NRMSE against the phantom, and the largest NRMSE between a variant's image and the default's.\n\n" *
        md_table(["case", "threads", "NRMSE against the phantom", "largest NRMSE against the default (variant)"], err;
        align = ["---", "---:", "---:", "---:"])
end

function ablation_meta_markdown()
    m = first(ablation_files())["meta"]
    return "Job $(m["slurm_job"]), node $(m["host"]) ($(m["cpu"])), Julia $(m["julia"]), $(m["blas"]); " *
        "Ristretto $(m["ristretto"]["commit"][1:9]), RistrettoBenchmarking $(m["benchmarking"]["commit"][1:7]); measured $(m["date"][1:10])."
end

function first_solve_markdown()
    groups = Dict{Tuple{String, String, Int}, Dict{Bool, Any}}()
    for f in readdir(ABL)
        (startswith(f, "first_") && endswith(f, ".json")) || continue
        d = JSON.parsefile(joinpath(ABL, f))
        get!(groups, (d["case"], d["method"], d["threads"]), Dict{Bool, Any}())[d["precompile_workload"]] = d
    end
    g(d, k) = d === nothing ? "—" : @sprintf("%.2f", d[k])
    out = map(sort!(collect(keys(groups)); by = k -> (abl_rank(k[1]), k[3]))) do k
        w, n = get(groups[k], true, nothing), get(groups[k], false, nothing)
        [case_label(k[1]) * ", " * method_name(k[2]), string(k[3]), g(w, "load_s"), g(n, "load_s"),
            g(w, "first_solve_s"), g(n, "first_solve_s"), "$(g(w, "second_solve_s")) / $(g(n, "second_solve_s"))"]
    end
    return md_table(["case", "threads", "load, with workload (s)", "load, without (s)", "first solve, with workload (s)",
        "first solve, without (s)", "second solve, with / without (s)"], out)
end

# ------------------------------------------------------------------ one large problem

const TS = joinpath(BENCH, "thread_scaling", "results")
const PROBE_CHANGES = Dict("default" => "none", "gc_off" => "GC off during the solve",
    "cg_blas_grant" => "CG's dot and axpy on threaded OpenBLAS", "variation_serial" => "TV gradient never threads",
    "no_inner_threads" => "nothing threads (threaded = false)")

function thread_probe_markdown()
    out = Vector{Vector{String}}()
    for job in sort(readdir(TS)), f in sort(readdir(joinpath(TS, job)))
        (endswith(f, ".json") && !startswith(f, "kernels")) || continue
        d = JSON.parsefile(joinpath(TS, job, f))
        push!(out, [d["method"] == "tv" ? "TV (ADMM)" : "CG-SENSE", string(d["threads"]),
            occursin("spread4", f) ? "spread over 4 domains" : "one domain", get(PROBE_CHANGES, d["variant"], d["variant"]),
            fmt_s(d["time_min_s"]), fmt_err(d["nrmse"]), job])
    end
    sort!(out; by = r -> (r[1], parse(Int, r[2]), r[3], r[4] != "none", r[7]))
    return md_table(["method", "threads", "placement", "change", "time", "NRMSE", "job"], out;
        align = ["---", "---:", "---", "---", "---:", "---:", "---"])
end

function kernels_markdown()
    dir = joinpath(TS, "15122806")
    fs = sort(filter(f -> startswith(f, "kernels"), readdir(dir)); by = f -> (occursin("spread", f), parse(Int, match(r"(\d+)t", f).captures[1])))
    out = map(fs) do f
        d = JSON.parsefile(joinpath(dir, f))
        g(k) = @sprintf("%.1f", d[k])
        ["$(d["threads"])" * (occursin("spread", f) ? ", spread over 4 domains" : ""), g("copy_GBps") * " GB/s",
            g("fft_batched_ms") * " ms", g("fft_percoil_tasks_ms") * " ms", g("axpy_ms_blas1") * " / " * g("axpy_ms_blasN") * " ms"]
    end
    return md_table(["threads", "copy bandwidth", "batched 3D FFT, 8 coils", "8 per-coil FFT tasks", "axpy!, serial / threaded BLAS"], out)
end

# ------------------------------------------------------------------ what the pages call

md(s) = Markdown.parse(s)
race(machine = CLUSTER; gpu::Bool = false) = md(by_threads(race_markdown, machine; gpu))
fixed(category, machine = CLUSTER; gpu::Bool = false) = md(by_threads(s -> fixed_budget_markdown(s, category), machine; gpu))
scaling(category, machine = CLUSTER) = md(scaling_markdown(machine, category))

# One section per machine other than the cluster, each holding f(machine); nothing when there is none.
function others(f)
    ms = other_machines()
    isempty(ms) && return md("")
    return md(join(("### $(m)\n\n" * f(m) for m in ms), "\n"))
end
other_races(; gpu::Bool = false) = others(m -> by_threads(race_markdown, m; gpu))
other_fixed(category; gpu::Bool = false) = others(m -> by_threads(s -> fixed_budget_markdown(s, category), m; gpu))
other_scaling(category) = others(m -> scaling_markdown(m, category))

end
