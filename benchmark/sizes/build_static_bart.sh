#!/bin/bash
# Build BART statically (SLINK=1 in its Makefile: OpenBLAS, FFTW with threads, no CUDA, no MKL) on
# a RHEL/Rocky 8 machine that has no static libraries installed, and report its size and that it
# is static. Everything is built and unpacked under WORK; nothing is installed system-wide.
#
#   WORK=/path/to/scratch FFTW_BASE=/path/to/fftw-3.3.10 GCC_BIN=/opt/rh/gcc-toolset-13/root/usr/bin \
#       benchmark/sizes/build_static_bart.sh [tag]
#
# FFTW_BASE must contain lib/libfftw3f.a and lib/libfftw3f_threads.a (single precision). BART
# v1.0.00 needs GCC 12 or newer. The static archives that RHEL 8 does not install come from the
# Rocky Linux 8 "devel" repository and are unpacked with rpm2cpio:
#   glibc-static, zlib-static, libpng-static, openblas-static and openblas-devel (lapack.h).
# libgfortran.a, libquadmath.a and libgomp.a come from the GCC toolset itself.
set -euo pipefail
TAG="${1:-v1.0.00}"
: "${WORK:?set WORK to a scratch directory}"
: "${FFTW_BASE:?set FFTW_BASE}"
: "${GCC_BIN:?set GCC_BIN to a GCC >= 12 bin directory}"
ROCKY=https://dl.rockylinux.org/pub/rocky/8/devel/x86_64/os/Packages
RPMS=(
    g/glibc-static-2.28-251.el8_10.48.x86_64.rpm
    z/zlib-static-1.2.11-26.el8.x86_64.rpm
    l/libpng-static-1.6.34-11.el8_10.x86_64.rpm
    o/openblas-static-0.3.15-6.el8.x86_64.rpm
    o/openblas-devel-0.3.15-6.el8.x86_64.rpm
)
mkdir -p "$WORK/static-rpms" "$WORK/static-root"
for r in "${RPMS[@]}"; do
    [ -f "$WORK/static-rpms/$(basename "$r")" ] || curl -sf -o "$WORK/static-rpms/$(basename "$r")" "$ROCKY/$r"
    (cd "$WORK/static-root" && rpm2cpio "$WORK/static-rpms/$(basename "$r")" | cpio -idm --quiet)
done
SR="$WORK/static-root/usr/lib64"
# glibc's libm.a is a linker script naming /usr/lib64 absolutely; point it at the unpacked copies.
printf 'GROUP ( %s/libm-2.28.a %s/libmvec.a )\n' "$SR" "$SR" > "$SR/libm.a"
# The SLINK branch of BART's Makefile links -llapack -lblas; OpenBLAS provides both.
ln -sf libopenblas.a "$SR/liblapack.a"
ln -sf libopenblas.a "$SR/libblas.a"

export PATH="$GCC_BIN:$PATH"
GCCLIB="$(dirname "$(gcc -print-libgcc-file-name)")"
SRC="$WORK/bart-static-$TAG"
[ -d "$SRC" ] || git clone -q --depth 1 --branch "$TAG" https://codeberg.org/mrirecon/bart.git "$SRC"
# libgomp.a's offloading code calls dlopen, so libdl.a must follow it on the link line, which the
# Makefile's own -fopenmp does not arrange; it is named explicitly after the BLAS libraries.
cat > "$SRC/Makefile.local" <<EOF
CUDA = 0
MKL = 0
OPENBLAS = 1
NOLAPACKE = 1
FFTW_BASE = $FFTW_BASE
FFTWTHREADS = 1
SLINK = 1
override BLAS_L = -L$SR $SR/libopenblas.a $GCCLIB/libgfortran.a $GCCLIB/libquadmath.a $GCCLIB/libgomp.a $SR/libdl.a $SR/libpthread.a
LDFLAGS += -L$SR
CPPFLAGS += -I$WORK/static-root/usr/include/openblas
EOF
make -C "$SRC" -j"${JOBS:-8}" bart > "$SRC/build.log" 2>&1
mkdir -p "$SRC/dist"
cp "$SRC/bart" "$SRC/dist/bart"
strip "$SRC/dist/bart"
echo "unstripped: $(stat -c %s "$SRC/bart") bytes"
echo "stripped:   $(stat -c %s "$SRC/dist/bart") bytes ($SRC/dist/bart)"
file "$SRC/dist/bart"
ldd "$SRC/dist/bart" || true
"$SRC/dist/bart" version
