#!/usr/bin/env bash
#
# Runs zlog's own ctest suite (built by mayhem/build.sh in build/tests), then asserts known outputs
# by running the built test programs directly. ctest judges a case only by its exit code, so on its
# own it cannot tell a working library from a program that exits 0; the known-answer checks can.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BT="$SRC/build/tests"
BIN="$BT/bin"
if [ ! -x "$BIN/test_hello" ] || [ ! -f "$BT/CTestTestfile.cmake" ]; then
  echo "test runners missing: mayhem/build.sh did not build build/tests" >&2
  emit_ctrf "zlog-ctest" 0 1
  exit $?
fi

passed=0 failed=0

# 1) The project's suite.
ctest_out="$(cd "$BT" && ctest --output-on-failure 2>&1)"; echo "$ctest_out" | tail -15
summary="$(echo "$ctest_out" | sed -n 's/.*tests passed, \([0-9]*\) tests failed out of \([0-9]*\).*/\1 \2/p' | tail -1)"
if [ -z "$summary" ]; then
  failed=$((failed + 1)); echo "FAIL: no ctest summary line" >&2
else
  cf="${summary% *}"; ct="${summary#* }"
  failed=$((failed + cf)); passed=$((passed + ct - cf))
  if [ "$ct" -lt 35 ]; then failed=$((failed + 1)); echo "FAIL: only $ct ctest cases ran, expected >= 35" >&2; fi
fi

# 2) Known-answer checks against the programs themselves, in a scratch dir.
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp "$BT"/test/*.conf "$W"/
cd "$W"

check() {  # check <name> <command that succeeds iff the output is right>
  if ( eval "$2" ) >/dev/null 2>&1; then passed=$((passed + 1)); echo "ok   $1"
  else failed=$((failed + 1)); echo "FAIL $1" >&2; fi
}

"$BIN/test_hello" >hello.out 2>hello.err
check "test_hello stdout, millisecond format" \
  "grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\\.[0-9]{3} hello, zlog\$' hello.out"
check "test_hello stdout, microsecond format" \
  "grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\\.[0-9]{6} hello, zlog\$' hello.out"
check "test_hello stdout is exactly two lines" "[ \"\$(wc -l < hello.out)\" -eq 2 ]"
check "test_hello stderr, default format" \
  "grep -Eq ' INFO \\[[0-9]+:.*test_hello\\.c:[0-9]+\\] hello, zlog\$' hello.err"

"$BIN/test_hex" test_hex.conf 1 >/dev/null 2>&1
check "test_hex wrote the hex dump of its conf" \
  "grep -Fq '5b 72 75 6c 65 73 5d 0a 2a 2e 2a 09 09 22 68 65   [rules]' hex.log"
check "test_hex dump covers the whole conf" "grep -Fq '78 2e 6c 6f 67 22 3b 0a' hex.log"

"$BIN/test_bitmap" 0xaa55 0x66 >bitmap.err 2>&1
check "test_bitmap results" "grep -Eq '\\] ff\$' bitmap.err && grep -Eq '\\] fffffffe\$' bitmap.err"

"$BIN/test_init_from_string" >ifs.out 2>&1
check "init_from_string output file A" "[ \"\$(cat init_from_string_a.txt)\" = 'A one' ]"
check "init_from_string output file B after reload" "[ \"\$(cat init_from_string_b.txt)\" = 'B two' ]"
check "init_from_string test ran to completion" "grep -Fq 'init from string tests passed' ifs.out"

emit_ctrf "zlog-ctest+kat" "$passed" "$failed"
