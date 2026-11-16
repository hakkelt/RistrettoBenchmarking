# Measurements for the Ristretto.jl paper

This branch (`paper-measurements`) collects the measurements and source checks for the
Toolbox Article on Ristretto.jl. It is based on `gpu-tensor-rerun` (draft PR #1), which is
`master` plus the GPU rerun and the TENSOR-NFFT radial CPU rows, so the stored snapshots it starts
from are the newest ones. Working files that are not in the repository (source clones, builds,
venvs, logs) are in `/project/c_mrrecon/paper-measurements`, called "the working directory" below.

## Not done or not verified

State on 2026-11-16; every table names its commit and node.

- **Part 2.4 / start-up numbers.** The JuliaC and static-BART start-up rows are login-node
  measurements only. The harness numbers on a compute node, at the Part 6 commit, are not done.
- **Part 2, JuliaC with threads.** The 15-18 s first solve at more than one thread is explained
  (Part 2) but not fixed: the fix needs a change to Ristretto's source.
- **Part 3.** Causes 4(a)-(c) and the knee's 4-thread run are observed, not resolved. The fixes in
  the last table are estimates; none was implemented (Ristretto's source was not to be changed).
- **Part 4a.** The fork PR is updated (hakkelt/AbstractOperators.jl#50). The Ristretto branch is
  committed locally but not pushed, and its PR is not open yet. The `:operators`/`:encoding` test
  items pass on it (31 of 31, login node).
- **Part 4b.** Not started. Switches known to be missing: `fftshift` instead of sign alternation,
  and no-Toeplitz (no run-time option found so far).
- **Part 5.** Not started.
- **Part 6.** Waits for the go-ahead.
- **Part 1, item 9.** The reported POGM/OptISTA failure was not reproduced; only the forms listed
  there were tried.
- **Part 1, item 10.** The printed snippet is derived from the measured call, not run on its own.

## Part 1. Claims about other toolboxes

BART source: tag `v1.0.00` (commit `37f3c5f0`, 2026-02-18) cloned from
`codeberg.org/mrirecon/bart` into the working directory; paths below are relative to its root.
Everything below was read in the source except where it says "measured" or "inference". All
licences were checked first: BART (BSD-3-style), SigPy (BSD), MRpro (Apache-2.0), MRIReco.jl,
RegularizedLeastSquares.jl, LinearOperatorCollection.jl, MIRT.jl (MIT). No GPL code was read.

1. **BART centred FFT by modulation.** `fftc` is `fftmod` → uncentred FFT → `fftmod`
   (`src/num/fft.c:419-424`). Cartesian `pics` never calls `fftc`: it multiplies the coil maps by
   the modulation once (`src/sense/model.c:75-76`) and demodulates the k-space once
   (`src/pics.c:438`), around an uncentred FFT (`linop_fft_create`, `src/sense/model.c:118-128`).
   **Odd sizes work:** the phase is `(j − c/2)·c/n` with `c = n÷2` for any `n`
   (`src/num/fft.c:64-69`); only the fast ±1 checkerboard path needs every dimension divisible by
   4 (`src/num/fft.c:131-135`), all other sizes take complex phases. Measured: `bart fft 3`
   (static v1.0.00 build) on random 7×5 and 9×1 arrays equals `fftshift(fft(ifftshift(x)))` to a
   relative error of 1.1e-7 (8×6: exactly). So BART's modulation path, unlike Ristretto's sign
   alternation, also covers odd sizes.
2. **BART adaptive ADMM penalty.** Implementation: `src/iter/admm.c:491-506` (ρ×τ if r > μ·s,
   ρ/τ if s > μ·r). Flag: `pics -D`, short form only (`OPT_SET('D', &admm.dynamic_rho,
   "(ADMM dynamic step size)")`, `src/pics.c:163`). Hidden: `show_option_p` hides any option
   whose description is wholly in parentheses (`src/misc/opts.c:257-263`). **Off by default**:
   `.dynamic_rho = false`, `τ = 2`, `τ_max = 20`, `μ = 3` (`src/iter/iter.c:133-148`).
   Undocumented: no hit for ADMM/rho/`-D` in `doc/*.txt`, `doc/bart.1` or `README*`. The
   hidden `-J` ("residual balancing") also turns on adaptive τ (`src/pics.c:213`). Same in
   v0.9.00 (`src/pics.c:294`).
3. **BART looping.** `pics` does not split anything itself: its hidden `-L` is declared
   (`src/pics.c:182`) and rejected with "Looping only supported via BART generic looping
   interface!" (`src/pics.c:207-208`). Only the generic wrapper loops: `bart -l/--loop`,
   `-p/--parallel-loop` (`src/bart.c:202-203`) run the whole tool once per index, each run seeing
   singleton looped dimensions (`md_select_dims(D, ~cfl_loop_desc.flags, …)`,
   `src/misc/mmio.c:384`). **No check** that the regularizer does not couple the looped dimensions:
   searched `regulari|coupl|reg.*loop|loop.*reg` in `src/bart.c src/misc/mmio.c src/pics.c
   src/grecon/optreg.c` and `cfl_loop_get_flags|cfl_loop_desc_active` across `src/`; nothing
   loop-aware outside the I/O layer except a random-number warning (`src/num/rand.c:101-102`).
   Inference, not tested: a TV over a looped dimension then acts on a size-1 axis and does nothing,
   silently.
4. **BART off-resonance correction.** None in `pics`: no field-map hit in `src/pics.c`,
   `src/grecon`, `src/sense` or `src/noncart/nufft.[ch]` (searched
   `fieldmap|timemap|nudft|b0|off.res`). v1.0.00 adds it elsewhere, all new since v0.9.00:
   `bart nufft -F <fieldmap> -T <timemap>` (`src/nufft.c:98-99`) for the exact NUDFT only
   (`assert(1 == dft)`, `src/nufft.c:165`; per-sample phase in `src/noncart/nudft.c:42-60`), and
   `moba --b0map` (`src/moba.c:186`) for the Bloch model. `moba -G` estimates a B0 map in its
   multi-echo water/fat model (`src/moba/meco.c:278`); that is not a correction inside an
   image reconstruction.
5. **BART static linking:** see Part 2.
6. **Toeplitz normal operator.**
   - BART `pics`: **on by default** (`.toeplitz = true`, `src/noncart/nufft.c:55`; forced again
     in `src/pics.c:90`; `--no-toeplitz` turns it off, `src/pics.c:189`).
   - SigPy 0.1.27: exists (`sigpy.fourier.toeplitz_psf`, `NUFFT(…, toeplitz=False)`,
     `sigpy/linop.py:1558`), **never used by the MRI apps**: `Sense` builds
     `sp.linop.NUFFT(S.oshape, coord)` without it (`sigpy/mri/linop.py:91`), and `Compose` does
     not override `_normal_linop`, so `A.N` is the explicit product.
   - MRpro 0.260420: **on by default** in the CG-based SENSE reconstructions:
     `NonUniformFastFourierOp.gram` returns `NonUniformFastFourierOpGramOp`
     (`mrpro/operators/NonUniformFastFourierOp.py:286-288`, kernel on a 2× grid at 419-424), and
     `RegularizedIterativeSENSEReconstruction` solves with `acquisition_model.gram`
     (`mrpro/algorithms/reconstruction/RegularizedIterativeSENSEReconstruction.py:127-131`). The
     TV reconstruction uses PDHG and no gram.
   - MIRT.jl 0.18.3: **none** (searched `toeplitz|psf|Gnufft` over the package).
   - MRIReco.jl 0.9.2: exists in LinearOperatorCollection's `NFFTOp`, **off by default**
     (`toeplitz=false`, `ext/LinearOperatorNFFTExt/NFFTOp.jl:17`); MRIReco forwards `:toeplitz`
     only when the user passes it (`src/Reconstruction/RecoParameters.jl:172-173`).
7. **MRpro subspace reconstruction: none.** Searched `subspace|basis|temporal|lowrank|casorati|
   svd|nuclear|rank` in `mrpro/operators` and `mrpro/algorithms`. The hits are unrelated: the
   temporal basis of `B0InformedFourierOp` (time-segmented **off-resonance correction**, which
   MRpro therefore does have, `mrpro/operators/B0InformedFourierOp.py:40,138-261`),
   `PCACompressionOp`, and a citation in a docstring. No nuclear-norm functional either.
8. **SigPy CPU threading: nothing threads** except, possibly, OpenBLAS inside NumPy's `vdot`/`norm`
   on CG and step-size vectors (NumPy links scipy-openblas 0.3.34). The FFT is
   `numpy.fft.fftn` with no `workers` (`sigpy/fourier.py:44,79`; `numpy/fft/_pocketfft.py` has
   no worker or thread option at all); the Numba kernels are `nopython=True` with no
   `parallel=True`/`prange` (`sigpy/interp.py`, `sigpy/block.py`); `sigpy/config.py` has no
   thread setting; PyWavelets does not thread (searched its Python layer only, `pywt/*.py`, for
   thread/pool/workers; its C extension was not read). Consistent with the flat 1-16 thread rows.
9. **MRIReco.jl with POGM and OptISTA: both run.** Measured
   (`benchmark/paper_checks/mrireco_solvers.jl`, results in
   `benchmark/paper_checks/results/mrireco_solvers.json`; login node; MRIReco 0.9.2,
   RegularizedLeastSquares 0.16.13, LinearOperatorCollection 2.3.2), 2D 8-coil Cartesian,
   ℓ1-wavelet, λ = 1.58e-3 (MRIReco's calibrated value), 20 iterations:

   | solver | step = 0.95/power iteration (0.41) | MRIReco's default `:rho` = 0.05 |
   |---|---|---|
   | FISTA | NRMSE 0.267 | 0.391 |
   | POGM | 0.231 (0.076 from FISTA's image) | 0.355 |
   | OptISTA | 0.233 (0.068 from FISTA's image) | 0.356 |

   No error in either form tried: `params[:solver] = POGM` / `OptISTA` passed to
   `reconstruction(acqData, params)` with `:reco => "multiCoil"`, `:sparseTrafo => "Wavelet"`,
   `:reg => L1Regularization(λ)`, once with an explicit `:rho` (column 1) and once with MRIReco's
   default (column 2). **The reported failure was not reproduced**; other forms (`:normalizeReg`,
   GPU arrays, non-Cartesian data, other regularizers) were not tried. RegularizedLeastSquares
   0.16.12 and 0.16.13 differ only in `CGNR.jl` (start value), so this holds for 0.16.12 as well.
   What a user meets without noticing is the second column: MRIReco's default
   `params[:rho] = 0.05` (`RecoParameters.jl:9`), an ADMM penalty, becomes the step size of all
   three.
10. **Silently dropped options.** `params[:kwargWarning] = false` (`MRIReco/src/Reconstruction/
    RecoParameters.jl:12`) reaches `createLinearSolver(...; kwargWarning, kwargs...)`, whose
    `filterKwargs` keeps only the solver constructor's keywords and warns only when asked
    (`RegularizedLeastSquares/src/RegularizedLeastSquares.jl:267-289`). Measured, same script:
    `params[:iteration] = 3` (for `:iterations`) gives an image **bit-identical** to the run
    without it (max |Δ| = 0; the solver runs MRIReco's default 30, not 3) and logs nothing but an
    unrelated `Info` about `enc2D`. With `params[:kwargWarning] = true` the same call logs
    `Warn: The following arguments were passed but filtered out: absTol, tolInner,
    densityWeighting, S, iteration, reco, iterationsCG, vary_rho.` The smallest example, written
    from the measured call in `mrireco_solvers.jl` (derived; this exact snippet was not run on its
    own):

    ```julia
    params = Dict{Symbol, Any}(:reco => "multiCoil", :reconSize => (nx, ny), :senseMaps => maps,
        :solver => FISTA, :reg => L1Regularization(λ), :sparseTrafo => "Wavelet",
        :iteration => 3)                      # misspelled; add :kwargWarning => true to see it dropped
    img = reconstruction(acqData, params)     # same image as without :iteration, no message
    ```
11. **Current releases against what is installed** (checked 2026-11-16: Julia General registry
    after `Registry.update`, PyPI JSON API, Codeberg tags):

    | toolbox | installed (used by the stored runs) | current | rerun would install |
    |---|---|---|---|
    | BART | v1.0.00 binaries (`~/c_mrrecon/bart-v1.0.00`) | **v1.0.01** (tag 2026-07-03, "minor bugfix release"; Codeberg's release list still shows v1.0.00 as latest) | v1.0.01, built three times (OpenBLAS, MKL, CUDA) |
    | SigPy | 0.1.27 | 0.1.27 | — |
    | MRpro | 0.260420 | **0.261015** | mrpro 0.261015 |
    | PyTorch (CPU) | 2.14.0+cpu | **2.15.0** | torch 2.15.0 (CPU and cu12x wheels) |
    | NumPy | 2.5.3 | 2.5.5 | numpy 2.5.5 |
    | finufft | 2.5.1 | 2.5.1 | — |
    | MRIReco.jl | 0.9.2 | 0.9.2 | — |
    | RegularizedLeastSquares.jl | 0.16.13 | 0.16.13 | — |
    | LinearOperatorCollection.jl | 2.3.2 | **2.5.1** | 2.5.1 (MRIReco's NFFT/FFT operators) |
    | MRIOperators.jl | 0.4.2 | 0.4.3 | 0.4.3 |
    | MIRT.jl | 0.18.3 | 0.18.3 | — |

    `benchmark/comparison/results/toolkit_versions.json` lists BART v0.9.00 for runs before
    2026-10-11; the binaries the site file points at today report v1.0.00.

**Also found (not asked):** the "OpenBLAS" and "MKL" CPU BART builds the suite times are CUDA
builds (`CUDA = 1` in their `Makefile.local`): every CPU `bart` process loads cuFFT, cuBLAS and
cuBLASLt (≈ 840 MB of shared libraries, see Part 2). That costs nothing inside `pics`'s own
"Total Time", which the comparison tables use, but it is in every BART start-up number.

## Part 2. Sizes and start-up

Measured on the login node `vn01` (sizes do not depend on the node), 2026-11-16.

| artifact | size on disk | what it contains |
|---|---:|---|
| BART v1.0.00, **static** (`SLINK=1`, Rocky 8's serial OpenBLAS 0.3.15 `libopenblas.a`, FFTW 3.3.10 with threads, no CUDA/MKL), stripped | **33.7 MB** (33,655,648 B; 56.7 MB unstripped) | one file; `ldd`: "not a dynamic executable"; `file`: "statically linked" |
| BART v1.0.00 as used by the suite (`~/c_mrrecon/bart-v1.0.00/openblas/bart`), dynamic | 5.3 MB binary + **893.8 MB** of shared libraries | of which 844.5 MB are CUDA (cuFFT 292.9, cuBLASLt 441.1, cuBLAS 109.8, cudart 0.7); without them 49.3 MB (OpenBLAS 36.4 — `/usr/lib64/libopenblas.so.0` from openblas-0.3.15-6.el8, the serial variant, FFTW 3.7, libgfortran 2.6, libc/libm/libstdc++ …) |
| same, MKL build | 5.2 MB + 971.4 MB | MKL 116.9 MB + the same CUDA libraries |
| Ristretto JuliaC bundle (`juliac --output-exe --bundle`, no `--trim`) | **1.32 GB** (1,322,813,979 B, 62 files) | executable with the compiled image 989 MB, `lib/` 327 MB (libjulia, LLVM, BLAS, …), artifacts 6.2 MB |
| Ristretto package image (`compiled/v1.13/Ristretto/*.so` + `.ji`) | 372 MB + 2.3 MB | the precompiled native code of Ristretto and its vendored packages |
| a depot holding only what `Pkg.add(url = Ristretto.jl)` installs, precompiled | **847 MB** (4,250 files) | compiled caches 575 MB, artifacts 205 MB, packages + clones 48 MB, registry 19 MB; Julia 1.13.1 itself is another 1.10 GB |
| venv with SigPy (`numpy sigpy numba scipy`) | **392 MB** (392,264,524 B) | + CPython 3.14.3, 108 MB |
| venv with MRpro (CPU PyTorch 2.15.0 + torchvision 0.29.2+cpu + mrpro 0.261015) | **1.37 GB** (1,370,292,576 B, 26,125 files) | PyTorch alone 770 MB; + CPython 108 MB |

Build commands:

- Static BART: `benchmark/sizes/build_static_bart.sh` (committed; it records every step). RHEL 8
  installs no static libraries, so it unpacks the Rocky Linux 8 `glibc-static`, `zlib-static`,
  `libpng-static`, `openblas-static` and `openblas-devel` RPMs into a scratch directory, rewrites
  glibc's `libm.a` linker script to point there, and links with GCC 13 (`gcc-toolset-13`; BART
  v1.0.00 refuses GCC < 12) with `libgomp.a libdl.a` named explicitly after the BLAS libraries.
  Run twice from scratch, it gave the same size to within 4 kB. Checked: `bart pics -S -R
  W:7:0:0.005 -i 20` on a 128², 8-coil phantom gives NRMSE 0 against the dynamic build; the
  static process peaks at 11.8 MB RSS against 132 MB for the dynamic one (which maps the CUDA
  libraries), and `bart version` returns in < 10 ms against 90 ms.
- JuliaC: `juliac --output-exe ristretto_app --bundle build benchmark/startup/juliac_app` (JuliaC
  installed as an app, Julia 1.13.1); the app (`benchmark/startup/juliac_app/src/RistrettoApp.jl`)
  is `solve_ristretto.jl` as a `@main` program. Precompilation of the app environment took 458 s,
  the whole build about 25 min on 16 login-node cores.
- Depot: `JULIA_DEPOT_PATH=<empty dir> julia -e 'using Pkg; Pkg.activate(temp=true);
  Pkg.add(url="https://github.com/hakkelt/Ristretto.jl", rev="master"); Pkg.precompile()'` (registry
  copied in first; script `depot_build.jl` in the working directory).
- Venvs: `uv venv -p cpython-3.14.3`, then `uv pip install --link-mode=copy numpy sigpy numba scipy`;
  for MRpro `torch` and `torchvision` from the PyTorch CPU index, then `mrpro`. (`mrpro` alone
  pulls `torchvision` from PyPI, whose build does not match the CPU `torch`: `import mrpro` then
  fails with "operator torchvision::nms does not exist".) Checked: `import mrpro` works. Both venvs
  hold the **current releases** (table in Part 1, item 11), not the versions the stored suite runs
  used (SigPy is the same; MRpro 0.261015 vs 0.260420, PyTorch 2.15.0 vs 2.14.0).
- JuliaC with `--trim=safe --experimental` (same app): **fails** in the trim verifier with 57
  errors, about half of them in the app's own code (closures over abstractly typed values, the
  `kwcall` that builds the reconstruction, `println`, `read!` with splatted dimensions). The rest are
  in dependencies: ArgCheck's error builder, AbstractNFFTs' backend registry (`getglobal(back,
  :backend)()` returns `Any`), FFTW's plan finalizer (`unsafe_destroy_plan` on an abstract
  `FFTWPlan`), ProximalAlgorithms' keyword merge with a `Dict{Symbol}`, and Ristretto's
  dimension-name tuple checks (`Tuple{Vararg{Symbol}}` comparisons and string building). Log:
  `juliac/build_trim.log` in the working directory.

**JuliaC first solve depends on the thread count (login node `vn01`, 4 cores pinned, not the
harness; preliminary).** A second bundle whose app module carries a `@compile_workload` running
`main` on a 32², 4-coil synthetic case (both methods; bundle 1.34 GB, build ≈ 25 min) gives, on the
startup case (128², 8 coils, ℓ1-wavelet, 20 FISTA iterations):

| process | `noop` start | first solve | warm solves | NRMSE |
|---|---:|---:|---:|---:|
| JuliaC + workload, 1 thread | 1.55 s (6.4 s cold page cache) | **0.29 s** | 0.14, 0.25 s | 0.27718 |
| JuliaC + workload, 4 threads | same | **17.9 s** | 0.08-0.25 s | 0.27718 |
| JuliaC + workload, 4 threads, the 32² workload case itself | | 14.6 s | 2-4 ms | |
| script (`solve_ristretto.jl`, package image), 1 thread | import 9.4 s | 10.7 s | 0.077 s | 0.27718 |
| script, 4 threads | import 5.4 s | 18.1 s | 0.07-0.11 s | 0.27718 |

The image is generated in a single-threaded process (the build log prints `threads 1` from the
workload), so `reconstruct`'s default `threaded = Threads.nthreads() > 1` is false there and the
threaded code paths are never compiled into it; started with more threads, the app compiles them at
run time (14.6 s even on the workload's own case). Ristretto's package workload
(`src/precompile.jl`) runs the same way under `Pkg.precompile`, which is where about 7 s of the
script's 4-thread first solve comes from.

Cause, measured: with more than one thread `get_encoding_operator` builds a different operator, the
coil-fused frame operator (`_coil_fused_frame_operator`, gated by `threaded && … &&
Threads.nthreads() > 1` at `src/encoding/encoding_operators.jl:144`), so every solver method
specialises on a new operator type. `--trace-compile-timing` of the script: 176 method instances
(18.3 s summed compile time) at 1 thread, 370 (26.6 s) at 4 threads, of which 235 instances and
16.1 s exist only at 4 threads, led by `_scale_default_warm_start`, `_direct_reconstruct`, the
`Compose` products and the `Threads.@threads` closures of AbstractOperators' `mul!`
(`benchmark/startup/paper_results/trace_compile_threads.txt`). A third bundle whose workload also
calls the solve with `threaded = true` confirms it: first solve 15.7 s at 4 threads, 18.1 s at 8
(0.31 s at 1), because `threaded = true` does not reach the `nthreads()` gate in a single-threaded
build process. A fix needs Ristretto's source (not changed here): let that gate be overridden (for
example by a keyword or a scoped value the workloads set), and run both workloads, the package's
`src/precompile.jl` and an app's, through the coil-fused operator as well.

## Part 3. Thread scaling of single large problems

**Runs:** `shepp_logan_3d_8ch_cartesian` (128³, 8 coils, OpenBLAS), the comparison suite's Ristretto
rows (TV: ADMM 20×10 CG; CG-SENSE: 10 CGNR), timed with `time_run`, then profiled once (Julia's
sampling profiler, 5 ms, every thread). Ristretto at the submodule pin `c949d8e` (clean). The
vendored packages are identified by the git tree hash of their `deps/` directory, because the
`git-subtree-split` trailers in the history are older than the trees: AbstractOperators
`4bfdc831`, ProximalAlgorithms `bf0eb15b`, ProximalOperators `76d44bef`, StructuredOptimization
`e8b3ff86`, NFFT `e6cd902c`, OperatorCore `b23f830c`. (Ristretto `master` `0f53bf49c` differs
only in ProximalAlgorithms, `a517b180`; the re-vendored branch of Part 4 only in AbstractOperators,
`5ee907fc`.) AMD EPYC 7763,
exclusive node, one run at a time. "One domain" = `numactl --cpunodebind=1 --membind=1` (16 cores,
the placement `matrix.sh` gives every task); "spread" = cores taken round-robin from NUMA nodes 0-3,
memory interleaved over them. Jobs: 15122806 (`cpu-short`, 64-core node x1001c1s2b0n1), 15123878
(`cpu`, x1000c3s4b0n1), 15123914 (`cpu`, x1000c0s5b0n0). Scripts and every JSON:
`benchmark/thread_scaling/` (`probe.jl`, `kernels.jl`, `probe.sh`, `results/<job>/`).

The probe reproduces the stored numbers: TV 41.5 / 21.0 / 22.3 s at 1 / 4 / 16 threads (stored
41.97 / 25.72 / 25.54), CG-SENSE 3.87 / 1.57 / 1.21 s (stored 4.06 / 1.84 / 1.19).

### Attribution (job 15123878, `cpu` partition, 128-core node x1000c3s4b0n1)

Wall time of the main thread, which carries the solve, by what it was doing; seconds, scaled to the
timed minimum. With threads, the main thread's FFT and element-wise time is the time of the
parallel region it leads; "waiting" is the main thread blocked at the end of a region whose other
tasks are still running.

| run | time | FFT | FFT planning | element-wise | TV gradient | proximal step | CG/ADMM vector updates (incl. BLAS) | alloc + GC | waiting for workers |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| TV, 1 thread | 41.5 | 25.0 | 1.5 | 8.4 | 2.0 | 0.5 | 3.3 | 0.7 | 0 |
| TV, 4 threads, one domain | 21.0 | 7.9 | 1.7 | 0.2 | 1.3 | 0.1 | 4.0 | 0.3 | 5.5 |
| TV, 16 threads, one domain | 22.3 | 7.1 | 0.1 | 2.7 | 4.2 | 0 | 1.3 | 0.7 | 6.1 |
| TV, 16 threads, spread over 4 domains | 14.0 | 4.5 | 0 | 0.8 | 0.6 | 0 | 6.2 | 0.4 | 1.4 |
| CG-SENSE, 1 thread | 3.9 | 1.3 | 1.5 | 0.6 | – | – | 0.1 | 0.4 | 0 |
| CG-SENSE, 4 threads | 1.6 | 0.9 | 0 | 0.1 | – | – | 0.1 | 0.1 | 0.3 |
| CG-SENSE, 16 threads | 1.2 | 0.4 | 0 | 0.1 | – | – | 0.3 | 0.1 | 0.3 |
| CG-SENSE, 16 threads, spread | 0.8 | 0.3 | 0 | 0.1 | – | – | 0.1 | 0.2 | 0.1 |

Share of all task-running threads' time spent idle or spin-waiting: TV 40 % (4 threads), 77 %
(16), 58 % (16 spread); CG-SENSE 34 %, 82 %, 55 %. Single-sample attributions on the main thread
move by about a second between jobs (e.g. "vector updates" at 4 vs 16 threads); the totals and the
one-change comparisons below are the robust part.

Kernels on the case's own arrays (`kernels.jl`, job 15122806, `cpu-short` partition, 64-core node
x1001c1s2b0n1, one domain unless noted):

| threads | copy bandwidth | batched 3D FFT, 8 coils | 8 per-coil FFT tasks | `axpy!` serial / threaded BLAS |
|---:|---:|---:|---:|---:|
| 1 | 8.5 GB/s | 60.4 ms | 59.9 ms | 10.4 / 10.4 ms |
| 4 | 28.2 GB/s | 19.0 ms | 18.8 ms | 10.5 / 8.5 ms |
| 16 | 32.6 GB/s | 12.4 ms | 14.4 ms | 10.4 / 8.6 ms |
| 16, spread over 4 domains | 40.6 GB/s | 6.7 ms | 9.0 ms | 8.7 / 0.8 ms |

### One-change experiments (TV at 16 threads unless noted; times are the timed minimum)

Jobs 15123878 and 15123914 ran on 128-core `cpu` nodes, 15122806 on the 64-core `cpu-short` node;
the job column says which row came from where.

| change | TV | CG-SENSE | job |
|---|---:|---:|---|
| none (one domain) | 22.3 / 22.1 s | 1.21 s | 15123878 / 15123914 |
| 4 threads instead of 16 | 21.0 s | 1.57 s | 15123878 |
| **spread over 4 domains, memory interleaved** | **14.0 s** (1.6×) | **0.80 s** (1.5×) | 15123878 |
| no inner threading (`threaded = false`) | 40.9 s | – | 15123914 |
| TV gradient never threads (`Variation` threshold raised) | 21.2 s; 4 threads 21.9 s; spread 14.0 s | – | 15123914 |
| CG's `dot`/`axpy!` on threaded OpenBLAS (`CG_BLAS_THREAD_BYTES = 8 MiB`) | **42.8 s** (1.9× slower) | 1.49 s (1.2× slower) | 15122806 |
| GC switched off during the run | 21.6 s | 0.96 s | 15122806 |

### Causes

1. **Memory bandwidth of one NUMA domain: the main cause.** A threaded copy reaches 28 GB/s at
   4 threads and only 33 GB/s at 16 in one domain, and the batched FFT, which is what the solve
   mostly does, goes from 19 to 12 ms. The whole TV solve takes the same time at 4 and 16 threads
   (21.0 vs 22.3 s), and the same 16 threads spread over four domains, with identical code, take
   14.0 s. Every stored 16-thread row was measured under the one-domain placement, so the "stops
   after 2-4 threads" curve is the placement's, not the code's. BART runs under the same
   placement; it gains more because its 1-thread time is 4.5× Ristretto's (187.7 vs 42.0 s).
   Inference, not measured: BART is therefore compute-bound for longer and meets the same ceiling
   later (70 s at 16 threads vs Ristretto's 25.5 s).
2. **Coil-level parallelism is capped at 8.** The normal operator is `broadcast → SpreadingBatchOp
   over the 8 coils → reduce`, each coil running `DiagOp → DFT → mask → DFT' → DiagOp'` serially
   in one task. With 16 threads at most 8 work in that phase; the profiles show threads 9-16 idle
   during it, and per-coil FFT tasks scale no better than the batched FFT (14.4 vs 12.4 ms at 16
   threads). This matters only once bandwidth stops being the limit (spread placement).
3. **Not causes**, by the one-change runs: GC (0.6 s of 22 s for TV; switching it off changes
   nothing for TV, saves 0.25 s of 1.21 s for CG-SENSE); the threaded TV gradient (serial
   `Variation` gives 21.2 vs 22.1 s, within noise); serial BLAS in CG (threading it makes TV 1.9×
   slower, which confirms the serial-BLAS default); FFT planning (0.1 s at 16 threads, where the
   automatic rule picks `ESTIMATE`; at 1 thread CG-SENSE pays 1.5 s of 3.9 s for `MEASURE` plans,
   which the rule chose correctly per the docs' 128³ table).
4. **Observed, not resolved.** (a) Serial phases run slower when 15 other cores are active: the TV
   gradient on the main thread takes 4.2-4.4 s at 16 threads even when it never threads, against
   2.0 s at 1 thread; candidates are the all-core clock (EPYC 7763 3.5 GHz boost vs 2.45 GHz base)
   and bandwidth taken by the parallel regions it overlaps. Not tested. (b) With memory interleaved
   over four domains, the solver's serial vector updates take 6.2 s of the 14.0 s (remote memory
   for a single thread); `axpy!` on threaded OpenBLAS is 11× faster there (0.8 vs 8.7 ms) while it
   is not faster in one domain. (c) In the full-size profiles, worker threads spend about
   2-3 thread-seconds per solve in the unfused `NormalGetIndex` `mul!` (`fill!` + masked
   `setindex!`), although the per-coil chain of the 32³ small case fuses its mask; which operator
   takes that path at full size was not traced.
5. **The knee's 4-thread run (66 s vs 44 s at 1 thread).** Not settled from the stored files:
   `large_datasets.sh` pins with `numactl --physcpubind=… --preferred=<domain>` (preferred, not
   bound, so pages can spill to another domain), the three thread counts run at the same time on one
   node, and the result files record the host but neither the CPUs nor the memory placement. A
   per-run `numastat -p` and the pinned CPU list in the Part 6 large-dataset run would answer it.

### Proposed fixes and their likely gain

| fix | evidence | estimated gain |
|---|---|---|
| Benchmark and recommend placing a single large reconstruction across NUMA domains (`numactl --interleave=all`, threads spread), and state in the paper that the 16-thread rows are one-domain | spread vs one domain, same code | TV 3D 22 → 14 s (1.6×), CG-SENSE 1.2 → 0.8 s; the knee likely more (its arrays are 17× larger) |
| When threads > coils, give each coil's FFT the spare threads (FFTW threads per coil plan) or split the coil chain into spatial slabs | idle threads 9-16 during the coil phase | in one domain little (bandwidth-bound); spread, up to the FFT's share of 4.5 s × (1 − 8/16) ≈ 2 s of 14 s |
| Thread the ADMM/CG vector updates with Julia's own threads (FastBroadcast `@..` with `thread = true` over the 134 MB vectors) instead of serial BLAS, size-gated | 6.2 s serial updates in the spread run; OpenBLAS's threaded `axpy!` 11× faster there but its workers spin and cost 1.9× overall | spread: ≈ 5 s of 14 s (to ≈ 9-10 s); one domain: ≈ 1 s |
| Fuse the full-size mask that falls back to `NormalGetIndex`'s `fill!` + `setindex!` | 2-3 thread-seconds per solve in that `mul!` | ≈ 0.2-0.4 s per TV solve; small |

## Part 4. Fusion switch and ablation

### 4a. Run-time switch for pointwise fusion (done)

- AbstractOperators fork, branch `perf/fused-pointwise` (PR hakkelt/AbstractOperators.jl#50):
  `AbstractOperators.POINTWISE_FUSION[] = false` makes `Compose` run every operator of a
  fusable run on its own, through its own buffer. Documented in the fork's docstring and at the
  end of `docs/src/performance.md`; test item "Pointwise fusion: POINTWISE_FUSION switches it
  off at run time" (forward and adjoint equal, buffers untouched when fused and all written when
  not).
- Re-vendored into Ristretto on branch `paper-measurements` (PR hakkelt/Ristretto.jl#16). The
  `:operators` and `:encoding` test items pass (31 of 31, login node).

### Odd-length fftshift as a phase ramp (added on request, included in every paper run)

- AbstractOperators fork, branch `feat/odd-fftshift-phase-ramp` (PR hakkelt/AbstractOperators.jl#61),
  re-vendored into the same Ristretto PR (integration `6528049f`, Ristretto `5faaa2e41`).
- An odd-length FFTShift/IFFTShift next to a DFT becomes a `DiagOp` holding the phase ramp
  exp(σ·2πi·s·k/N) on the other side of the transform, instead of a shift that copies the
  array on every application. Even lengths keep `SignAlternation`.
- Two existing bugs in the even path were fixed on the same branch:
  - With shifts on both sides of a DFT, `fftshift_op`/`ifftshift_op` returned the negated
    operator for lengths ≡ 2 (mod 4). This was checked on the unmodified `unified-threading` for
    N = 6 and 10. In Ristretto it flips the image phase by π for such a dimension; magnitudes
    are unchanged.
  - An even-length shift along a dimension the DFT does not transform became a
    `SignAlternation`, which gives a wrong result.
- Checks: the fork's FFTW test items pass on the branch (1,916) and on the rebuilt integration
  (4,071). Ristretto's `:operators`/`:encoding` items pass (31 of 31). A 127² CG-SENSE
  reconstruction gives the same NRMSE as before (0.386919), and its encoding operator contains
  no shift.
- Login node, 1 thread, 8 coils: the shifted operator's overhead over the bare DFT is 0.64 ms
  against 2.4 ms for the old shift at 255², and about equal at 127² (0.42 vs 0.37 ms). This is
  indicative only.

### 4b. Ablation

## Part 5. Problem size and memory

## Part 6. Consistent rerun

Decisions (2026-11-16): one-domain placement as in `matrix.sh`; current toolbox releases; no
MKL runs; the odd-length fftshift change is included.

| toolbox | version for Part 6 | where |
|---|---|---|
| Ristretto | `paper-measurements` (`5faaa2e41` or later; PR #16) | submodule of this branch |
| BART | v1.0.01 (`381039c4`), OpenBLAS build **without CUDA** (the earlier CPU builds were CUDA builds), and a CUDA 12.4 build for the A100 | `/project/c_mrrecon/bart-v1.0.01/{openblas,cuda}` |
| SigPy / MRpro (CPU) | SigPy 0.1.27, MRpro 0.261015, torch 2.15.0+cpu, NumPy 2.5.5 | `/project/c_mrrecon/venvs/py314-paper` |
| SigPy / MRpro (GPU) | the same, torch 2.15.0+cu132 (torch 2.15 GPU wheels exist only on the cu132 index), CuPy 14.2.0 | `/project/c_mrrecon/venvs/py314-gpu-paper` |

BART v1.0.01 build notes:
- Its Makefile defines `FFTW_H` but never adds it to `CPPFLAGS`, so an FFTW outside `/usr` needs
  its include path in `Makefile.local`.
- The CUDA build needs GCC 12 (`gcc-toolset-12`), because nvcc 12.4 rejects GCC 13's `floatn.h`.
- Script: `build_bart_1001.sh` in the working directory.
