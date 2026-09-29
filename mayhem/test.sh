#!/usr/bin/env bash
#
# mayhem/test.sh — run the oracle binary mayhem/build.sh compiled from mayhem/oracle (a
# known-answer test of the fuzzed function, markdown.RenderRaw). Behavioral, not a crash probe:
# it asserts on rendered HTML content, so a "fix" that makes RenderRaw a no-op fails here even
# though nothing crashes (SPEC.md §6.3 anti-reward-hacking / sabotage check).
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

if [ ! -x "$SRC/mayhem-build/oracle" ]; then
  echo "mayhem/test.sh: $SRC/mayhem-build/oracle missing — mayhem/build.sh should have built it" >&2
  emit_ctrf "gitea-markdown-oracle" 0 1
  exit $?
fi

out="$("$SRC/mayhem-build/oracle" 2>&1)"
rc=$?
echo "$out"

passed=$(grep -c '^PASS ' <<<"$out" || true)
failed=$(grep -c '^FAIL ' <<<"$out" || true)
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then
  failed=1 # oracle exited non-zero without a parseable FAIL line — count it as one failure
fi

emit_ctrf "gitea-markdown-oracle" "$passed" "$failed"
