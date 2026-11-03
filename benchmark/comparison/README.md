# benchmark/comparison/

Cross-toolkit MRI reconstruction benchmark: Ristretto vs BART / SigPy / MRIReco / MIRT / MRpro, on the
cases of Ristretto's benchmark case catalog (`Ristretto/benchmark/utils/` in the submodule, see [its README](../../Ristretto/benchmark/README.md)),
at matched effort or matched accuracy. Comparing one checkout of Ristretto against another is the Ristretto
harness's job (`Ristretto/benchmark/run.jl`), not this suite's.

## Python toolkits

SigPy and MRpro run in-process through PythonCall, in the interpreter `RISTRETTO_BENCH_SIGPY_PYTHON` in
`benchmark/slurm/site.env` names (CondaPkg's `Null` backend: no environment of its own is built).
It needs Python ≥ 3.10 (MRpro's floor), and PythonCall loads its `libpython`, so on a cluster it
must exist on the compute nodes too: a system Python of the login node may not. A standalone build
on shared storage is. A CPU-only environment:

```sh
UV_PYTHON_INSTALL_DIR=/path/to/uv-python uv python install 3.14
uv venv -p /path/to/uv-python/cpython-3.14.*/bin/python3.14 /path/to/venvs/py314
uv pip install -p /path/to/venvs/py314 numpy sigpy numba scipy
uv pip install -p /path/to/venvs/py314 torch torchvision --index-url https://download.pytorch.org/whl/cpu
uv pip install -p /path/to/venvs/py314 mrpro
```

PythonCall rather than PyCall because the Ristretto solves between Python calls are multithreaded:
PyCall frees a Python object from whichever thread Julia's GC finalizes it on, which segfaults the
process at 8 and 16 threads, while PythonCall defers such a free to the thread that holds the GIL.
MRpro's rows are skipped when it does not import. SigPy is single-threaded on the CPU; MRpro
threads through PyTorch (`torch.set_num_threads`) and finufft (`OMP_NUM_THREADS`).

## Sections

Each `scripts/run_<section>.jl` is a standalone, runnable Julia script (`include`s `_setup.jl`,
`_toolkits.jl` and `_methods.jl`). It loops over the catalog cases its method family applies to and
calls `run_method_rows!` per (case, method): Ristretto's row is timed with the same `ristretto_reconstructor`
call the Ristretto harness times, then every competitor that `supports` the pair. No section prepares
data of its own. Every toolkit gets the same prepared case, rearranged to its layout by
`_toolkits.jl`.

| section | cases × methods |
|---|---|
| `base` | adjoint on the Cartesian cases |
| `noncart` | DCF-weighted gridding on the radial cases, plus Ristretto at MRIReco's NFFT operating point |
| `cgsense` | CG-SENSE on every multichannel case |
| `sparsity` | isotropic TV, anisotropic TV, each by ADMM and by PDHG, L1-wavelet, TGV on the static cases (TGV 2D only; radial cases get the TVs and no wavelet or TGV), matched effort |
| `dynamic` | global / locally low rank, temporal TV (ADMM and PDHG) on both cine cases, matched effort |
| `kspace` | GRAPPA on the regularly undersampled variant of the 2D and multislice cases (Ristretto only — no cross-toolkit row exists, see the script's header) |
| `accuracy_race` | time-to-target-NRMSE per toolkit, the fair comparison (see the script's header for why the other sections' fixed-iteration-count numbers are not directly comparable across toolkits) |

`--data=synthetic` (default), `real` or `all` picks which catalog cases the sections iterate; the
real-data analogues use the λ of their synthetic case. Unsupported (toolkit, case, method)
combinations are skipped; the table in `supports` (`_toolkits.jl`) lists what each toolkit covers.

`scripts/run_all.jl` runs every section as its own subprocess (they each define top-level `const`s,
so they cannot share a process) and is the normal entry point:

```sh
julia --project=benchmark/comparison -t N benchmark/comparison/scripts/run_all.jl --threads=N [--use-mkl]
```

## GPU

`--device=cuda` runs every section on an NVIDIA GPU instead, for the toolkits that reconstruct on
one, under the same row labels with a `(CUDA)` suffix and recorded under backend `cuda`:

| toolkit | on the GPU |
|---|---|
| Ristretto | the acquisition moved with `adapt(CuArray, ·)`; everything runs on the device |
| BART | `pics -g`, from the build `RISTRETTO_BENCH_BART_CUDA` names; not the direct rows, which are not timed on the CPU either, nor the PDHG rows: BART 1.0.01's `pics -a --precond -g` aborts in `mem_device_free`, and without `--precond` `-a` is a different solver from the one the CPU rows time |
| SigPy | CuPy, with the k-space, maps and trajectory on `sigpy.Device(0)`. Its wavelet transform is PyWavelets on the host, so its L1-wavelet row copies every iterate to the host and back |
| MRIReco | `arrayType = CuArray`, through RegularizedLeastSquares' and NFFT's GPU extensions |
| MRpro | its tensors on `"cuda"`; cufinufft for the NUFFT |
| MIRT | none |

Every row is timed from host data to a host image: the copies to the device and back are inside
the timed region for every toolkit, since BART cannot be timed any other way. A BART process also
creates its CUDA context and loads cuFFT and cuBLAS on every call, which an in-process toolkit
does once, in its warm-up; that cost (`BART_GPU_INIT`, measured on an 8×8 problem) is subtracted.
The process start and the file I/O are not in BART's times at all: each is the `Total Time` that
`pics` reports itself. After each toolkit's row the memory pools of CUDA.jl,
CuPy and PyTorch are emptied, so each toolkit starts with the whole device. λ and ρ are the CPU
calibration's: the problem is the same, and so is the precision (`ComplexF32`).

CUDA.jl is not a dependency of this environment. A GPU run adds it through a GPUEnv overlay,
persisted in `gpu_env/` (gitignored) and reused until this environment changes. SigPy and MRpro
need CuPy and a CUDA build of PyTorch, which the CPU interpreter does not have, so a GPU run uses
the interpreter `RISTRETTO_BENCH_GPU_PYTHON` names when it is set:

```sh
uv venv -p /path/to/uv-python/cpython-3.14.*/bin/python3.14 /path/to/venvs/py314-gpu
uv pip install -p /path/to/venvs/py314-gpu torch torchvision --index-url https://download.pytorch.org/whl/cu128
uv pip install -p /path/to/venvs/py314-gpu numpy sigpy numba scipy cupy-cuda12x mrpro cufinufft pytorch-finufft
```

The BART build needs `CUDA = 1`, OpenBLAS and the device's architecture in its `Makefile.local`
(`GPUARCH_FLAGS = -gencode arch=compute_80,code=sm_80` for an A100). A toolkit whose GPU build is
missing is skipped with a warning.

On Windows two things differ, both because every toolkit shares one process. Windows matches an
already loaded DLL by its file name, so PyTorch's CUDA libraries resolve to the ones CUDA.jl loaded
first (`cufft64_11.dll`, `cublas64_12.dll`, ...): PyTorch's `torch\lib\cufftw64_11.dll`, which it
preloads but does not call, fails against CUDA.jl's cuFFT and has to be renamed away (to
`cufftw64_11.dll.disabled`). And the PyTorch and CuPy builds have to suit the NVIDIA driver: on a
driver of CUDA 12.2 (537.58), PyTorch's CUDA 12.6 builds cannot create a context and CuPy 14's
runtime is too new, so that machine runs `torch==2.5.1` from the `cu121` index with
`cupy-cuda12x==13.6.0`, CuPy taking its cuBLAS/cuFFT/NVRTC from `torch\lib` and its headers from an
`nvidia-cuda-runtime-cu12` wheel (`CUDA_PATH`); the venv's `sitecustomize.py` sets both up. A recent
driver needs none of that. BART runs inside WSL 2 there (see `benchmark/local/bart_wsl/`), built with
CUDA from conda-forge (`cuda-nvcc`, `libcufft-dev`, `libcublas-dev`; GCC 14 needs CUDA ≥ 12.8).

A GPU run has one host thread and OpenBLAS as the host BLAS (`-t 1 --threads=1`, no `--use-mkl`),
and refuses to start otherwise. The device does the work, and MRIReco's GPU path is wrong with more than one
Julia thread: its operators issue kernels from parallel tasks on unordered CUDA streams, which
returned different, wrong images on every call (NaN on the radial and L1-wavelet rows), while at
one thread every row matched the CPU. The SLURM script passes those flags itself:

```sh
benchmark/slurm/submit.sh comparison_gpu.sh --sections=cgsense,sparsity
```

A GPU run times a (case, method) row only when at least one other toolkit supports it on the GPU
(`has_gpu_rival` in `_methods.jl`, read from the static support table, so the set of rows does not
depend on which builds a machine has): the GPU rows are there to compare Ristretto with another
toolkit. That is every method of every section but `kspace`, whose GRAPPA runs on a host copy and
which no other toolkit implements. The non-Cartesian section's second Ristretto operating point
(`m = 3, σ = 1.25`) runs on the device too, against MRIReco's GPU row at the same point. A row whose
Ristretto reconstruction fails on the device (out of memory, on a small GPU) is skipped whole, with
a warning, rather than leaving the competitors' rows unscored.

On a workstation the local runners take the GPU as one more backend, one host thread and every
section but `kspace` (see the top-level `README.md`, *Local runs*):

```powershell
powershell -ExecutionPolicy Bypass -File benchmark\local\run_comparison.ps1 --backends=cuda
```

## Filtering a rerun

Three independent filters, all stackable, all forwarded from `run_all.jl` to each section
subprocess:

| flag | narrows to |
|---|---|
| `--sections=sparsity,dynamic` | specific sections instead of all seven |
| `--data=all` | which catalog cases: `synthetic` (default), `real` or `all` |
| `--cases=shepp_logan_2d,low-rank` | case-insensitive substrings matched against a catalog case id, a section, or a method label — `shepp_logan_2d` runs the three 2D Shepp-Logan cases, `low-rank` every low-rank row across `dynamic` and `accuracy_race` |
| `--frameworks=BART` | gates only the *competitor* toolkits (SigPy/BART/MRIReco/MIRT/MRpro); Ristretto's own solve always runs — it is the reference every other framework's `nrmse_ristretto` is computed against, and it is cheap next to whichever toolkit is under suspicion |

```sh
# re-verify one suspect BART timing without paying for the other three toolkits or 7 other sections
julia --project=benchmark/comparison -t 16 --use-mkl benchmark/comparison/scripts/run_all.jl \
    --threads=16 --use-mkl --sections=dynamic --cases=low-rank --frameworks=BART
```

Every section checks `should_run` / `should_run_framework` (`_setup.jl`) *before* paying for a
solve, so a narrow filter is actually cheap, not just a smaller printout.

`RISTRETTO_BENCH_SMALL=1` runs every section on the shrunken catalog in a few minutes, for a smoke test
on a login node:

```sh
RISTRETTO_BENCH_SMALL=1 julia --project=benchmark/comparison -t 4 benchmark/comparison/scripts/run_all.jl --threads=4 --frameworks=none
```

## Results storage (`Ristretto/benchmark/utils/results_store.jl`)

Every recorded run is its own immutable JSON file under `results/runs/`, never overwritten —
concurrent writers (different SLURM nodes, or a login-node smoke test run alongside a cluster job)
cannot collide with each other by construction, no locking needed, on any filesystem. `flush_results!`
(inside every section script) writes one such file after *each case*, not just once at the end, so
a crash partway through a long section keeps whatever already finished. `source` (`"slurm"` on this
cluster's compute nodes, `"other"` everywhere else — see `ResultsStore.source_tag`) is recorded on
every run, so a login-node measurement stays visibly distinct from a cluster one instead of silently
looking the same. Every row carries its `case_id`, `data_source` and `schema_version` (2); rows
written before the case catalog (schema 1) are skipped when reading, since their problems no longer
exist.

`results/runs/` is gitignored working data. Nothing merges it automatically — reading it back is a
query, done fresh each time:

- **`query_results.jl`** — prints the latest row per (backend, threads, case, category, method,
  framework), preferring `source = "slurm"`. Filter with `--backend=`, `--threads=`, `--case=`,
  `--category=`, `--method=`, `--source=`.
  ```sh
  julia --project=benchmark/comparison benchmark/comparison/scripts/query_results.jl --source=slurm --case=shepp_logan_2d
  ```
- **`export_snapshot.jl`** — writes `results/benchmark_<backend>_<n>threads.json`, the committed
  snapshot of a full cluster run, one per (backend, threads) pair found, from the latest
  `source = "slurm"` row per case. A toolkit's rows measured with an older release than its
  latest run's are left out, also where the new release recorded no row (a solver that no longer
  reaches the accuracy target), so a table never mixes releases. A run limited to some competitors
  (`--frameworks=`) still times Ristretto as their reference; those Ristretto rows are left out too,
  so rerunning one competitor never replaces Ristretto's numbers. Run this after any cluster rerun
  that should update the committed numbers:
  ```sh
  julia --project=benchmark/comparison benchmark/comparison/scripts/export_snapshot.jl
  ```

## Calibration

`scripts/calibrate_lambda.jl` fits each toolkit's own λ per case. It sweeps a log grid (8 points, 6
for the heavy cases) at 30 outer iterations. Ristretto's best NRMSE is the target, and every other toolkit
gets the λ whose NRMSE is closest to it. So every section compares toolkits at matched accuracy
rather than at a nominally equal but differently scaled λ.

A row that runs a fixed-penalty ADMM also sweeps ρ, over the decades `RHO_DECADES` (default
`-2,-1,0,1,2`) around the toolkit's default: `admm_rho(c)` for Ristretto, relative to `‖𝒜‖²`, and
`CMP_RHO` for the others, absolute in their own operator scaling. Each toolkit keeps the ρ at which
it reaches its best NRMSE (the `rho` table, read back by `load_rho`), and its λ is picked on that
ρ's curve; a best ρ at the grid's edge is logged. Without a calibrated ρ, rows fall back to those
defaults.

`--frameworks=ristretto,bart,...` recalibrates only the named toolkits and `--methods=tv,...` only the
named methods. The curves of the other toolkits are read back from the case's file, so the target,
the picks and `race_target` are always recomputed over every toolkit calibrated so far, and the
file is merged under a lock, so several processes can calibrate one case at once.

A toolkit's optimum can lie outside the shared grid (BART's and SigPy's radial TV λ lies above
it), so each axis grows past an edge holding the best point, up to `MAX_GRID_EXTENSIONS` (4) steps.
`--resume` reuses the points already stored for the toolkits being calibrated and measures only
the missing ones, which makes widening a finished calibration cheap. Every point is written to the
case's file as soon as it is measured, so a job cut off by its time limit loses nothing, and under
`--resume` a toolkit's new points are added to its stored ones. A slow toolkit can therefore be
split over several processes, one ρ decade each (`RHO_DECADES=-1` and so on), or one share of the
λ grid each (`LAMBDA_SHARD=i/n` measures the points whose index is `i` modulo `n`), followed by one
`--resume` run over the full grid that measures only the extensions an edge optimum still needs.
SigPy's 3D TV (about 20 minutes a point) and radial cine rows (about 7) were calibrated by ρ
decade, and its 3D PDHG TV by λ share.

Results go to `results/lambda/<case id>.json`, together with `race_target`: the worst toolkit's best
NRMSE × 1.10, the target `run_accuracy_race.jl` races to. The ADMM and PDHG rows of one TV race to
the larger of their two targets, so their times are to the same accuracy. `load_lambda` falls back
from a case to its synthetic analogue, then to the pre-catalog `results/lambda_calibration.json`,
then to the default
in `Ristretto/benchmark/utils/ristretto_methods.jl`. Under `RISTRETTO_BENCH_SMALL=1` the files go to `results/lambda_small/`
(gitignored) instead. Rerun calibration for a case whose problem or regularization changed. It
takes one SLURM array task per case:

```sh
benchmark/slurm/submit.sh --array=0-6 calibrate.sh
```

## Real scanner data

The real-data analogues of the catalog cases, where they come from and how their references are
built, are described in [Ristretto's `benchmark/README.md`](../../Ristretto/benchmark/README.md#real-data).
