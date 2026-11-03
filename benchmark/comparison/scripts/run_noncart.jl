# Section: non-Cartesian DCF adjoint (gridding) of every non-Cartesian catalog case — Ristretto vs BART
# vs SigPy vs MRIReco vs MIRT vs MRpro, all on the case's own ramp DCF except MRIReco, whose `direct`
# reconstruction applies its own density compensation.
#   julia --project=benchmark/comparison -t N benchmark/comparison/scripts/run_noncart.jl --threads=N [--use-mkl] [--data=synthetic|real|all]
#
# ## The toolkits do not grid at the same accuracy by default
#
# Ristretto's default NFFT operating point is `m = 3, σ = 1.5, TENSOR` (`DEFAULT_NFFT_M` and friends);
# MRIReco (`LinearOperatorCollection`'s `NFFTOp`) hardcodes `m = 3, σ = 1.25, TENSOR`, about 4-7×
# less accurate on the forward transform and slightly cheaper — accuracy a gridding
# reconstruction does not use, since its NRMSE against the phantom barely moves across that range.
# So Ristretto is reported twice: at its default, and as `Ristretto (m=3, σ=1.25)` at MRIReco's operating point,
# through `get_encoding_operator`'s `m` / `sigma` / `precompute` keywords.
include(joinpath(@__DIR__, "_setup.jl"))
include(joinpath(@__DIR__, "_toolkits.jl"))
include(joinpath(@__DIR__, "_methods.jl"))

const NFFT_TENSOR = isdefined(Ristretto, :NFFT) ? Ristretto.NFFT.TENSOR : nothing

for c in section_cases(c -> c.trajectory === :noncartesian)
    xm = run_method_rows!("Non-Cartesian", c, :gridding)
    xm === nothing && continue
    # Ristretto at MRIReco's NFFT operating point, same acquisition and DCF. On the GPU the operator
    # is planned on the device (MRIReco's GPU row grids at the same point), and the timed region
    # holds the copies of the k-space to the device and of the image back, as every GPU row does.
    try
        acq = ristretto_acquisition(c; dcf = true)
        y = acq.kspace_data   # host copy, taken before the acquisition moves to the device
        ON_GPU && (acq = Ristretto.Adapt.adapt(RISTRETTO_DEVICE, acq))
        E = Ristretto.get_encoding_operator(acq; m = 3, sigma = 1.25, precompute = NFFT_TENSOR)
        adjoint_run = if ON_GPU
            # NamedDims has no Adapt rule, so the names are carried over by hand: the operator is named
            names = Ristretto.NamedDims.dimnames(y)
            () -> Array(parent(E' * Ristretto.NamedDims.NamedDimsArray{names}(RISTRETTO_DEVICE(parent(y)))))
        else
            () -> E' * y
        end
        t, _, x = time_run(adjoint_run; runs = timed_runs(c))
        x = _score_image(c, :gridding, parent(x))
        push!(results, BenchResult("Non-Cartesian", method_label(:gridding, 0), "$FW (m=3, σ=1.25)", NUM_THREADS, t * 1000, mag_nrmse(x, c.reference), mag_nrmse(xm, x), c.id, c.source))
        flush_results!("non_cartesian")
    catch err
        @warn "Ristretto at MRIReco's NFFT operating point failed on $(c.id)" exception = (err, catch_backtrace())
    end
    release_device_memory()
end

write_section("noncart")
