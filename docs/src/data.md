# Data and reproduction

## Result files

Every table of this site is generated from these files when the site is built (`docs/tables.jl`):

| file | content |
|---|---|
| `benchmark/comparison/results/benchmark_<backend>_<n>threads.json` | a snapshot: the latest row per (case, category, method, toolbox) of one backend and thread count, with a `run` record (dates, nodes, CPU, GPU, Julia, BLAS, toolbox versions) |
| `benchmark/comparison/results/machines/<machine>/` | the same, for a machine other than Komondor |
| `benchmark/comparison/results/lambda/<case>.json` | calibrated λ, ρ and race target per method and toolbox, with the calibration curves |
| `benchmark/sizes/results/15137010/` | the problem-size runs and peak-memory files |
| `benchmark/sizes/footprint.json` | installation sizes |
| `benchmark/startup/results.json` | start-up timings, with every repetition |
| `benchmark/ablation/results/15137089/` | ablation and first-solve files |
| `benchmark/thread_scaling/results/` | the 3D thread-scaling probes, with sampling profiles per thread |
| `benchmark/paper_part6/large_datasets/` | the large-dataset runs and their logs |

A snapshot row holds `time_ms` (minimum of the timed runs; -1 when not measured), `nrmse_gt` (the error
of the case, see [Error measures](@ref)) and `nrmse_ristretto` (the NRMSE against Ristretto's image of
the same row). An accuracy-race method records its target and the iteration count reached, as in
"Total Variation (NRMSE≤0.0805, 80 it)".

## Calibrated regularization weights

λ (and ρ for ADMM solvers) per toolbox, as each case's file records them. The values are on each
toolbox's own scale and are not comparable across columns.

```@eval
Main.Tables.md(Main.Tables.lambda_markdown())
```

## Reproducing a run

The repository pins the measured Ristretto as a submodule. With the toolboxes installed (see the
[README](https://github.com/hakkelt/RistrettoBenchmarking#readme) and the
[suite's README](https://github.com/hakkelt/RistrettoBenchmarking/blob/master/benchmark/comparison/README.md)):

```sh
julia --project=benchmark/comparison -t 8 benchmark/comparison/scripts/run_all.jl --threads=8 --data=all
julia --project=benchmark/comparison benchmark/comparison/scripts/export_snapshot.jl
julia --project=docs docs/make.jl
```

On a SLURM cluster, `benchmark/slurm/matrix.sh` runs every thread count in its own NUMA domain; on a
workstation, `benchmark/local/run_comparison.sh` or `.ps1` pins each run to its own cores. Results of
a workstation are exported with `export_snapshot.jl --machine=<name> --host=<hostname>` and appear on
these pages as a machine of their own.
