#!/bin/bash
# Part 5: problem size and memory, on one exclusive node, each process bound with numactl to a
# NUMA domain of its own as matrix.sh places the comparison suite (one process per domain at a time).
#
#   1. λ of the L1-wavelet row calibrated at every size (calibrate_lambda.jl; CG-SENSE has no λ)
#   2. the startup case written out at every size (startup/prepare.jl), for step 4
#   3. CG-SENSE and L1-wavelet timed by the comparison suite at every size, 1 and 8 threads, with
#      BART planning by ESTIMATE (the suite's default) and, in a second pass, by MEASURE
#   4. peak RSS of every toolkit's solve in a fresh process, 8 threads (sizes/peak_memory.jl)
#
#   benchmark/slurm/submit.sh --production --time=05:00:00 ../sizes/part5.sh
#
#SBATCH --job-name=part5
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --mem=0
#SBATCH --time=05:00:00
set -u
REPO_ROOT="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$REPO_ROOT/benchmark/slurm/common.sh"

SIZES=(${PART5_SIZES:-96 128 192 256 320 384 512 255})
CASE=shepp_logan_2d_8ch_cartesian
OUT="$REPO_ROOT/benchmark/sizes/results/${SLURM_JOB_ID:-local}"
DATA="${PART5_DATA:-/project/c_mrrecon/paper-measurements/part5-data}/${SLURM_JOB_ID:-local}"
mkdir -p "$OUT" "$DATA"
DOMAINS=($(numactl --hardware | awk '/^node [0-9]+ cpus:/ {print $2}'))
echo "### node $(hostname), domains ${DOMAINS[*]}, sizes ${SIZES[*]}"
lscpu > "$OUT/lscpu.txt"; numactl --hardware > "$OUT/numactl_hardware.txt"

"$JULIA_BIN" --project=benchmark/comparison -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' || exit 1

declare -A BUSY
run_on_free_domain() { # label, command...
    local label=$1; shift
    while true; do
        for d in "${DOMAINS[@]}"; do
            pid=${BUSY[$d]:-}
            if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
                ( numactl --cpunodebind="$d" --membind="$d" "$@" > "$OUT/$label.log" 2>&1; echo "### $label exit $? domain $d" ) &
                BUSY[$d]=$!
                return
            fi
        done
        sleep 5
    done
}

JL=("$JULIA_BIN" --project=benchmark/comparison)

# 1. calibration
for n in "${SIZES[@]}"; do
    run_on_free_domain "calibrate_n$n" env RISTRETTO_BENCH_N="$n" "${JL[@]}" -t 8 benchmark/comparison/scripts/calibrate_lambda.jl \
        --threads=8 --cases=$CASE --methods=wavelet
done
wait

# 2. the startup case at every size, with the λ just calibrated
for n in "${SIZES[@]}"; do
    RISTRETTO_BENCH_N="$n" "${JL[@]}" benchmark/startup/prepare.jl "$DATA/n$n" $CASE > "$OUT/prepare_n$n.log" 2>&1 || echo "### prepare n$n failed"
done

# 3. timing
for n in "${SIZES[@]}"; do
    for nt in 1 8; do
        run_on_free_domain "time_n${n}_${nt}t" env RISTRETTO_BENCH_N="$n" "${JL[@]}" -t "$nt" benchmark/comparison/scripts/run_all.jl \
            --threads="$nt" --sections=cgsense,sparsity --cases=$CASE --methods=cgsense,wavelet
        run_on_free_domain "time_n${n}_${nt}t_bart_measure" env RISTRETTO_BENCH_N="$n" RISTRETTO_BENCH_BART_MEASURE=1 "${JL[@]}" -t "$nt" benchmark/comparison/scripts/run_all.jl \
            --threads="$nt" --sections=cgsense,sparsity --cases=$CASE --methods=cgsense,wavelet --frameworks=bart
    done
done
wait

# 4. peak memory, 8 threads
for n in "${SIZES[@]}"; do
    [ -f "$DATA/n$n/meta.json" ] || continue
    run_on_free_domain "memory_n$n" "${JL[@]}" benchmark/sizes/peak_memory.jl "$DATA/n$n" 8 "$OUT/memory_n$n.json"
done
wait
echo "### done"
