# Methodology

The comparison suite in `benchmark/comparison/` reconstructs the same prepared cases with every toolbox,
from the same data, in the same process (SigPy and MRpro through PythonCall, BART as a subprocess per
solve). Ristretto's benchmark case catalog, in the pinned `Ristretto/` submodule, prepares the cases.

## Cases

```@eval
Main.Tables.md(Main.Tables.cases_markdown())
```

The synthetic cases are phantoms with known ground truth and complex Gaussian noise. The "regular
undersampling" variants feed the GRAPPA rows. The real cases are public raw datasets, undersampled
retrospectively; the breast case keeps the first 128 of its 288 radial spokes.

## Error measures

- **Synthetic cases:** NRMSE of the magnitude image against the phantom.
- **Real Cartesian cases:** NRMSE of the magnitude image against the reconstruction of the fully
  sampled acquisition.
- **Real radial breast case: held-out k-space error.** The fully sampled acquisition is itself
  radial, and an unregularized reconstruction of it keeps changing with the iteration count, so it is
  no reference. Instead, an image is scored by how well it predicts the 160 spokes the undersampled
  acquisition leaves out: with `A` the coil maps followed by an NFFT, `y` the held-out samples and `W`
  their density weights, the error is ‖W^½ (α A x − y)‖ / ‖W^½ y‖, where the complex scale α is fitted
  on the acquired spokes. Measurement noise sets a floor near 0.44 that no image goes below.

## Regularization weight

The toolboxes scale data and penalties differently, and their penalties differ in detail (boundary
handling of the finite differences, the TGV weights of BART 1.0), so one λ does not mean the same
thing to all of them. `calibrate_lambda.jl` therefore sweeps λ for every (case, method, toolbox) on a
logarithmic grid, 30 iterations per solve, and, for an ADMM solver, the penalty ρ on a grid of decades.
Ristretto's best error defines the operating point; every other toolbox gets the λ whose error is
closest to it. The calibrated values are listed under [Data and reproduction](@ref).

## Time to accuracy and fixed budget

An iteration does different work in different solvers: BART's ADMM `-i N` is a budget of about N
normal-operator applications rather than N outer iterations, a PDHG iteration applies the operator
once where an ADMM iteration runs an inner CG, and some solvers add power iterations for a step size.
The **accuracy race** therefore climbs a ladder of iteration counts per toolbox
(3, 5, 8, 12, 20, 30, 50; 5, 10, 20, 40 for the 3D and cine cases; the longer ladders 10 to 300 and
20 to 400 for PDHG and for BART's ADMM budget) and reports the time of the first count that reaches the
target. The target is 1.10 × the worst toolbox's best calibrated error, so that every toolbox can reach
it; the ADMM and PDHG rows of one TV share the larger of their two targets. On the radial breast case,
where the noise floor is close to every toolbox's best error, the target is 1.01 × the worst best error
of the toolboxes in that row.

The **fixed-budget** tables run every method at a set number of iterations (10 for CG-SENSE, 20 for
ADMM and FISTA, 200 for PDHG) and report time and error side by side. They show what a call with
default settings costs, but times there compare solvers that reach different errors.

## Timing

- Each time is the fastest of three runs after one warm-up run, from data on the host to an image on
  the host. On the GPU the copies to and from the device are included.
- No FFTW wisdom survives from one run to the next, in memory or on disk, so every run pays its own
  FFT planning.
- BART's time is the "Total Time" `pics` reports, which leaves out the process start and the file
  input and output, as the in-process toolboxes' times leave out their loading. BART's adjoint and
  gridding go through `bart fft` and `bart nufft`, which report no time of their own; those cells read
  "n/m" (not measured), since process start and file transfer dominate a solve of a few milliseconds.
- **BART's GPU times include its CUDA start-up.** Every `bart pics -g` process creates a CUDA context
  and loads cuFFT and cuBLAS before it solves, which an in-process toolbox pays once, in its warm-up.
  That start-up takes several hundred milliseconds (0.3-1.1 s per process, measured as the difference
  between a GPU and a CPU `pics` call on an 8×8 problem, and recorded in each run file as
  `bart_gpu_init_s`) and varies between processes by more than many GPU solves take, so it cannot be
  subtracted. BART's GPU times therefore show what a call of the `bart` tool costs on the GPU, not
  the solver's own speed.

## FFT planning

FFTW chooses how to compute a transform when it is planned. `FFTW_ESTIMATE` guesses from the sizes in
well under a millisecond; `FFTW_MEASURE` times candidate algorithms, which costs about 0.1-0.2 s per 2D
transform and 1-1.5 s per 3D one, and gives a faster plan. The toolboxes differ here:

- **BART** plans with `FFTW_ESTIMATE` by default; with `BART_USE_FFTW_WISDOM=1` it plans with
  `FFTW_MEASURE` and saves the result to files that later calls read. The "BART (MEASURE)" column of
  [Problem size and memory](@ref) times it that way, with the files emptied before every run.
- **MRIReco.jl** always plans with `FFTW_MEASURE` and keeps the result in memory only, so every new
  session measures again; with no wisdom carried between runs, it measures in every timed run.
- **Ristretto** chooses per reconstruction: `FFTW_MEASURE` when the transforms of the solve repay the
  measuring, else `FFTW_ESTIMATE` (`fft_planning = :auto`).
- **SigPy and MRpro** use NumPy's and PyTorch's FFTs, which have no measuring step. On the GPU every
  toolbox uses cuFFT.

## Threads and placement

On Komondor, each thread count runs in a process bound to one NUMA domain (16 cores and its local
memory) of an exclusively allocated node, threads pinned to physical cores, one process per domain at
a time (`benchmark/slurm/matrix.sh`). The same placement holds for every toolbox. SigPy does not
thread on the CPU: its FFT and its kernels are serial. A run on another machine states its placement in
the line above each of its tables.

## Reading the tables

- **Bold:** the fastest time of a row.
- **·:** no row: the toolbox does not provide the method (or, on the GPU, does not run it on the
  device), or its run failed.
- **not reached:** in the accuracy race, the toolbox has a fixed-budget row of the method but no race
  row: no count on its ladder reached the target, or the race run did not finish.
- **n/m:** run, but its time is not measured (see Timing).
- Brackets hold the error of the reconstruction (see Error measures).
