// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// WHY A SEPARATE BINARY (SPEC §6.3 anti-reward-hacking):
// `go test` links a STATIC binary, so the verify-repo sabotage check (which
// LD_PRELOADs a shim whose constructor calls _exit(0) for non-system executables)
// cannot neuter it — a suite that only runs `go test` is therefore immune to the
// sabotage check and does NOT prove the oracle is behavioral. This probe is built
// with cgo (see cgo_dynamic.go) so it is DYNAMICALLY linked: the shim reaches it,
// the process becomes an instant no-op, it prints nothing, and test.sh's exact
// string assertions below fail. That is what makes the oracle sabotage-detecting.
//
// It is also a real KAT, not a liveness check: it builds a workbook USING THE
// LIBRARY ITSELF (no fixture files needed), writes typed values and a formula,
// round-trips it through the real ZIP+XML container (Write -> OpenReader), and
// asserts EXACT values recovered on the other side. A patch that stubs the
// writer/reader/evaluator to dodge a crash cannot reproduce these.
//
// Prints four lines, which test.sh matches EXACTLY:
//
//	KAT_CELL_A1=<string cell round-tripped through Write+OpenReader>
//	KAT_SHEET_COUNT=<sheet count after NewSheet, round-tripped>
//	KAT_SHEET2_NAME=<name of the second sheet, round-tripped>
//	KAT_SUM_A1A3=<CalcCellValue result of SUM(A1:A3) over 1,2,3>
package main

import (
	"bytes"
	"fmt"
	"os"

	"github.com/xuri/excelize/v2"
)

func fatalf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "kat: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()

	// ── 1) typed cell + a second sheet in a fresh in-memory workbook ─────────
	if err := f.SetCellStr("Sheet1", "A1", "hello"); err != nil {
		fatalf("SetCellStr: %v", err)
	}
	if _, err := f.NewSheet("Data"); err != nil {
		fatalf("NewSheet: %v", err)
	}

	// ── 2) formula evaluation: SUM over three numeric cells ──────────────────
	for i, v := range []int64{1, 2, 3} {
		cell, err := excelize.CoordinatesToCellName(1, i+1)
		if err != nil {
			fatalf("CoordinatesToCellName: %v", err)
		}
		if err := f.SetCellInt("Data", cell, v); err != nil {
			fatalf("SetCellInt(Data!%s): %v", cell, err)
		}
	}
	if err := f.SetCellFormula("Data", "B1", "SUM(A1:A3)"); err != nil {
		fatalf("SetCellFormula: %v", err)
	}
	sum, err := f.CalcCellValue("Data", "B1")
	if err != nil {
		fatalf("CalcCellValue: %v", err)
	}

	// ── 3) round-trip through the real container: write to bytes, reopen ────
	// exercises ZIP + XML + relationship resolution end to end (the same
	// stack fuzz_openreader targets), not just the in-memory object model.
	var buf bytes.Buffer
	if err := f.Write(&buf); err != nil {
		fatalf("Write: %v", err)
	}
	f2, err := excelize.OpenReader(bytes.NewReader(buf.Bytes()))
	if err != nil {
		fatalf("OpenReader: %v", err)
	}
	defer func() { _ = f2.Close() }()

	a1, err := f2.GetCellValue("Sheet1", "A1")
	if err != nil {
		fatalf("GetCellValue(A1): %v", err)
	}
	sheets := f2.GetSheetList()
	if len(sheets) < 2 {
		fatalf("expected >=2 sheets after round-trip, got %d", len(sheets))
	}

	fmt.Printf("KAT_CELL_A1=%s\n", a1)
	fmt.Printf("KAT_SHEET_COUNT=%d\n", len(sheets))
	fmt.Printf("KAT_SHEET2_NAME=%s\n", sheets[1])
	fmt.Printf("KAT_SUM_A1A3=%s\n", sum)
}
