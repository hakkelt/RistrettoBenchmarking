# GPU

Komondor's GPU node, one A100 40 GB per job, one host thread. Every toolbox runs on the device where it
can: a row is left out for a toolbox whose solve would stay on the host, and MIRT has no rows here. Times
include the copies to and from the device. BART's times also include the CUDA start-up that every
BART call pays (see [Timing](@ref)).

A device reconstruction in Ristretto solves the slices of a multi-slice case jointly, where the CPU
splits them into one task per slice, so its multi-slice errors differ between CPU and GPU.

## Accuracy race

```@eval
Main.Tables.race(; gpu = true)
```

## Adjoint

```@eval
Main.Tables.fixed("Base"; gpu = true)
```

## Gridding

```@eval
Main.Tables.fixed("Non-Cartesian"; gpu = true)
```

## CG-SENSE

```@eval
Main.Tables.fixed("CG-SENSE"; gpu = true)
```

## Static regularization

```@eval
Main.Tables.fixed("Sparsity"; gpu = true)
```

## Dynamic regularization

```@eval
Main.Tables.fixed("Dynamic"; gpu = true)
```

```@eval
Main.Tables.other_races(; gpu = true)
```
