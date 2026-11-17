# Start-up and footprint

## Start-up

The tables of the other pages time warm solves. A user also pays to start the toolbox: a BART call is
a process that starts in milliseconds, a Python toolbox is imported, and a Julia toolbox also compiles
each solver the first time it is called. Measured on one case (Shepp–Logan 2D, 8 coils, Cartesian;
ℓ₁-wavelet, 20 iterations / CG-SENSE, 10 iterations), in fresh processes
([`benchmark/startup/`](https://github.com/hakkelt/RistrettoBenchmarking/tree/master/benchmark/startup));
each cell gives ℓ₁-wavelet / CG-SENSE.

```@eval
Main.Tables.md(Main.Tables.startup_markdown())
```

The Julia rows assume precompiled packages. Since BART starts a process for every call, its first
and warm solves are the same and include the process start and file transfer the other pages leave
out. The first solve in a Julia session is two to three orders of magnitude slower than a warm one:
that matters for a script that reconstructs one image, and hardly at all for a session that
reconstructs many. The effect of Ristretto's precompile workload on these numbers is on the
[Ablation](@ref) page.

## Footprint

What each toolbox occupies on disk.

```@eval
Main.Tables.md(Main.Tables.footprint_markdown())
```
