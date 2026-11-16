# Measurements for the Ristretto.jl paper

This branch (`paper-measurements`) collects the measurements and source checks for the
Toolbox Article on Ristretto.jl. It is based on `gpu-tensor-rerun` (draft PR #1), which is
`master` plus the GPU rerun and the TENSOR-NFFT radial CPU rows, so the stored snapshots it starts
from are the newest ones.

## Not done or not verified

(Filled in as the work proceeds.)

## Part 1. Claims about other toolboxes

BART source: tag `v1.0.00` (commit `37f3c5f0`, 2026-02-18) cloned from
`codeberg.org/mrirecon/bart` into the scratch area; paths below are relative to its root.
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
   thread setting; PyWavelets does not thread. Consistent with the flat 1-16 thread rows.
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

   No error. RegularizedLeastSquares 0.16.12 and 0.16.13 differ only in `CGNR.jl` (start value),
   so this holds for 0.16.12 as well. If it failed for you, it was not these solvers; one thing a
   user meets without noticing is the second column: MRIReco's default `params[:rho] = 0.05`
   (`RecoParameters.jl:9`), an ADMM penalty, becomes the step size of all three.
10. **Silently dropped options.** `params[:kwargWarning] = false` (`MRIReco/src/Reconstruction/
    RecoParameters.jl:12`) reaches `createLinearSolver(...; kwargWarning, kwargs...)`, whose
    `filterKwargs` keeps only the solver constructor's keywords and warns only when asked
    (`RegularizedLeastSquares/src/RegularizedLeastSquares.jl:267-289`). Measured, same script:
    `params[:iteration] = 3` (for `:iterations`) gives an image **bit-identical** to the run
    without it (max |Δ| = 0; the solver runs MRIReco's default 30, not 3) and logs nothing but an
    unrelated `Info` about `enc2D`. With `params[:kwargWarning] = true` the same call logs
    `Warn: The following arguments were passed but filtered out: absTol, tolInner,
    densityWeighting, S, iteration, reco, iterationsCG, vary_rho.` The smallest example:

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
| BART v1.0.00, **static** (`SLINK=1`, OpenBLAS 0.3.15, FFTW 3.3.10 with threads, no CUDA/MKL), stripped | **33.7 MB** (33,655,648 B; 56.7 MB unstripped) | one file; `ldd`: "not a dynamic executable"; `file`: "statically linked" |
| BART v1.0.00 as used by the suite (`~/c_mrrecon/bart-v1.0.00/openblas/bart`), dynamic | 5.3 MB binary + **893.8 MB** of shared libraries | of which 844.5 MB are CUDA (cuFFT 292.9, cuBLASLt 441.1, cuBLAS 109.8, cudart 0.7); without them 49.3 MB (OpenBLAS 36.4, FFTW 3.7, libgfortran 2.6, libc/libm/libstdc++ …) |
| same, MKL build | 5.2 MB + 971.4 MB | MKL 116.9 MB + the same CUDA libraries |
| Ristretto JuliaC bundle (`juliac --output-exe --bundle`, no `--trim`) | **1.32 GB** (1,322,813,979 B, 62 files) | executable with the compiled image 989 MB, `lib/` 327 MB (libjulia, LLVM, BLAS, …), artifacts 6.2 MB |
| Ristretto package image (`compiled/v1.13/Ristretto/*.so` + `.ji`) | 372 MB + 2.3 MB | the precompiled native code of Ristretto and its vendored packages |
| a depot holding only what `Pkg.add(url = Ristretto.jl)` installs, precompiled | **847 MB** (4,250 files) | compiled caches 575 MB, artifacts 205 MB, packages + clones 48 MB, registry 19 MB; Julia 1.13.1 itself is another 1.10 GB |
| venv with SigPy (`numpy sigpy numba scipy`) | **370 MB** (4,221 files) | + CPython 3.14.3, 108 MB |
| venv with MRpro (CPU PyTorch 2.15.0 + mrpro 0.261015) | **1.32 GB** (23,094 files) | PyTorch alone 770 MB; + CPython 108 MB |

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
  copied in first; script `depot_build.jl` in the scratch area).
- Venvs: `uv venv -p cpython-3.14.3`, then `uv pip install --link-mode=copy numpy sigpy numba scipy`;
  for MRpro `torch` from the PyTorch CPU index, then `mrpro`. **Caveat:** `mrpro` pulls
  `torchvision` from PyPI, whose build does not match the CPU `torch` (`import mrpro` fails with
  "operator torchvision::nms does not exist"); the size above includes that torchvision.

## Part 3. Thread scaling of single large problems

**Runs:** `shepp_logan_3d_8ch_cartesian` (128³, 8 coils, OpenBLAS), the comparison suite's Ristretto
rows (TV: ADMM 20×10 CG; CG-SENSE: 10 CGNR), timed with `time_run`, then profiled once (Julia's
sampling profiler, 5 ms, every thread). Ristretto at the submodule pin `c949d8e` (clean; vendored
AbstractOperators `94b9c2b5`, ProximalAlgorithms `bbd8bd51`, ProximalOperators `5c38fbbb`,
StructuredOptimization `40720478`, NFFT `5b8ad7ae`, OperatorCore `ff43eb93`). AMD EPYC 7763,
exclusive node, one run at a time. "One domain" = `numactl --cpunodebind=1 --membind=1` (16 cores,
the placement `matrix.sh` gives every task); "spread" = cores taken round-robin from NUMA nodes 0-3,
memory interleaved over them. Jobs: 15122806 (`cpu-short`, 64-core node x1001c1s2b0n1), 15123878
(`cpu`, x1000c3s4b0n1), 15123914 (`cpu`, x1000c0s5b0n0). Scripts and every JSON:
`benchmark/thread_scaling/` (`probe.jl`, `kernels.jl`, `probe.sh`, `results/<job>/`).

The probe reproduces the stored numbers: TV 41.5 / 21.0 / 22.3 s at 1 / 4 / 16 threads (stored
41.97 / 25.72 / 25.54), CG-SENSE 3.87 / 1.57 / 1.21 s (stored 4.06 / 1.84 / 1.19).

### Attribution (job 15123878)

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

Kernels on the case's own arrays (`kernels.jl`, job 15122806, one domain unless noted):

| threads | copy bandwidth | batched 3D FFT, 8 coils | 8 per-coil FFT tasks | `axpy!` serial / threaded BLAS |
|---:|---:|---:|---:|---:|
| 1 | 8.5 GB/s | 60.4 ms | 59.9 ms | 10.4 / 10.4 ms |
| 4 | 28.2 GB/s | 19.0 ms | 18.8 ms | 10.5 / 8.5 ms |
| 16 | 32.6 GB/s | 12.4 ms | 14.4 ms | 10.4 / 8.6 ms |
| 16, spread over 4 domains | 40.6 GB/s | 6.7 ms | 9.0 ms | 8.7 / 0.8 ms |

### One-change experiments (TV at 16 threads unless noted; times are the timed minimum)

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
   placement; it gains more because its 1-thread time is 4.5× Ristretto's (187.7 vs 42.0 s), so it
   is compute-bound for longer and meets the same ceiling later (70 s at 16 threads vs Ristretto's
   25.5 s).
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

## Part 5. Problem size and memory

## Part 6. Consistent rerun
