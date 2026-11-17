#!/bin/bash
#SBATCH --job-name=calibrate-pack
#SBATCH --gres=gpu:2
#SBATCH --cpus-per-task=16
#SBATCH --mem=120G
#SBATCH --time=01:00:00
#
# Several λ calibrations (benchmark/comparison/scripts/calibrate_lambda.jl) side by side in one job,
# one worker process per line of the file given as the first argument. A line starting with `cuda`
# runs on one of the job's GPUs (taken in turn) from one host thread, as calibrate_gpu.sh does; any
# other line runs on the host at one thread. The rest of each line goes to calibrate_lambda.jl:
#
#   cuda --cases=real_2d_multichannel_radial --data=real --methods=tv
#   cpu  --cases=real_2d_multichannel_radial --data=real --methods=tv_pd --frameworks=bart
#
# Calibration measures only errors, never times, so workers may share a node and a GPU.
set -euo pipefail
source "${SLURM_SUBMIT_DIR:-$(pwd)}/benchmark/slurm/common.sh"

nvidia-smi --query-gpu=index,name,memory.total --format=csv
ngpu=$(nvidia-smi -L | wc -l)
LOG_DIR="benchmark/results/slurm/calibrate-pack_${SLURM_JOB_ID:-local}"
mkdir -p "$LOG_DIR"
dirs=()
trap 'rm -rf "${dirs[@]}"' EXIT
i=0; g=0
while read -r kind args; do
    [ -z "$kind" ] && continue
    case "$kind" in \#*) continue ;; esac
    i=$((i + 1))
    if [ "$kind" = cuda ]; then
        # GPUEnv writes its overlay into the environment's directory: one copy per worker.
        env_dir="$REPO_ROOT/benchmark/comparison_gpu_${SLURM_JOB_ID:-local}_$i"
        rm -rf "$env_dir"; mkdir -p "$env_dir"; dirs+=("$env_dir")
        cp benchmark/comparison/Project.toml benchmark/comparison/Manifest.toml "$env_dir/"
        [ -f benchmark/comparison/LocalPreferences.toml ] && cp benchmark/comparison/LocalPreferences.toml "$env_dir/"
        # shellcheck disable=SC2086
        CUDA_VISIBLE_DEVICES=$((g % ngpu)) OMP_NUM_THREADS=1 "$JULIA_BIN" --project="$env_dir" -t 1 \
            benchmark/comparison/scripts/calibrate_lambda.jl --threads=1 --device=cuda $args \
            > "$LOG_DIR/worker$i.log" 2>&1 &
        g=$((g + 1))
    else
        # shellcheck disable=SC2086
        CUDA_VISIBLE_DEVICES= OMP_NUM_THREADS=1 "$JULIA_BIN" --project=benchmark/comparison -t 1 \
            benchmark/comparison/scripts/calibrate_lambda.jl --threads=1 $args \
            > "$LOG_DIR/worker$i.log" 2>&1 &
    fi
    echo "worker $i ($kind): $args"
done < "$1"
status=0
for p in $(jobs -p); do wait "$p" || status=1; done
exit $status
