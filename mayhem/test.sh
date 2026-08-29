#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for gitea's work-time duration parser.
# Runs the dynamically-linked KAT probe (/mayhem/gitea_timestr_kat, built by
# build.sh) that parses fixed "1h 2m 3s" strings through the real
# modules/util.TimeEstimateParse path, and asserts the EXACT decoded values
# (all lifted from upstream's modules/util/time_str_test.go golden cases).
#
# Why not `go test` alone (netnew §4): a Go test binary is statically linked, so
# the gate's LD_PRELOAD sabotage shim cannot neuter it — the suite would survive
# sabotage while proving nothing. The KAT probe is cgo-linked (dynamic), so when
# the program is neutered to _exit(0) it prints nothing, every assertion misses,
# and test.sh FAILS — which is the point (§6.3).
#
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
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

PROBE=/mayhem/gitea_timestr_kat
passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
if [ ! -x "$PROBE" ]; then
  echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "gitea-timestr-kat" 0 1
  exit 1
fi

OUT="$("$PROBE" 2>/dev/null)"
echo "--- KAT probe output ---"; printf '%s\n' "$OUT"; echo "------------------------"

# Fixed inputs -> exact expected decodes (time_str_test.go golden cases):
#   TimeEstimateParse("1h")       -> 3600
#   TimeEstimateParse("1m")       -> 60
#   TimeEstimateParse("1s")       -> 1
#   TimeEstimateParse("1h 1m 1s") -> 3661
#   TimeEstimateParse("1h_2m")    -> error ; ("1h,1m") -> error
#   TimeEstimateString(3600)      -> "1h"
#   TimeEstimateString(3601)      -> "1h 1s"
assert() { # <desc> <expected-line>
  if printf '%s\n' "$OUT" | grep -qxF "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected exact line: $2)"; failed=$((failed+1))
  fi
}

assert "TimeEstimateParse(\"1h\") == 3600"        "KAT_1H=3600"
assert "TimeEstimateParse(\"1m\") == 60"          "KAT_1M=60"
assert "TimeEstimateParse(\"1s\") == 1"           "KAT_1S=1"
assert "TimeEstimateParse(\"1h 1m 1s\") == 3661"  "KAT_COMBO=3661"
assert "TimeEstimateParse(\"1h_2m\") errors"      "KAT_ERR_UNDERSCORE=true"
assert "TimeEstimateParse(\"1h,1m\") errors"      "KAT_ERR_COMMA=true"
assert "TimeEstimateString(3600) == \"1h\""       "KAT_STR_3600=1h"
assert "TimeEstimateString(3601) == \"1h 1s\""    "KAT_STR_3601=1h 1s"

emit_ctrf "gitea-timestr-kat" "$passed" "$failed"
