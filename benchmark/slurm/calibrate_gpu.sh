#!/bin/bash
#SBATCH --job-name=calibrate-gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=96G
#SBATCH --time=01:00:00
#
# λ and ADMM-penalty calibration (benchmark/comparison/scripts/calibrate_lambda.jl) on one GPU:
# every toolkit that runs on the device is swept there, from one host thread with OpenBLAS (see
# `DEVICE` in _setup.jl). One case per job, as calibrate.sh does:
#
#   benchmark/slurm/submit.sh calibrate_gpu.sh --cases=real_3d_multichannel_cartesian --data=real --methods=atv
#
# Every argument goes to calibrate_lambda.jl.
set -euo pipefail
source "${SLURM_SUBMIT_DIR:-$(pwd)}/benchmark/slurm/common.sh"

nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
# GPUEnv writes its overlay (gpu_env/) into the active environment's directory, so each job runs in
# a copy of the environment of its own (see comparison_gpu.sh).
ENV_DIR="$REPO_ROOT/benchmark/comparison_gpu_${SLURM_JOB_ID:-local}"
rm -rf "$ENV_DIR"; mkdir -p "$ENV_DIR"
cp benchmark/comparison/Project.toml benchmark/comparison/Manifest.toml "$ENV_DIR/"
[ -f benchmark/comparison/LocalPreferences.toml ] && cp benchmark/comparison/LocalPreferences.toml "$ENV_DIR/"
trap 'rm -rf "$ENV_DIR"' EXIT
"$JULIA_BIN" --project="$ENV_DIR" -t 1 benchmark/comparison/scripts/calibrate_lambda.jl \
    --threads=1 --device=cuda "$@"
