#!/usr/bin/env bash
# Builds the sanitized libFuzzer harnesses (+ run-once standalone reproducers) and the doctest suite.
# cista is header-only, so the harness TUs are the instrumented project code.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Test suite first, with the project's NORMAL flags (clean, independent of the sanitized build).
#    Start from a fresh build dir: cmake drops -DCISTA_FMT=OFF when a re-run changes the cached
#    compiler path (clang vs /usr/bin/clang), which would break an offline re-run.
rm -rf build-tests
env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake -G Ninja -S . -B build-tests \
  -DCISTA_FMT=OFF -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests -j"$MAYHEM_JOBS" --target cista-test

# 2) Fuzz harnesses, each linked against libFuzzer and against the run-once standalone driver.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CXXFLAGS_FUZZ="-std=c++17 -O1 -DCISTA_FNV1A=1 -I$SRC/include -I$SRC/fuzz"

# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$WORK/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$WORK/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -c "$SRC/fuzz/dependencies/rtree_c/rtree_c.c" -o "$WORK/rtree_c.o"

build_harness() {
  local src="$1" name="$2"
  local file="$SRC/fuzz/$src.cc"
  [ -f "$SRC/mayhem/$src.cc" ] && file="$SRC/mayhem/$src.cc"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $CXXFLAGS_FUZZ $LIB_FUZZING_ENGINE \
    "$file" "$WORK/rtree_c.o" "$WORK/lsan_off.o" -o "$SRC/cista-fuzz-$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $CXXFLAGS_FUZZ \
    "$file" "$WORK/rtree_c.o" "$WORK/lsan_off.o" "$WORK/standalone_main.o" \
    -o "$SRC/cista-fuzz-$name-standalone"
}

build_harness bitset_verification bitset-verification
build_harness bitvec_verification bitvec-verification
build_harness graph graph
build_harness hash_map_verification hash-map-verification
build_harness hash_set hash-set
build_harness multimap_verification multimap-verification
build_harness rtree_verification rtree-verification
