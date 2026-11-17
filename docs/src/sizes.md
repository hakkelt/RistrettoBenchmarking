# Problem size and memory

The 2D 8-coil Shepp–Logan case at n² for n = 96 to 512, 255 being the odd size; the calibration-region
width, the undersampling and the coil maps scale with n. λ of the ℓ₁-wavelet is calibrated per toolbox
and size (`benchmark/comparison/results/lambda_n<n>/`). Each size is timed with the suite's protocol at 1
and 8 threads, one process per NUMA domain. "BART (MEASURE)" is BART with `FFTW_MEASURE` planning, paid
in every run. Job 15137010 on Komondor, Ristretto `5faaa2e41`, BART v1.0.01, MRIReco 0.9.2, SigPy 0.1.27,
MRpro 0.261015 (PyTorch 2.15.0), MIRT 0.18.3; raw files in
[`benchmark/sizes/results/15137010/`](https://github.com/hakkelt/RistrettoBenchmarking/tree/master/benchmark/sizes/results/15137010).
"error" marks a run that failed: MRpro's wavelet transform (ptwt) needs even sizes.

## CG-SENSE, 10 iterations

```@eval
Main.Tables.md(Main.Tables.sizes_markdown("CG-SENSE"))
```

## ℓ₁-wavelet, 20 iterations

```@eval
Main.Tables.md(Main.Tables.sizes_markdown("Sparsity"))
```

NRMSE against the phantom, 8 threads:

```@eval
Main.Tables.md(Main.Tables.sizes_markdown("Sparsity"; what = :error))
```

## Peak memory

Peak resident set size in MB of one fresh process per toolbox, method and size at 8 threads, which
loads, sets up, solves once and solves again (CG-SENSE / ℓ₁-wavelet). BART runs one process per solve,
so its number is one solve.

```@eval
Main.Tables.md(Main.Tables.sizes_meta_markdown())
```

```@eval
Main.Tables.md(Main.Tables.memory_markdown())
```

What the runs show:

- **Power-of-two sizes under `FFTW_ESTIMATE`.** In the FFTW-based toolboxes 256² is slower than 320² at
  1 thread, and 512² is 4-5× slower than 384² for 1.8× the pixels: FFTW's estimated plan for these sizes
  is slow (a bare 256² × 8 FFT takes 17.1 ms with `ESTIMATE` against 1.9 ms with `MEASURE`). BART with
  `MEASURE` shows no such step. Ristretto's automatic choice picks `ESTIMATE` at 512² for CG-SENSE,
  where measuring would pay (3.18 s against 1.14 s, login node, 1 thread).
- **Peak memory is mostly the runtime:** a Julia process starts at about 0.75-0.85 GB, a Python one at
  0.3-0.37 GB, BART at tens of MB; from 96² to 512² each grows by 0.1-0.6 GB.
