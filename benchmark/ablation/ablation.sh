#!/bin/bash
# Part 4b ablation on one exclusive node: every (case, thread count) is one process of
# benchmark/ablation/ablation.jl, bound with numactl to a NUMA domain of its own (cores and
# memory), as matrix.sh places the comparison suite; at most one process per domain at a time.
# Then the first-solve comparison with and without the precompile workload (first_solve.jl).
#
#   benchmark/slurm/submit.sh --production --time=03:00:00 ../ablation/ablation.sh
#
#SBATCH --job-name=ablation
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --mem=0
#SBATCH --time=03:00:00
set -u
REPO_ROOT="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$REPO_ROOT/benchmark/slurm/common.sh"
export OPENBLAS_NUM_THREADS=1

OUT="$REPO_ROOT/benchmark/ablation/results/${SLURM_JOB_ID:-local}"
mkdir -p "$OUT"
DOMAINS=($(numactl --hardware | awk '/^node [0-9]+ cpus:/ {print $2}'))
echo "### node $(hostname), domains ${DOMAINS[*]}"
lscpu > "$OUT/lscpu.txt"; numactl --hardware > "$OUT/numactl_hardware.txt"

"$JULIA_BIN" --project=benchmark/comparison -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' || exit 1

# case method threads [extra args]
TASKS=(
    "shepp_logan_multislice_8ch_cartesian tv 1"
    "shepp_logan_multislice_8ch_cartesian tv 8"
    "shepp_logan_2d_8ch_radial tv 1"
    "shepp_logan_2d_8ch_radial tv 8"
    "shepp_logan_3d_8ch_cartesian tv 1"
    "shepp_logan_3d_8ch_cartesian tv 8"
    "torso_cine_8ch_cartesian lowrank 1"
    "torso_cine_8ch_cartesian lowrank 8"
    "torso_cine_8ch_radial lowrank 1"
    "torso_cine_8ch_radial lowrank 8"
    "shepp_logan_2d_8ch_cartesian wavelet 1"
    "shepp_logan_2d_8ch_cartesian wavelet 8"
    "shepp_logan_multislice_8ch_cartesian tv 1 --reltol=1e-3 --maxit=100"
    "shepp_logan_multislice_8ch_cartesian tv 8 --reltol=1e-3 --maxit=100"
)

# One slot per NUMA domain; a task waits for a free domain.
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

for t in "${TASKS[@]}"; do
    set -- $t
    case=$1; method=$2; nt=$3; shift 3
    tag=""; [ $# -gt 0 ] && tag="_tol"
    label="${case}_${method}_${nt}t${tag}"
    run_on_free_domain "$label" "$JULIA_BIN" --project=benchmark/comparison -t "$nt" benchmark/ablation/ablation.jl \
        --case="$case" --method="$method" --out="$OUT/$label.json" "$@"
done
wait

# precompile_workload = false: a copy of the environment at the same depth (so the relative
# [sources] path to Ristretto still resolves) with the preference set, compiled into a depot of
# its own placed first, so the default compiled cache is left alone.
NOWL="$REPO_ROOT/benchmark/comparison_noworkload"
rm -rf "$NOWL"; mkdir -p "$NOWL"
cp benchmark/comparison/Project.toml benchmark/comparison/Manifest.toml "$NOWL/"
[ -f benchmark/comparison/LocalPreferences.toml ] && cp benchmark/comparison/LocalPreferences.toml "$NOWL/"
printf '\n[Ristretto]\nprecompile_workload = false\n' >> "$NOWL/LocalPreferences.toml"
NOWL_DEPOT="${ABLATION_NOWL_DEPOT:-/project/c_mrrecon/paper-measurements/depot-noworkload}"
mkdir -p "$NOWL_DEPOT"
BASE_DEPOT="${JULIA_DEPOT_PATH:-/scratch/c_mrrecon/julia_depot:}"
JULIA_DEPOT_PATH="$NOWL_DEPOT:$BASE_DEPOT" "$JULIA_BIN" --project="$NOWL" -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' || exit 1

for t in "${TASKS[@]:0:12}"; do
    set -- $t
    case=$1; method=$2; nt=$3
    for wl in default noworkload; do
        label="first_${case}_${method}_${nt}t_${wl}"
        if [ $wl = default ]; then
            run_on_free_domain "$label" "$JULIA_BIN" --project=benchmark/comparison -t "$nt" benchmark/ablation/first_solve.jl --case="$case" --method="$method" --out="$OUT/$label.json"
        else
            run_on_free_domain "$label" env JULIA_DEPOT_PATH="$NOWL_DEPOT:$BASE_DEPOT" "$JULIA_BIN" --project="$NOWL" -t "$nt" benchmark/ablation/first_solve.jl --case="$case" --method="$method" --out="$OUT/$label.json"
        fi
    done
done
wait
rm -rf "$NOWL"
echo "### done"
