# Thread scaling

## Every toolbox, 1 to 16 threads

Each toolbox's time at 1, 2, 4, 8 and 16 threads on Komondor, every thread count in one NUMA domain
(see [Threads and placement](@ref)), and the speed-up from 1 to 16 threads. The rows come from the
same snapshots as the other pages; their errors are there. In the accuracy race a row's iteration
count can differ between thread counts, when a run lands on the other side of the target.

### Accuracy race

```@eval
Main.Tables.scaling("Accuracy race")
```

### Static regularization

```@eval
Main.Tables.scaling("Sparsity")
```

### Dynamic regularization

```@eval
Main.Tables.scaling("Dynamic")
```

### CG-SENSE

```@eval
Main.Tables.scaling("CG-SENSE")
```

### Gridding

```@eval
Main.Tables.scaling("Non-Cartesian")
```

### Adjoint

```@eval
Main.Tables.scaling("Base")
```

### GRAPPA

```@eval
Main.Tables.scaling("K-Space")
```

```@eval
Main.Tables.others(m -> join((Main.Tables.scaling_markdown(m, c) for c in ("Accuracy race", "Sparsity", "Dynamic", "CG-SENSE")), "\n"))
```

## One large reconstruction

Where the time of a single large Ristretto reconstruction goes as threads are added: the 3D case
(Shepp–Logan, 128³, 8 coils), TV by ADMM (20 outer iterations of 10 CG steps) and CG-SENSE
(10 iterations), timed with the suite's protocol on exclusive Komondor CPU nodes, Ristretto `c949d8e`.
"One domain" is the placement of every table above (16 cores of one NUMA domain, local memory);
"spread" takes the cores round-robin from four domains and interleaves the memory over them. Each
"change" alters one thing in the default configuration. Scripts and raw files:
[`benchmark/thread_scaling/`](https://github.com/hakkelt/RistrettoBenchmarking/tree/master/benchmark/thread_scaling).

```@eval
Main.Tables.md(Main.Tables.thread_probe_markdown())
```

Kernels on the case's own arrays (job 15122806, one domain unless noted):

```@eval
Main.Tables.md(Main.Tables.kernels_markdown())
```

What the runs show:

- **Memory bandwidth of one NUMA domain limits the solve.** A threaded copy reaches 28 GB/s at 4
  threads and 33 GB/s at 16 in one domain; the TV solve takes the same time at 4 and 16 threads there.
  The same 16 threads spread over four domains, with identical code, are 1.6× faster for TV and 1.5×
  for CG-SENSE.
- **Coil parallelism stops at 8.** The normal operator runs each of the 8 coils as one task, so at 16
  threads half of them idle in that phase; per-coil FFT tasks scale no better than the batched FFT.
- **Not the cause:** garbage collection (switched off, TV changes by 2%), the threaded TV gradient (serial, within
  noise), the serial BLAS in CG (threaded BLAS makes TV 1.9× slower).
