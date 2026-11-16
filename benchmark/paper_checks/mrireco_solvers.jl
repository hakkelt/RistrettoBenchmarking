# Two checks of MRIReco.jl on the 2D 8-coil Cartesian catalog case, with the comparison suite's
# MRIReco set-up (_toolkits.jl: maps, acquisition, calibrated λ, the FISTA step estimate):
#
#  1. reconstruction(acqData, params) with params[:solver] = FISTA, POGM and OptISTA
#     (RegularizedLeastSquares), ℓ1-wavelet, 20 iterations: the error each raises, or the NRMSE
#     of its image against the phantom and against the FISTA image.
#  2. A misspelled solver option (:iteration for :iterations): the image with and without it, and
#     the log records MRIReco emits, with its default params[:kwargWarning] = false and with true.
#
#   julia --project=benchmark/comparison -t 1 benchmark/paper_checks/mrireco_solvers.jl --threads=1 --out=x.json
const OUTFILE = something(match(r"^--out=(.*)$", get(filter(a -> startswith(a, "--out="), ARGS), 1, "--out=mrireco_solvers.json")), nothing).captures[1]
include(joinpath(@__DIR__, "..", "comparison", "scripts", "_setup.jl"))
include(joinpath(@__DIR__, "..", "comparison", "scripts", "_toolkits.jl"))
include(joinpath(@__DIR__, "..", "comparison", "scripts", "_methods.jl"))
using Logging, Pkg

c = get_case("shepp_logan_2d_8ch_cartesian")
λ = load_lambda(c, :wavelet, "MRIReco", 0.0)
k, s = c.kspace, cart_maps(c)
senseMaps = _mrireco_maps(s, c.image_size)
AHA = _mrireco_normal_operator(_mrireco_acq(k), senseMaps, c.image_size)
step = 0.95 / RLS.power_iterations(AHA)

function params(solver; extra...)
    rp = Dict{Symbol, Any}(
        :reco => "multiCoil", :reconSize => c.image_size, :senseMaps => senseMaps,
        :solver => solver, :reg => L1Regularization(λ), :iterations => 20, :rho => step,
        :vary_rho => :none, :iterationsCG => CMP_CG_ITERS, :absTol => 0.0, :relTol => 0.0,
        :tolInner => CMP_TOL_INNER, :densityWeighting => false, :sparseTrafo => "Wavelet",
    )
    for (kk, v) in extra
        rp[kk] = v
    end
    return rp
end
recon(rp) = _mrireco_image(MRIReco.reconstruction(_mrireco_acq(k), rp), c.image_size)

out = Dict{String, Any}("case" => c.id, "lambda" => λ, "step" => step,
    "versions" => Dict(string(p.name) => string(p.version) for p in values(Pkg.dependencies()) if p.name in ("MRIReco", "RegularizedLeastSquares", "MRIOperators", "LinearOperatorCollection")))
ref = nothing
for (name, solver) in (("FISTA", MR_FISTA), ("POGM", RLS.POGM), ("OptISTA", RLS.OptISTA))
    try
        img = recon(params(solver))
        name == "FISTA" && (global ref = img)
        out[name] = Dict("status" => "ok", "nrmse_phantom" => mag_nrmse(img, c.reference),
            "nrmse_vs_fista" => ref === nothing ? nothing : mag_nrmse(img, ref))
    catch e
        bt = catch_backtrace()
        msg = sprint(showerror, e)
        st = [string(f) for f in stacktrace(bt)[1:min(12, end)]]
        out[name] = Dict("status" => "error", "type" => string(typeof(e)), "message" => first(msg, 2000), "stacktrace" => st)
    end
    println(name, " => ", out[name])
end

# 2. a misspelled keyword
function logged(f)
    lg = Test.TestLogger(; min_level = Logging.Debug)
    r = with_logger(f, lg)
    return r, [(string(l.level), string(l.message)) for l in lg.logs if l.level >= Logging.Info]
end
using Test
base, _ = logged(() -> recon(params(MR_FISTA)))
typo, logs_off = logged(() -> recon(params(MR_FISTA; iteration = 3)))
typo_w, logs_on = logged(() -> recon(params(MR_FISTA; iteration = 3, kwargWarning = true)))
short, _ = logged(() -> recon(params(MR_FISTA; iterations = 3)))
out["misspelled"] = Dict(
    "identical_to_unmisspelled" => base == typo,
    "max_abs_diff_vs_unmisspelled" => maximum(abs.(base .- typo)),
    "nrmse_vs_3_iterations" => mag_nrmse(typo, short),
    "logs_kwargWarning_false" => logs_off, "logs_kwargWarning_true" => logs_on,
    "identical_with_warning_on" => base == typo_w,
)
println(out["misspelled"])
mkpath(dirname(abspath(OUTFILE)))
open(io -> JSON.print(io, out, 2), OUTFILE, "w")
