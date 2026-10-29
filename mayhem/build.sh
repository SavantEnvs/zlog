#!/usr/bin/env bash
#
# Builds everything the commit image needs: the sanitized zlog library and fuzz harness (+ standalone
# reproducer), and the project's own unit tests with the NORMAL flags (mayhem/test.sh only runs them).
# zlog has no third-party dependencies, so there is nothing to fetch: re-running is offline and idempotent.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty SANITIZER_FLAGS builds with no sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) The project, instrumented. fuzz-no-link adds SanCov to the library itself (not just the harness TU).
#    -fno-sanitize=function: zlog stores its destructors in void(*)(void *) slots (zc_arraylist, zc_hashtable)
#    and calls them through that type, which UBSan's function check halts on at every init+fini. The rest of
#    UBSan and ASan stay halting.
#    build/ is gitignored upstream, so `git clean -ffdX` removes both build trees.
cmake -S . -B build/fuzz -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=function $DEBUG_FLAGS"
cmake --build build/fuzz --target zlog_s -j"$MAYHEM_JOBS"

# 2) Harness: fuzzer binary + standalone reproducer (the harness is C, so the driver links directly).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o build/fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    mayhem/zlog_init_fuzzer.c build/fuzz/lsan_off.o -Isrc build/fuzz/lib/libzlog.a -pthread \
    -o "$SRC/zlog_init_fuzzer"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" \
    mayhem/zlog_init_fuzzer.c build/fuzz/lsan_off.o -Isrc build/fuzz/lib/libzlog.a -pthread \
    -o "$SRC/zlog_init_fuzzer-standalone"

# 3) The project's unit tests with its normal flags, an independent build.
cmake -S . -B build/tests -DUNIT_TEST=ON -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$COVERAGE_FLAGS"
cmake --build build/tests -j"$MAYHEM_JOBS"
