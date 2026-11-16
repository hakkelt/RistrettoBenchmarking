# Ristretto's row of the startup benchmark as a JuliaC application: the solve of
# `../solve_ristretto.jl`, compiled ahead of time with its dependencies into one executable.
#
#   juliac --output-exe ristretto_app --bundle build --experimental benchmark/startup/juliac_app
#   JULIA_NUM_THREADS=8 build/bin/ristretto_app <datadir> <method> <nwarm> <nx> <ny> <nc> <maxit> <lambda> [<out.c64>]
#
# It reads the raw arrays `../prepare.jl` writes, prints the same `RESULT` line as the scripts
# (`../child_common.jl`; its import time is 0, since nothing is loaded at run time), and writes
# the image of the first solve to `<out.c64>` when given. With the single argument `noop` it
# exits at once, which times the process start of the bundle.
module RistrettoApp

using Ristretto
using LinearAlgebra: BLAS
using FFTW: FFTW

const WAVELET_LEVELS = 3

readraw(dir, T, name, dims...) = read!(joinpath(dir, name), Array{T}(undef, dims...))

function mag_nrmse(est, ref)
    a, r = abs.(est), abs.(ref)
    a .*= sqrt(sum(abs2, r) / sum(abs2, a))
    return sqrt(sum(abs2, a .- r) / sum(abs2, r))
end

function (@main)(args::Vector{String})::Cint
    (length(args) == 1 && args[1] == "noop") && return 0
    dir, method = args[1], Symbol(args[2])
    nwarm = parse(Int, args[3])
    nx, ny, nc = parse(Int, args[4]), parse(Int, args[5]), parse(Int, args[6])
    maxit = parse(Int, args[7])
    λ = parse(Float64, args[8])
    nt = Threads.nthreads()
    t_setup = @elapsed begin
        BLAS.set_num_threads(nt)
        FFTW.set_num_threads(nt)
        kspace = readraw(dir, ComplexF32, "kspace.c64", nx, ny, nc)
        smaps = readraw(dir, ComplexF32, "smaps.c64", nx, ny, nc)
        reference = readraw(dir, ComplexF32, "reference.c64", nx, ny)
        mask = readraw(dir, UInt8, "mask.u8", nx, ny) .!= 0
        lines = mask[1, :]
        acq = Ristretto.CartesianAcquisitionInfo(
            NamedDimsArray{(:kx, :ky, :coil)}(kspace[:, lines, :]);
            is3D = false, image_size = (nx, ny), subsampling = (:, lines), shifted_image_dims = (:x, :y),
            sensitivity_maps = NamedDimsArray{(:x, :y, :coil)}(smaps),
        )
        m = if method === :wavelet
            IterativeReconstruction(;
                regularization = L1Wavelet2D(λ; wavelet = Ristretto.WT.db2, levels = WAVELET_LEVELS),
                algorithm = Ristretto.FISTA(; maxit, tol = 0.0), maxit, reltol = 0.0,
            )
        elseif method === :cgsense
            IterativeReconstruction(; regularization = (), algorithm = Ristretto.CGNR(; maxit, tol = 0.0), maxit, reltol = 0.0)
        else
            error("no method $method")
        end
    end
    solve() = Array(parent(reconstruct(acq, m; verbosity = Silent())))
    t_first = @elapsed x = solve()
    e = mag_nrmse(x, reference)
    length(args) >= 9 && open(io -> write(io, ComplexF32.(x)), args[9], "w")
    warm = [@elapsed(solve()) for _ in 1:nwarm]
    println("RESULT ", 0.0, " ", t_setup, " ", t_first, " ", e, " ", isempty(warm) ? "-" : join(warm, ","))
    println(stderr, "threads ", nt)
    return 0
end

end
