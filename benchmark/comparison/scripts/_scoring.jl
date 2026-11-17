# The error a row reports, `case_error`. Assumes `_setup.jl` has been included.
#
# A case whose reference is a fully sampled Cartesian reconstruction is scored against it in the
# image domain (`mag_nrmse`). The real radial case has no reference of that kind: its fully sampled
# acquisition is itself non-Cartesian, its unregularized reconstruction keeps changing with the
# iteration count (noise fills the k-space the trajectory never visits), and so an image reference
# rewards a solver for stopping early. It is scored by how well an image predicts the k-space the
# undersampled acquisition leaves out ([`heldout_error`](@ref)).

using Serialization: serialize, deserialize

"""
    error_metric(c) -> String

The name of the error `case_error` reports for case `c`, as recorded in a calibration file.
"""
error_metric(c::BenchCase) = c.id in HELDOUT_CASES ? "held-out k-space" : "image NRMSE"

"""
    case_error(c, method, x) -> Float64

The error of `method`'s reconstruction `x` of case `c`, after `_score_image`: `mag_nrmse` against
`c.reference`, or for a case in [`HELDOUT_CASES`](@ref) the held-out k-space error.
"""
function case_error(c::BenchCase, method::Symbol, x)
    x = _score_image(c, method, x)
    c.id in HELDOUT_CASES && return heldout_error(c, x)
    return mag_nrmse(x, c.reference)
end

"""
    HeldOut

The acquired and the held-out k-space of a case in [`HELDOUT_CASES`](@ref), each with its NFFT plan
and density weights, normalized as the case's own k-space is (`norm_ksp` over all spokes or arms,
before the acquired ones are selected). `k` is (sample, spoke, coil).
"""
struct HeldOut
    kA::Array{ComplexF32}
    wA::Vector{Float64}
    planA::Any
    kH::Array{ComplexF32}
    wH::Vector{Float64}
    planH::Any
end

const _HELDOUT = Dict{String, HeldOut}()
const HELDOUT_CACHE_VERSION = 1

# Accurate enough that the prediction error is the image's, not the NUFFT's.
_heldout_plan(traj, n) = Ristretto.NFFT.plan_nfft(Ristretto.NFFT.backend(), Float64.(reshape(traj, 2, :)), n; m = 4, σ = 2.0)

"""
    heldout(c) -> HeldOut

The held-out data of case `c`, read from the raw dataset the case was prepared from (cached under
`work_dir()` next to the case). The acquired part is checked against `c.kspace` and `c.traj`, so a
change to the case preparation that this assembly does not follow fails here instead of scoring
against the wrong data.
"""
function heldout(c::BenchCase)
    return get!(_HELDOUT, c.id) do
        # Keyed by the acquired trajectory too, so a case prepared with other spokes or arms gets its own.
        path = joinpath(BenchUtils.work_dir(), "$(c.id)__heldout_$(string(hash(c.traj); base = 16))__v$(HELDOUT_CACHE_VERSION).jls")
        kH, tH, wH = if isfile(path)
            deserialize(path)
        else
            d = _assemble_heldout(c)
            mkpath(dirname(path))
            tmp = path * ".tmp$(getpid())"
            serialize(tmp, d)
            mv(tmp, path; force = true)
            d
        end
        n = c.image_size
        HeldOut(c.kspace, vec(Float64.(c.dcf)), _heldout_plan(c.traj, n), kH, vec(Float64.(wH)), _heldout_plan(tH, n))
    end
end

function _heldout_source(c::BenchCase)
    for s in BenchUtils.real_candidates(c.id)
        startswith(c.source, "$(s.source):$(s.id) ") && return s
    end
    error("$(c.id): no dataset candidate matches the case's source \"$(c.source)\"")
end

function _check_acquired(c::BenchCase, k, traj)
    (size(k) == size(c.kspace) && isapprox(k, c.kspace; rtol = 1.0e-6) && traj == c.traj) ||
        error("$(c.id): the held-out assembly does not reproduce the case's acquired k-space; it must follow the case preparation in real_data.jl")
    return nothing
end

# Assembles the k-space exactly as BenchUtils' _prepare_breast_radial does, then keeps what that
# leaves out.
function _assemble_heldout(c::BenchCase)
    s = _heldout_source(c)
    raw = Base.invokelatest(BenchUtils._mritestdata().load_raw, BenchUtils._handle(s))
    _idx = BenchUtils._idx
    if c.id == "real_2d_multichannel_radial"
        prof = raw.profiles
        nsamp, ncoil = size(prof[1].data)
        spokes = sort(unique(Int(_idx(p).kspace_encode_step_1) for p in prof))
        k = zeros(ComplexF32, nsamp, length(spokes), ncoil)
        traj = zeros(Float32, 2, nsamp, length(spokes))
        for p in prof
            j = Int(_idx(p).kspace_encode_step_1) + 1
            k[:, j, :] .+= p.data
            Int(_idx(p).slice) == 0 && (traj[:, :, j] .= p.traj[1:2, :])
        end
        nkeep = c.image_size[1]
        ctr = Int(prof[1].head.center_sample) + 1
        keep = (ctr - nkeep ÷ 2):(ctr + nkeep ÷ 2 - 1)
        k = norm_ksp(k[keep, :, :])
        traj = clamp.(traj[:, keep, :] .* Float32(nsamp / nkeep), -0.5f0, prevfloat(0.5f0))
        sel = 1:size(c.kspace, 2)
        _check_acquired(c, k[:, sel, :], traj[:, :, sel])
        ho = (last(sel) + 1):size(k, 2)
        return k[:, ho, :], traj[:, :, ho], BenchUtils.ramp_dcf(traj[:, :, ho])
    end
    throw(ArgumentError("$(c.id) has no held-out data"))
end

# k-space of image x (x, y[, frame]) through maps S (x, y, coil), as (sample, coil[, frame]).
function _predict(plan, x, S)
    nt = size(x, 3)
    out = zeros(ComplexF64, size(plan.k, 2), size(S, 3), nt)
    for t in 1:nt, j in axes(S, 3)
        out[:, j, t] = plan * ComplexF64.(view(x, :, :, t) .* view(S, :, :, j))
    end
    return out
end

"""
    heldout_error(c, x) -> Float64

How well image `x` of case `c` (one of [`HELDOUT_CASES`](@ref)) predicts the k-space the
undersampled acquisition leaves out, through the case's coil maps and an NFFT: with `W` the
density weights, `y` the held-out samples and `A` the forward model,

    ‖W^½ (α A x − y)‖ / ‖W^½ y‖,

where the complex scale `α` is fitted on the acquired samples (so it never sees the held-out data)
and puts every toolkit's image on the data's scale and global phase. The density weights make this
behave like an image-domain error over the disk the trajectory covers rather than one dominated by
the k-space centre; the corners of the image's k-space, which no sample constrains, do not count.
Measurement noise in `y` sets a floor no image can go below.
"""
function heldout_error(c::BenchCase, x)
    h = heldout(c)
    x = Array(x)
    pA = _predict(h.planA, x, c.smaps)
    yA = reshape(h.kA, size(pA, 1), size(pA, 2), :)
    WA = reshape(h.wA, :)
    num = zero(ComplexF64); den = 0.0
    for I in CartesianIndices(pA)
        w = WA[I[1]]
        num += w * conj(pA[I]) * yA[I]
        den += w * abs2(pA[I])
    end
    α = num / den
    pH = _predict(h.planH, x, c.smaps)
    yH = reshape(h.kH, size(pH, 1), size(pH, 2), :)
    WH = reshape(h.wH, :)
    e = 0.0; r = 0.0
    for I in CartesianIndices(pH)
        w = WH[I[1]]
        e += w * abs2(α * pH[I] - yH[I])
        r += w * abs2(yH[I])
    end
    return sqrt(e / r)
end
