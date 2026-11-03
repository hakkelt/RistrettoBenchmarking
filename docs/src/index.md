# RistrettoBenchmarking

Benchmarks of [Ristretto.jl](https://github.com/hakkelt/Ristretto.jl), an MRI reconstruction
package in Julia, against [BART](https://github.com/mrirecon/bart),
[SigPy](https://github.com/mikgroup/sigpy),
[MRIReco.jl](https://github.com/MagneticResonanceImaging/MRIReco.jl),
[MIRT.jl](https://github.com/JeffFessler/MIRT.jl) and [MRpro](https://github.com/PTB-MR/mrpro),
and a comparison of what each toolbox provides.

!!! warning "Snapshots, not a live comparison"
    Every number here was measured on the date and with the releases that the
    [Hardware](@ref) and [Versions](@ref) sections of the [Benchmarks](@ref) page list, and the
    [Feature comparison](@ref) was checked in October 2026. The toolboxes keep changing and the
    benchmarks are not re-run on every release, so read an old snapshot as a record of its date,
    not as a description of the current releases.

- [Benchmarks](@ref): time to a common accuracy, fixed-iteration timings, start-up costs, thread
  scaling and GPU timings, with the method, the hardware and the versions.
- [Feature comparison](@ref): which reconstruction methods and tools each toolbox implements.

Each toolbox reconstructs the same prepared inputs: the cases come from Ristretto's benchmark case
catalog, which this repository reads from a pinned commit of Ristretto (the `Ristretto/`
submodule). The scripts, the setup of every toolbox and the raw results are in the
[repository](https://github.com/hakkelt/RistrettoBenchmarking); corrections from the maintainers
of the other toolboxes are welcome as issues or pull requests.
