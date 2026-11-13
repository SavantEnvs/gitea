#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for gitea's fuzzed code paths.
# Runs two dynamically-linked KAT probes built by build.sh:
#   /mayhem/gitea_timestr_kat  fixed "1h 2m 3s" strings through the real
#       modules/util.TimeEstimateParse (values from upstream's time_str_test.go)
#   /mayhem/gitea_markup_kat   fixed markdown / HTML through the real
#       markdown.RenderRaw and markup.PostProcessDefault, incl. sanitizer behavior
# and asserts the EXACT output lines.
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

passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
for PROBE in /mayhem/gitea_timestr_kat /mayhem/gitea_markup_kat; do
  if [ ! -x "$PROBE" ]; then
    echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
    emit_ctrf "gitea-kat" 0 1
    exit 1
  fi
done

OUT="$(/mayhem/gitea_timestr_kat 2>/dev/null; /mayhem/gitea_markup_kat 2>/dev/null)"
echo "--- KAT probe output ---"; printf '%s\n' "$OUT"; echo "------------------------"

# Fixed inputs -> exact expected decodes. timestr: time_str_test.go golden cases
#   TimeEstimateParse("1h") -> 3600, "1m" -> 60, "1s" -> 1, "1h 1m 1s" -> 3661,
#   "1h_2m" / "1h,1m" -> error; TimeEstimateString(3600) -> "1h", (3601) -> "1h 1s".
# markup: CommonMark/GFM semantics (strong, em, code, link, list, task list) and the
#   sanitizer dropping <script>.
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

assert "markdown **bold** -> <strong>"           'MD_BOLD="<p dir=\"auto\"><strong>bold</strong></p>\n"'
assert "markdown *em* -> <em>"                    'MD_EM="<p dir=\"auto\"><em>em</em></p>\n"'
assert "markdown \`code\` -> <code>"              'MD_CODE="<p dir=\"auto\"><code>code</code></p>\n"'
assert "markdown link -> nofollow anchor"         'MD_LINK="<p dir=\"auto\"><a href=\"https://example.com/x\" rel=\"nofollow\">a</a></p>\n"'
assert "markdown list -> <ul><li>"                'MD_LIST="<ul dir=\"auto\">\n<li>one</li>\n<li>two</li>\n</ul>\n"'
assert "markdown sanitizer drops <script>"        'MD_SCRIPT="<p dir=\"auto\">hi </p>\n"'
assert "markdown task list -> checkboxes"         'MD_TASK="<ul dir=\"auto\">\n<li><input type=\"checkbox\" disabled=\"\" data-source-position=\"2\" checked=\"\">done</li>\n<li><input type=\"checkbox\" disabled=\"\" data-source-position=\"13\">todo</li>\n</ul>\n"'
assert "post-process autolinks a bare URL"        'POST_URL="<p>go <a href=\"https://example.com/x\" data-markdown-generated-content=\"\">https://example.com/x</a> now</p>"'

emit_ctrf "gitea-kat" "$passed" "$failed"
