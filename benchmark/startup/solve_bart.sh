#!/bin/bash
# BART's row of the startup benchmark: the `pics` calls `bart_recon` makes in the comparison harness
# (benchmark/comparison/scripts/_toolkits.jl), on the `.cfl` files `prepare.jl` wrote, with the
# arguments and the `RESULT` line of the other toolkits' solve scripts (`child_common.jl`):
#
#   bash solve_bart.sh <datadir> <method> <nwarm> <nx> <ny> <nc> <maxit> <lambda>
#
# Every BART solve is a process of its own, so there is nothing to import or set up in advance (both
# are 0), and the first and each of the `nwarm` further solves is the wall time of one `bart pics`
# process. The NRMSE (magnitudes, each image scaled to unit norm, as `mag_nrmse`) takes further
# `bart` processes; it is computed only when `nwarm` > 0 and is `nan` otherwise, so that a run with
# `nwarm = 0` times the solve alone. The binary is `RISTRETTO_BENCH_BART_OPENBLAS` (benchmark/slurm/site.env).
set -euo pipefail
datadir=$1 method=$2 nwarm=$3 maxit=$7 lambda=$8
bart=${RISTRETTO_BENCH_BART_OPENBLAS:?RISTRETTO_BENCH_BART_OPENBLAS is not set}
cd "$datadir"
case "$method" in
    wavelet) args=(-S -w 1 -e -i "$maxit" -R "W:3:0:$lambda") ;;
    cgsense) args=(-S -w 1 -i "$maxit") ;;
    *) echo "solve_bart.sh: no method $method" >&2; exit 1 ;;
esac

# Wall time of one `bart pics` process, in seconds.
solve() {
    local t0 t1
    t0=$(date +%s%N)
    "$bart" pics "${args[@]}" ksp sens "out_$method" > /dev/null
    t1=$(date +%s%N)
    awk -v d=$((t1 - t0)) 'BEGIN { printf "%.6f", d / 1e9 }'
}

first=$(solve)
warm=()
for ((i = 0; i < nwarm; i++)); do warm+=("$(solve)"); done

nrmse=nan
if ((nwarm > 0)); then
    "$bart" cabs "out_$method" "abs_$method"
    "$bart" normalize 3 "abs_$method" "absn_$method"
    "$bart" cabs ref ref_abs
    "$bart" normalize 3 ref_abs ref_absn
    nrmse=$("$bart" nrmse ref_absn "absn_$method")
fi
warm_list=$(IFS=,; echo "${warm[*]:--}")
echo "RESULT 0 0 $first $nrmse $warm_list"
