#!/usr/bin/env bash
# The WSL side of bart.exe (bart_wsl.cs): runs a BART built inside WSL on the .cfl/.hdr files a
# Windows process passed by path.
#
# usage: bart_wsl.sh <bart binary> <bart arguments...>   (paths already translated to /mnt/<drive>/...)
#
# BART's `Total Time` runs from the tool's start to its outputs written and its inputs unmapped, so
# it would include reading and writing the files over /mnt (9P, several times slower than ext4).
# Every /mnt argument is therefore staged: an existing <arg>.cfl/.hdr is copied to a temporary
# directory on the WSL file system first, and every file BART writes there is copied back after it
# exits. Both copies are outside the timed region.
set -u
bart=$1
shift
tmp=$(mktemp -d /tmp/bart_wsl.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

args=()
staged=()   # pairs: local path, original path
n=0
for a in "$@"; do
    case $a in
        /mnt/*)
            n=$((n + 1))
            l=$tmp/f$n
            for e in hdr cfl; do [ -e "$a.$e" ] && cp "$a.$e" "$l.$e" && touch -d @0 "$l.$e"; done
            staged+=("$l" "$a")
            args+=("$l")
            ;;
        *) args+=("$a") ;;
    esac
done
# Outputs are the files BART writes: an output of a previous run with the same name is staged like
# an input, so existence alone does not tell them apart. Staged copies are dated to the epoch above,
# and whatever has another time afterwards was written. (Not "newer than a marker file": the kernel
# stamps files with a coarse clock, so a file written right after the marker can carry its time.)
"$bart" "${args[@]}"
rc=$?

for ((i = 0; i < ${#staged[@]}; i += 2)); do
    l=${staged[i]}
    w=${staged[i + 1]}
    for e in hdr cfl; do
        [ -e "$l.$e" ] && [ "$(stat -c %Y "$l.$e")" != 0 ] && cp "$l.$e" "$w.$e"
    done
done
exit $rc
