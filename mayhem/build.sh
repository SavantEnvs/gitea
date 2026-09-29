#!/usr/bin/env bash
#
# mayhem/build.sh — build gitea's markdown-raw-rendering fuzz harness
# (tests/fuzz/fuzz_test.go: FuzzMarkdownRenderRaw, which drives
# modules/markup/markdown.RenderRaw()) as a sanitized libFuzzer binary
# (OSS-Fuzz Go path: go-118-fuzz-build -libfuzzer archive + clang++ ASan link).
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV under /opt/toolchains
# (absolute, $HOME-independent — so the offline PATCH re-run finds the cache).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) fills $GOMODCACHE (go get of the /testing shim,
#     plus `go mod download` of gitea's own dependency graph).
#   - GOPROXY points at the in-image module cache's file proxy FIRST, network
#     LAST, so the offline re-run resolves entirely from the cache; GOFLAGS=-mod=mod
#     + GOSUMDB=off keep go.sum verification local (no sum.golang.org round trip).
#
# HARNESS SCOPE (netnew §6 Go / port-go): unlike the work-time parser (a
# self-contained stdlib-only surface staged into a mini-module), the markdown
# renderer pulls in gitea's markup/markdown/setting packages and their full
# dependency graph — there is no smaller surface to isolate to, so we build the
# fuzz function straight out of the real module's own tests/fuzz package (same
# as the original mayhemheroes/oss-fuzz harness did).
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
# prepend a DWARF3 anchor.o at the final clang++ link so the FIRST .debug_info CU
# (what the gate reads) is DWARF < 4. $GO_DEBUG_FLAGS threads any base pins.
export GO_DEBUG_FLAGS="${GO_DEBUG_FLAGS:--gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} ${GO_DEBUG_FLAGS}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} ${GO_DEBUG_FLAGS}"

# Resolve modules offline-first from the in-image cache; network only as fallback.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOSUMDB="${GOSUMDB:-off}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

go version

TARGET="fuzz_markdown_render_raw"

# Pseudo-version of the go-118-fuzz-build /testing shim that the Dockerfile's
# `go install ...@a70c2aa677fa...` already resolved + cached. A raw commit hash
# forces a proxy.golang.org round trip to resolve it — fatal on the air-gapped
# PATCH re-run; the pseudo-version resolves straight from the file cache.
GO118_SHIM_VERSION="v0.0.0-20250520111509-a70c2aa677fa"

cd "$SRC"
go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_SHIM_VERSION}"

# ── Build the libFuzzer archive straight from the real module's tests/fuzz pkg ─
mkdir -p "$SRC/mayhem-build"
echo "=== go-118-fuzz-build $TARGET (func FuzzMarkdownRenderRaw) ==="
go-118-fuzz-build -func FuzzMarkdownRenderRaw -o "$SRC/mayhem-build/$TARGET.a" ./tests/fuzz

# ── DWARF3 anchor FIRST, then clang++ ASan+fuzzer link ─────────────────────────
printf 'int __mayhem_dwarf3_anchor;\n' > "$SRC/mayhem-build/anchor.c"
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem-build/anchor.c" -o "$SRC/mayhem-build/anchor.o"

# LSan-off hook (§6.2 item 15): -fsanitize=address always bundles LeakSanitizer in with no
# separate flag to exclude it, so link a hook that turns off leak detection preventively.
$CXX $SANITIZER_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/mayhem-build/lsan_off.o"

$CXX $GO_SAN $LIB_FUZZING_ENGINE \
     "$SRC/mayhem-build/anchor.o" "$SRC/mayhem-build/lsan_off.o" "$SRC/mayhem-build/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# ── mayhem/test.sh's oracle binary: a plain (unsanitized) Go program that calls the fuzzed
# RenderRaw function on a known-good input and asserts its output (§6.3 behavioral oracle).
echo "=== go build oracle (mayhem/test.sh's behavioral check) ==="
go build -o "$SRC/mayhem-build/oracle" ./mayhem/oracle
echo "built $SRC/mayhem-build/oracle"

echo "build.sh complete"
