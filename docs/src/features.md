# Feature comparison

What each toolbox provides itself, checked against its source and documentation in October 2026
(and not since: newer releases may have added what a cell says is missing)
(BART 731bfd3, SigPy 0.1.27, Gadgetron 1d14c4c, MRpro 6830010, current MRIReco.jl and MIRT.jl).
"via X" means the feature comes from another package.

| Feature | BART | SigPy | Gadgetron | MRIReco.jl | MIRT.jl | MRpro | Ristretto |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Iterative SENSE | ✅ | ✅ | ✅ (GPU) | ✅ | ✅ (operator + solver) | ✅ | ✅ |
| g-factor / noise propagation | ❌ | ❌ | ✅ (GRAPPA g-map, pseudo-replica) | ❌ | ❌ | ❌ | ✅ (pseudo-replica) |
| GRAPPA | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ |
| SPIRiT | ❌ | ❌ | ✅ (incl. ℓ₁-SPIRiT) | ❌ | ❌ | ❌ | ✅ |
| ESPIRiT | ✅ | ✅ | via BART | ✅ (Cartesian) | ❌ | ❌ (Walsh, Inati) | ✅ |
| JSENSE / NLINV | ✅ NLINV | ✅ JSENSE | via BART | ❌ | ❌ | ❌ | ❌ |
| Calibrationless structured low-rank | ✅ SAKE | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ SAKE, LORAKS |
| Noise prewhitening | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Coil compression | ✅ SVD, GCC, ROVir | ❌ | ✅ PCA | ✅ SVD, GCC | ✅ PCA | ✅ PCA | ✅ SVD, GCC |
| Non-Cartesian (NUFFT) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Density compensation | ❌ (given weights) | ✅ Pipe–Menon | ✅ | ✅ | radial only | ✅ Voronoi | ✅ Pipe–Menon, Voronoi |
| B₀ off-resonance correction | ✅ | ✅ time-segmented | ✅ spiral | ✅ time-segmented | building blocks | ✅ | ❌ |
| Partial Fourier | homodyne | ❌ | ✅ homodyne, POCS | ❌ | ❌ | ❌ | ✅ homodyne, POCS, phase-constrained |
| Gradient delay estimation | ✅ RING | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ RING, opposing spokes |
| Total variation | ✅ | ✅ | ✅ | ✅ | edge-preserving | ✅ | ✅ |
| Wavelets | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Low-rank, locally low-rank | ✅ (+ multi-scale) | ❌ | ❌ | ✅ (via RegularizedLeastSquares) | ❌ | ❌ | ✅ (+ multi-scale) |
| Low-rank + sparse decomposition | matrix completion | ❌ | ❌ | ❌ | example script | ❌ | ✅ any regularizers |
| TGV | ✅ (TGV, ICTGV) | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Subspace / temporal basis | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ |
| Plug-and-play priors | ✅ | ❌ | ❌ | ✅ (via RegularizedLeastSquares) | ❌ | ❌ | ✅ |
| Unrolled networks | ✅ MoDL, VarNet | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Simultaneous multi-slice | model-based | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Quantitative parameter mapping | ✅ model-based | ❌ | ✅ cardiac T₁, T₂ | ❌ | ❌ | ✅ | ❌ |
| GPU | ✅ CUDA | ✅ CuPy | ✅ CUDA | ✅ GPUArrays | ❌ | ✅ PyTorch | ✅ GPUArrays (tested on CUDA) |
| Scanner streaming (MRD) | streaming import | ❌ | ✅ server | file I/O | ❌ | file I/O | MRD read and write |
| Image export | PNG, DICOM | ❌ | DICOM, MRD | NIfTI (via ImageUtils) | AVS `.fld` | NIfTI, DICOM | NIfTI, DICOM, MRD |

PROPELLER/BLADE reconstruction is in none of them. What Ristretto lacks is on its
[roadmap](https://github.com/hakkelt/Ristretto.jl/blob/master/ROADMAP.md).
