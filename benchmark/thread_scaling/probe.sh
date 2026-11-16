#!/bin/bash
# Thread-scaling probe of the 3D catalog case (see README.md here): probe.jl for CG-SENSE and TV
# (ADMM) at 1, 4 and 16 threads on one NUMA domain, the one-change variants at 16 threads, the same
# at 4 and 16 threads spread over four domains, and kernels.jl at 1, 4 and 16 threads. One run at
# a time on an exclusive node; every run except the spread ones is bound with numactl to the cores
# and memory of NUMA domain $DOMAIN.
#
#   benchmark/slurm/submit.sh --production --time=02:00:00 benchmark/thread_scaling/probe.sh
#
#SBATCH --job-name=thread_scaling
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --mem=0
#SBATCH --time=02:00:00
set -u
REPO_ROOT="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$REPO_ROOT/benchmark/slurm/common.sh"

OUT="benchmark/thread_scaling/results/${SLURM_JOB_ID:-local}"
mkdir -p "$OUT"
DOMAIN="${DOMAIN:-1}"
CASE=shepp_logan_3d_8ch_cartesian
lscpu > "$OUT/lscpu.txt"
numactl --hardware > "$OUT/numactl_hardware.txt"

local_run() { # threads, args...
    local t=$1; shift
    numactl --cpunodebind="$DOMAIN" --membind="$DOMAIN" "$JULIA_BIN" --project=benchmark/comparison -t "$t" "$@"
}
spread_run() { # threads, args...
    local t=$1; shift
    PROBE_SPREAD=1 numactl --cpunodebind=0,1,2,3 --interleave=0,1,2,3 "$JULIA_BIN" --project=benchmark/comparison -t "$t" "$@"
}

"$JULIA_BIN" --project=benchmark/comparison -e 'using Pkg; Pkg.instantiate(); using Ristretto' || exit 1

for t in 1 4 16; do
    local_run "$t" benchmark/thread_scaling/kernels.jl --out="$OUT/kernels_${t}t.json"
done
spread_run 16 benchmark/thread_scaling/kernels.jl --out="$OUT/kernels_16t_spread4.json"
for m in cgsense tv; do
    for t in 1 4 16; do
        local_run "$t" benchmark/thread_scaling/probe.jl --case=$CASE --method=$m --out="$OUT/${m}_${t}t_default.json"
    done
    for v in cg_blas_grant gc_off; do
        local_run 16 benchmark/thread_scaling/probe.jl --case=$CASE --method=$m --variant=$v --out="$OUT/${m}_16t_${v}.json"
    done
    for t in 4 16; do
        spread_run "$t" benchmark/thread_scaling/probe.jl --case=$CASE --method=$m --out="$OUT/${m}_${t}t_spread4.json"
    done
done
echo "### done"
