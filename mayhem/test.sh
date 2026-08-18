#!/usr/bin/env bash
#
# excelize/mayhem/test.sh — RUN the project's own Go test suite and a
# known-answer probe, and emit a CTRF summary. exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `go test ./...` — upstream's suite is a genuine behavioral suite of 400+ Test
#     funcs: it round-trips real committed test/*.xlsx fixtures, and calc_test.go
#     alone is a large known-answer table (thousands of formula -> expected-value
#     assertions) that exercises the exact formula engine fuzz_formula targets. So
#     it asserts BEHAVIOUR, not "exits 0".
#
#  2) The KAT probe /mayhem/kat — because `go test` links a STATIC binary, the
#     verify-repo sabotage check (LD_PRELOAD a shim whose constructor _exit(0)s every
#     non-system executable) CANNOT neuter it. A `go test`-only oracle therefore
#     survives sabotage while proving nothing, which is exactly the reward-hackable
#     case the spec forbids. /mayhem/kat is built with cgo => DYNAMICALLY linked, so
#     the shim does neuter it; it then prints nothing and the exact-match assertions
#     below fail. The probe builds a workbook USING THE LIBRARY ITSELF (no fixture
#     files needed), writes a formula, round-trips the whole thing through the real
#     ZIP+XML container (Write -> OpenReader), and asserts four exact values — a
#     patch that stubs the writer/reader/evaluator to dodge a crash cannot reproduce
#     these.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own Go suite ────────────────────────────────────────────────
if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 2
fi

echo "=== running: go test -json ./... ==="
mkdir -p "$SRC/mayhem-build"
JSON="$SRC/mayhem-build/gotest.json"
go test -json ./... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?
go test ./... 2>&1 | tail -30 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events only (lines carrying a non-empty "Test" field); package-level
# pass/fail lines have no "Test" field. Subtests count — they are real asserted cases.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test events parsed — the suite did not run (go exit $rc)" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 1
fi
# excelize's own suite reports several hundred Test funcs (calc_test.go alone is a
# huge known-answer table); a suspiciously small count means the build context is
# missing files (see docs/netnew-worker-prompt.md §4b) even though there is no
# upstream .dockerignore here to cause it.
if [ "$(( PASSED + FAILED + SKIPPED ))" -lt 100 ]; then
  echo "FAIL: only $(( PASSED + FAILED + SKIPPED )) test cases ran — excelize ships hundreds; the build context is likely missing test files" >&2
  FAILED=$(( FAILED + 1 ))
fi
# A non-zero go exit with zero counted failures means a build/vet error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A
# `[ -f ... ]` guard here is how a probe silently stops running and the oracle
# quietly degrades to the go-test-only (reward-hackable) case. The probe needs no
# input fixture — it builds its own known workbook with the library.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, or the round trip is broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "cell A1 round-trips through Write+OpenReader" 'KAT_CELL_A1=hello'
kat_expect "sheet count after NewSheet round-trips"       'KAT_SHEET_COUNT=2'
kat_expect "second sheet name round-trips"                'KAT_SHEET2_NAME=Data'
kat_expect "CalcCellValue SUM(A1:A3) over 1,2,3"          'KAT_SUM_A1A3=6'

emit_ctrf "go-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
