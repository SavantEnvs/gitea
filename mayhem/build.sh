#!/usr/bin/env bash
#
# mayhem/build.sh — build gitea's fuzz targets as sanitized libFuzzer binaries
# (go-118-fuzz-build archive + clang++ ASan link), plus dynamically-linked KAT
# oracle probes for mayhem/test.sh to run:
#   fuzz_markdown_render_raw / fuzz_markup_post_process  upstream's tests/fuzz calls (markdown
#       render, markup post-process) in production mode (mayhem/fuzz_markup.go.src), built
#       from the full module
#   fuzz_timestr  modules/util.TimeEstimateParse, staged into a stdlib-only mini-module
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV under /opt/toolchains
# (absolute, $HOME-independent — so the offline PATCH re-run finds the cache).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) fills $GOMODCACHE (go get of the /testing shim).
#   - GOPROXY points at the in-image module cache's file proxy FIRST, network
#     LAST, so the offline re-run resolves entirely from the cache; GOFLAGS=-mod=mod
#     + GOSUMDB=off keep go.sum verification local (no sum.golang.org round trip).
#
# HARNESS STAGING (netnew §6 Go / port-go): the real gitea module (`gitea.dev`)
# pins `go 1.27` and its modules/util package drags a broad dependency closure
# through the shared package. TimeEstimateParse()/TimeEstimateString() need only
# stdlib (fmt + regexp + strconv + strings + sync), so we copy JUST time_str.go
# into a fresh STANDALONE Go module at _mayhem_harness/timestr and build there.
# The harness module's only non-stdlib dep is the go-118-fuzz-build /testing shim
# — gitea's giant graph is never touched.
set -euo pipefail

: "${SRC:=/mayhem}"

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# Sanitizers (§6.1): the OSS-Fuzz Go path is ASan-only for the libFuzzer link.
# Honor the knob — an explicit empty SANITIZER_FLAGS yields an un-sanitized build.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export SANITIZER_FLAGS
GO_SAN="-fsanitize=address"
[ -n "${SANITIZER_FLAGS}" ] || GO_SAN=""

# Debug-info contract (§6.2 item 10): gc always emits DWARF4 with no knob, so we
# force the clang-compiled cgo C shims to DWARF3 (CGO_CFLAGS/CGO_CXXFLAGS) AND
# prepend a DWARF3 shim object (go_runtime_ready.o) at the final clang++ link so the FIRST CU
# (what the gate reads) is DWARF < 4. $GO_DEBUG_FLAGS threads any base pins.
export GO_DEBUG_FLAGS="${GO_DEBUG_FLAGS:--gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} ${GO_DEBUG_FLAGS}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} ${GO_DEBUG_FLAGS}"

# Resolve modules offline-first from the in-image cache; network only as fallback.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOSUMDB="${GOSUMDB:-off}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

go version

# Pseudo-version of the go-118-fuzz-build /testing shim that the Dockerfile's
# `go install ...@a70c2aa677fa...` already resolved + cached. A raw commit hash
# forces a proxy.golang.org round trip to resolve it — fatal on the air-gapped
# PATCH re-run; the pseudo-version resolves straight from the file cache.
GO118_SHIM_VERSION="v0.0.0-20250520111509-a70c2aa677fa"

# Init-ordering shim (go_runtime_ready.c), linked FIRST into every target (#1644).
mkdir -p "$SRC/mayhem-build"
SHIM_O="$SRC/mayhem-build/go_runtime_ready.o"
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem/go_runtime_ready.c" -o "$SHIM_O"

# Leak sanitization off at build time (SPEC §6.2 item 15); ASan stays on.
LSAN_OFF_O="$SRC/mayhem-build/lsan_off.o"
$CXX $GO_SAN $GO_DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OFF_O"

# Link <archive> into /mayhem/<target>: DWARF3 shim first, ASan + libFuzzer.
link_target() {
  local target="$1"
  $CXX $GO_SAN $LIB_FUZZING_ENGINE "$SHIM_O" "$LSAN_OFF_O" "$SRC/mayhem-build/$target.a" -o "/mayhem/$target"
  nm "/mayhem/$target" | grep ' T LLVMFuzzerInitialize$' >/dev/null \
    || { echo "build.sh: LLVMFuzzerInitialize shim missing from /mayhem/$target" >&2; exit 1; }
  echo "built /mayhem/$target"
}

# ── Full-module targets: upstream's tests/fuzz calls, in production mode (module gitea.dev) ────
# Staged under a `_` dir (ignored by ./...) so it can import gitea.dev/modules/*.
# The /testing shim must be on gitea's module graph; resolves from the file proxy offline.
(cd "$SRC" && go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_SHIM_VERSION}")
declare -A HARNESSES=(
  [fuzz_markdown_render_raw]=FuzzMarkdownRenderRaw
  [fuzz_markup_post_process]=FuzzMarkupPostProcess
)
rm -rf "$SRC/_mayhem_fuzz"
mkdir -p "$SRC/_mayhem_fuzz"
cp "$SRC/mayhem/fuzz_markup.go.src" "$SRC/_mayhem_fuzz/fuzz.go"
for TARGET in "${!HARNESSES[@]}"; do
  echo "=== go-118-fuzz-build $TARGET (${HARNESSES[$TARGET]}) ==="
  (cd "$SRC" && go-118-fuzz-build -func "${HARNESSES[$TARGET]}" -o "$SRC/mayhem-build/$TARGET.a" ./_mayhem_fuzz)
  link_target "$TARGET"
done

# ── KAT oracle probe for the markup targets (dynamic: cgo) ─────────────────────
# Staged under a `_` dir (ignored by ./...) inside the module so it can import gitea.dev/modules/*.
export CGO_ENABLED=1
rm -rf "$SRC/_mayhem_kat"
mkdir -p "$SRC/_mayhem_kat"
cp "$SRC/mayhem/kat_markup.go.src" "$SRC/_mayhem_kat/main.go"
(cd "$SRC" && go build -o /mayhem/gitea_markup_kat ./_mayhem_kat)
file /mayhem/gitea_markup_kat | grep -q 'dynamically linked' \
  || { echo "FATAL: /mayhem/gitea_markup_kat is not dynamically linked — oracle would be reward-hackable"; exit 1; }
echo "built /mayhem/gitea_markup_kat (dynamically linked)"

TARGET="fuzz_timestr"
STAGE="$SRC/_mayhem_harness/timestr"

# ── Stage a standalone mini-module: time_str.go (verbatim) + harness + KAT ─────
rm -rf "$STAGE"
mkdir -p "$STAGE/kat"
cp "$SRC/modules/util/time_str.go" "$STAGE/time_str.go"
cp "$SRC/mayhem/harness_timestr.go.src" "$STAGE/harness_timestr.go"
cp "$SRC/mayhem/kat_main.go.src"         "$STAGE/kat/main.go"

(
  cd "$STAGE"
  go mod init gitea.dev/_mayhem_harness/timestr
  # Add the go-118-fuzz-build /testing shim (pulls go-fuzz-headers transitively);
  # resolves from the file-proxy cache offline on the PATCH re-run.
  go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_SHIM_VERSION}"
  go mod tidy
)

# ── Build the libFuzzer archive from the staged single-package module ──────────
echo "=== go-118-fuzz-build $TARGET (func FuzzTimeEstimateParse) ==="
(
  cd "$STAGE"
  go-118-fuzz-build -func FuzzTimeEstimateParse -o "$SRC/mayhem-build/$TARGET.a" .
)

link_target "$TARGET"

# ── KAT oracle probe: dynamically-linked (cgo) so the sabotage shim can neuter it ─
export CGO_ENABLED=1
(
  cd "$STAGE"
  go build -o /mayhem/gitea_timestr_kat ./kat
)
file /mayhem/gitea_timestr_kat | grep -q 'dynamically linked' \
  || { echo "FATAL: /mayhem/gitea_timestr_kat is not dynamically linked — oracle would be reward-hackable"; exit 1; }
echo "built /mayhem/gitea_timestr_kat (dynamically linked)"

echo "build.sh complete"
