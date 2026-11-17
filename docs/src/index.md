# RistrettoBenchmarking

This site holds the measurements that compare [Ristretto.jl](https://github.com/hakkelt/Ristretto.jl),
an MRI reconstruction package in Julia, with [BART](https://codeberg.org/mrirecon/bart),
[SigPy](https://github.com/mikgroup/sigpy),
[MRIReco.jl](https://github.com/MagneticResonanceImaging/MRIReco.jl),
[MIRT.jl](https://github.com/JeffFessler/MIRT.jl) and [MRpro](https://github.com/PTB-MR/mrpro), and the
measurements of Ristretto on its own (thread scaling, problem size, start-up, the effect of its design
choices). Every table is generated, when the site is built, from result files committed in the
[repository](https://github.com/hakkelt/RistrettoBenchmarking), and states the machine, the dates and the
releases it measured.

!!! warning "Snapshots, not a live comparison"
    Every number was measured on the dates and with the releases its table names. The toolboxes keep
    changing, and the measurements are not repeated for every release.

## Machines

Each snapshot of the cross-toolbox comparison comes from one machine, one BLAS library and one thread
count (or the GPU). Komondor is an HPC cluster: its CPU nodes have two AMD EPYC 7763 processors
(128 cores, 8 NUMA domains), its GPU nodes one EPYC 7763 (64 cores) and four NVIDIA A100 40 GB GPUs.
A CPU run uses one NUMA domain (16 cores) of an otherwise idle node, which is a CPU node for most rows and
the CPU of a GPU node for some; the line above each table gives the nodes behind it. A GPU run uses one
GPU.

```@eval
Main.Tables.md(Main.Tables.machines_markdown())
```

## Contents

- [Methodology](@ref): the cases, the error measures, how λ is chosen, the timing protocol.
- [Time to accuracy](@ref): how long each toolbox takes to reach a common error, on every
  thread count.
- [Fixed iteration budget](@ref): time and error of every method at a fixed number of iterations.
- [Thread scaling](@ref): every toolbox from 1 to 16 threads, and where the time of one large
  Ristretto reconstruction goes.
- [GPU](@ref): the comparison on an A100.
- [Problem size and memory](@ref): time, error and peak memory from 96² to 512².
- [Start-up and footprint](@ref): import, first-solve and fresh-process cost, and the size of
  each toolbox's installation.
- [Large datasets](@ref): a 3D knee and a multi-slice radial breast acquisition with Ristretto.
- [Ablation](@ref): what each of Ristretto's design choices contributes.
- [Feature comparison](@ref): which methods and tools each toolbox provides.
- [Data and reproduction](@ref): the result files, the calibrated λ, and how to repeat a run.
