# Fixed iteration budget

Every method at a set iteration count. Times compare work done at that count, not time to the same
error: the error in brackets differs between toolboxes (see [Time to accuracy and fixed budget](@ref)).
On each section, the 8-thread snapshot of Komondor is shown and the other thread counts open below it.

## Adjoint

The zero-filled, coil-combined reconstruction of the Cartesian cases, the cheapest operation every toolbox provides.

```@eval
Main.Tables.fixed("Base")
```

```@eval
Main.Tables.other_fixed("Base")
```

## Gridding

Density-compensated gridding of the radial cases. Ristretto also runs at MRIReco's NFFT operating point (m = 3, σ = 1.25), on a row of its own.

```@eval
Main.Tables.fixed("Non-Cartesian")
```

```@eval
Main.Tables.other_fixed("Non-Cartesian")
```

## CG-SENSE

Unregularized iterative SENSE, 10 conjugate-gradient iterations, on every multi-coil case.

```@eval
Main.Tables.fixed("CG-SENSE")
```

```@eval
Main.Tables.other_fixed("CG-SENSE")
```

## Static regularization

TV and anisotropic TV (each by ADMM, 20 iterations, and by PDHG, 200 iterations), TGV and ℓ₁-wavelet (FISTA, 20 iterations) on the static cases, each toolbox at its calibrated λ.

```@eval
Main.Tables.fixed("Sparsity")
```

```@eval
Main.Tables.other_fixed("Sparsity")
```

## Dynamic regularization

Global low rank, locally low rank, temporal TV (ADMM and PDHG) and ℓ₁-wavelet on the cine cases, each toolbox at its calibrated λ.

```@eval
Main.Tables.fixed("Dynamic")
```

```@eval
Main.Tables.other_fixed("Dynamic")
```

## GRAPPA

GRAPPA on the regularly undersampled variants, combined by root sum of squares or with the coil maps. Only Ristretto provides GRAPPA among the compared toolboxes.

```@eval
Main.Tables.fixed("K-Space")
```

```@eval
Main.Tables.other_fixed("K-Space")
```
