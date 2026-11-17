# Ablation

What each of Ristretto's design choices contributes, switched off one at a time at run time. All
variants of a case run in one process bound to one NUMA domain; each is timed with the suite's
protocol. Iterations and λ are the catalog defaults (20 iterations; ADMM for TV and low rank, FISTA
for ℓ₁-wavelet), not the calibrated λ of the comparison, so the errors here do not match the comparison
tables. Raw files:
[`benchmark/ablation/results/15137089/`](https://github.com/hakkelt/RistrettoBenchmarking/tree/master/benchmark/ablation/results/15137089).

```@eval
Main.Tables.md(Main.Tables.ablation_meta_markdown())
```

The variants:

- **no_task_splitting:** `disable_task_splitting = true`; the multi-slice case is solved jointly instead
  of as 12 slice tasks.
- **no_fusion:** `AbstractOperators.POINTWISE_FUSION[] = false`; every operator of a fusable chain
  runs on its own, through its own buffer.
- **no_inner_threading:** where the default splits the case into tasks, the tasks run in parallel
  and each is serial; where it is one task, `threaded = false`.
- **fft_estimate / fft_measure:** `fft_planning = :estimate` or `:measure` instead of the automatic
  choice.

```@eval
Main.Tables.md(Main.Tables.ablation_markdown())
```

## Precompile workload

Load time (`using Ristretto` and the harness), first solve (including compilation) and second solve, in
fresh processes, with Ristretto's precompile workload and without it (compiled into a depot of its own).

```@eval
Main.Tables.md(Main.Tables.first_solve_markdown())
```

What the runs show:

- **Task splitting** pays most with a stopping tolerance, since each slice stops on its own: the joint
  multi-slice solve with `reltol = 1e-3` is 1.6× slower at 1 thread and 2.1× at 8.
- **Fusion** matters for the memory-bound cases: 3D TV (1.12× at 1 thread, 1.38× at 8) and multi-slice
  TV at 8 threads; not for the radial and cine cases, whose time is in the NFFT or the SVD.
- **FFT planning:** `:estimate` is up to 5.8× slower on the radial cases, `:measure` up to 5.3× slower
  on the 2D ℓ₁-wavelet case, a 50-80 ms solve its planning dominates. The automatic choice is right in
  most rows; on multi-slice at 1 thread `:measure` is faster than it.
- **Precompile workload:** `using` takes 1.1-1.5 s longer; the first solve is 5-16 s shorter.
- Differences below about 10% in rows under 100 ms are within run-to-run noise.
