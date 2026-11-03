# RistrettoBenchmarking

Benchmarks of [Ristretto.jl](https://github.com/hakkelt/Ristretto.jl) against BART, SigPy,
MRIReco.jl, MIRT.jl and MRpro, and a comparison of their features. The results are published at
<https://hakkelt.github.io/RistrettoBenchmarking/>.

Every published number is a snapshot: it records when it was measured and which release of each
toolbox it measured. The toolboxes keep changing and these benchmarks are not re-run on every
release.

## Layout

| path | what it is |
|---|---|
| `Ristretto/` | Ristretto.jl as a submodule, pinned to the commit that was measured; the case catalog (`Ristretto/benchmark/utils/`) comes from it |
| `benchmark/comparison/` | the cross-toolkit suite ([its README](benchmark/comparison/README.md)) and its committed snapshots (`results/`) |
| `benchmark/startup/` | start-up and first-solve cost of each toolbox in fresh processes ([its README](benchmark/startup/README.md)) |
| `benchmark/slurm/` | SLURM scripts; machine paths live in the untracked `slurm/site.env` (copy `site.env.example`) |
| `benchmark/local/` | the suite on one workstation or laptop, without SLURM |
| `docs/` | the site: Documenter pages that render the committed snapshots (`docs/benchmark_tables.jl`) |

## Getting started

```sh
git clone --recursive https://github.com/hakkelt/RistrettoBenchmarking
cd RistrettoBenchmarking
cp benchmark/slurm/site.env.example benchmark/slurm/site.env   # then fill in BART, Python, data paths
julia --project=benchmark/comparison -e 'using Pkg; Pkg.instantiate()'
julia --project=benchmark/comparison -t 8 benchmark/comparison/scripts/run_all.jl --threads=8 --sections=base
```

`benchmark/comparison/Project.toml` takes Ristretto from the submodule (`[sources]`), so the
Ristretto that runs is the one pinned there. To measure a newer Ristretto, move the pin and commit
it with the results it produced:

```sh
git -C Ristretto fetch origin && git -C Ristretto checkout origin/master
git add Ristretto
```

## Local runs: `benchmark/local/`

`run_comparison` runs `benchmark/comparison/scripts/run_all.jl` once per (thread count, backend,
BART mode, section) on one machine, each run pinned to its own physical cores, with a resumable unit
list per session under `benchmark/results/local/`; `units_report` prints that list. `quiet_run`
wraps it in a quieter machine (services stopped, CPU clock fixed, turbo off) with a status screen,
and restores everything afterwards. Each script's header documents its flags.

| Linux (`.sh`) | Windows (`.ps1`, PowerShell 5.1+) |
|---|---|
| pins with `numactl`/`taskset` | starts each run with a process affinity mask (`start /affinity`); `_setup.jl` gives each Julia thread its CPU as ideal processor only (ThreadPinning cannot pin there, and a hard per-thread mask made small problems 5-50x slower) |
| `quiet_run.sh` (root): stops KDE and the user's processes, switches SMT off/on per group, status on a VT | `quiet_run.ps1` (UAC elevation): stops background services, a temporary power scheme (100 % processor state, turbo and core parking off), status in its own window; SMT cannot be switched at runtime, so physical-core runs leave the siblings idle; `--dry-run` shows what it would change, `--restore` undoes a run whose window was closed |
| temperature from hwmon | temperature from ACPI thermal zones, only when elevated and where the firmware reports one |

```powershell
powershell -ExecutionPolicy Bypass -File benchmark\local\run_comparison.ps1 --prepare
powershell -ExecutionPolicy Bypass -File benchmark\local\run_comparison.ps1 --threads=1,2 --small
powershell -ExecutionPolicy Bypass -File benchmark\local\quiet_run.ps1 --threads=1,2,4
```

`--backends=cuda` adds the GPU comparison (`run_all.jl --device=cuda`, see
`benchmark/comparison/README.md`): one set of units at one host thread, whatever `--threads` says,
with no `kspace` unit and BART in its default mode only. These units get no affinity mask: masked
to one core, the CUDA driver's and the Python toolkits' host threads starved the Julia thread that
feeds the device, and a 13 ms CG-SENSE took 17 s. Its builds come from `slurm/site.env` like the
CPU ones: `RISTRETTO_BENCH_BART_CUDA` (on Windows a CUDA BART built inside WSL, behind its own
`bart.exe` whose `bart_wsl.target` names the build) and `RISTRETTO_BENCH_GPU_PYTHON`. With
`quiet_run`, pass `--smt-mode=off` so the units run once.

```powershell
powershell -ExecutionPolicy Bypass -File benchmark\local\quiet_run.ps1 --backends=cuda --smt-mode=off
```

## SLURM: `benchmark/slurm/`

Every script sources `slurm/common.sh`, which reads `slurm/site.env`, resolves the depot Julia
binary (the login-node `julia` wrapper fails inside a SLURM cgroup), and sets `TMPDIR=/dev/shm`
for BART's `.cfl` files and `KMP_BLOCKTIME=0`. Submit through `slurm/submit.sh`, from the
repository root. It uses the **test** partition (one hour) unless given `--production`, which
occupies a node for hours.

| script | what it runs |
|---|---|
| `matrix.sh` | `run_all.jl` on one exclusive node, each (threads, backend) configuration pinned to its own NUMA domain, several at a time; its header lists the flags |
| `calibrate.sh` | λ calibration (`comparison/scripts/calibrate_lambda.jl`), one case per array task |
| `comparison_gpu.sh` | `run_all.jl --device=cuda` on one GPU |

```sh
benchmark/slurm/submit.sh --production matrix.sh
benchmark/slurm/submit.sh --array=0-6 calibrate.sh
benchmark/slurm/submit.sh comparison_gpu.sh --sections=cgsense
```

## Publishing a snapshot

`benchmark/comparison/scripts/export_snapshot.jl` writes
`benchmark/comparison/results/benchmark_<backend>_<n>threads.json` from the run files of a full
cluster run (see the comparison README). Commit the snapshots together with the `Ristretto/` pin
they measured; the Pages workflow (`.github/workflows/pages.yml`) rebuilds the site on every push
to `master`. Build it locally with

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

## Open items

- **Startup suite: BART in the common loop.** `benchmark/startup/run.jl` special-cases BART
  (`tk.lang === :bart`) in five places. Its first and warm solves are both the end-to-end time,
  and its NRMSE is read from the last run's output outside the loop. A small wrapper script that
  runs `pics` and prints the same `RESULT` line as the other toolkits (with `pics`'s Total Time)
  would remove the branches. The setup time every child prints in that line is never recorded;
  either record it or drop it from the protocol.
- **Startup suite: shared case and solver definitions.** `benchmark/startup/solve_ristretto.jl`
  rewrites the acquisition, the FISTA/CGNR choice and the ℓ₁-wavelet regularizer instead of using
  `ristretto_acquisition`, `ristretto_algorithm` and `ristretto_regularizer` (`Ristretto/benchmark/utils/`).
  Those helpers take a `BenchCase` and bring the whole harness with them, which the child process
  deliberately avoids loading. `prepare.jl` likewise parses the λ file itself instead of using
  `_lambda_from` (`comparison/scripts/_methods.jl`). Possible fix: move the toolkit-independent
  parts into a file that loads only Ristretto, or at least test that the two definitions agree.
