; tests/meta/test_toml_batchwrite_atomic.ahk

; ==============================================================================
; MODULE: TOML BatchWrite Atomic Meta Test
; DESCRIPTION:
; Protect write-through publication, flush/verification ordering and immediate
; native refusal diagnostics. Code masks keep comments and data from satisfying
; the call/branch guards; actual-body mutations prove the oracle refuses regressions.
; ==============================================================================

#Requires AutoHotkey v2.0

_TBA_RequireUnique(Code, Pattern, Message) {
	Position := RegExMatch(Code, Pattern, &Found)
	Assert(Position > 0, Message)
	Assert(RegExMatch(Code, Pattern, , Position + Found.Len) == 0, Message)
	return Found
}

_TBA_AssertPublication(Seg) {
	Assert(Seg != "", "the shared TOML renderer must be nonempty")
	Code := _DriverMaskNonCode(&Seg)
	Move := _TBA_RequireUnique(Code,
		"i)\bMoved\s*:=\s*FSAtomicMoveReplace\s*\(\s*tmp\s*,\s*Path\s*,\s*&MoveError\s*\)",
		"TOML_BatchWrite must publish once through the atomic adapter with its native error receipt")
	Assert(RegExMatch(SubStr(Code, 1, Move.Pos - 1), "i)\bMoveError\b") == 0,
		"the native error must not be consumed before publication")
	AssertEqual(0, RegExMatch(Code, "i)\bFileDelete\s*\(\s*Path\s*\)"),
		"TOML_BatchWrite must NOT delete the target file first (toml-batchwrite-nonatomic-config-loss)")
	AssertEqual(0, RegExMatch(Code, "i)\bFileMove\s*\("),
		"TOML_BatchWrite must not bypass the write-through adapter")
	Flush := _TBA_RequireUnique(Code, "i)\bFSFlushFileBuffers\s*\(\s*f\s*\)",
		"the complete stage must have one native flush")
	Verify := _TBA_RequireUnique(Code, "i)\b_TOML_StageMatches\s*\(\s*tmp\s*,\s*body\s*\)",
		"the complete stage must have one exact verification")
	Assert(Verify.Pos > Flush.Pos && Move.Pos > Verify.Pos,
		"flush and exact stage verification must precede atomic publication")
	Refusal := _TBA_RequireUnique(Code,
		"i)if\s*!\s*\(\s*\(\s*Moved\s+is\s+Integer\s*\)\s*&&\s*Moved\s*==\s*1\s*\)\s*\{",
		"the atomic move must retain its strict refusal branch")
	Assert(Refusal.Pos > Move.Pos, "the refusal branch must inspect the returned native receipt")
	OpenPos := Refusal.Pos + Refusal.Len - 1
	Depth := 1, Cursor := OpenPos + 1
	while Cursor <= StrLen(Code) && Depth {
		Character := SubStr(Code, Cursor, 1)
		if Character == "{"
			Depth += 1
		else if Character == "}"
			Depth -= 1
		Cursor += 1
	}
	AssertEqual(0, Depth, "the atomic refusal branch must close")
	Branch := SubStr(Code, OpenPos + 1, Cursor - OpenPos - 2)
	RawBranch := SubStr(Seg, OpenPos + 1, Cursor - OpenPos - 2)
	Log := _TBA_RequireUnique(Branch,
		"i)\bLoggerError\s*\(\s*[^,]*,\s*[^,]*,\s*Path\s*,\s*MoveError\s*\)",
		"the atomic refusal logger must consume the captured native error")
	RawLog := SubStr(RawBranch, Log.Pos, Log.Len)
	Assert(InStr(RawLog, "Write-through atomic replace") && InStr(RawLog, "native error {2}"),
		"the atomic refusal diagnostic must identify the operation and its native error")
	Cleanup := _TBA_RequireUnique(Branch, "i)\b_TOML_RemoveOwnedStage\s*\(\s*tmp\s*\)",
		"the refused publication must clean only its owned stage")
	Assert(Cleanup.Pos > Log.Pos, "the refusal diagnostic must precede owned-stage cleanup")
	Occurrences := 0, Position := 1
	while RegExMatch(Code, "i)\bMoveError\b", &Occurrence, Position) {
		Occurrences += 1
		Position := Occurrence.Pos + Occurrence.Len
	}
	AssertEqual(2, Occurrences, "the native receipt must reach only its output argument and refusal logger")
}

_TBA_BatchWriteIsAtomic() {
	Wrapper := _DriverFuncBody("TOML_BatchWrite")
	Seg := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(Wrapper != "" && Seg != "", "TOML_BatchWrite and its shared renderer must exist")
	Assert(InStr(Wrapper,
		'_TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write")') > 0,
		"the public writer must select the shared renderer's write mode explicitly")
	_TBA_AssertPublication(Seg)
}
Test("toml_helpers: TOML_BatchWrite uses write-through atomic replace "
	. "(toml-write-through-atomic)", _TBA_BatchWriteIsAtomic)

_TBA_SourceMutant(Mode) {
	Seg := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(Seg != "", "the mutation must start from the actual complete renderer")
	Call := "Moved := FSAtomicMoveReplace(tmp, Path, &MoveError)"
	AssertEqual(1, StrSplit(Seg, Call).Length - 1, "the actual mutation seam must be unique")
	switch Mode {
		case "missing-receipt":
			Mutant := StrReplace(Seg, Call, "Moved := FSAtomicMoveReplace(tmp, Path)")
			Expected := "TOML_BatchWrite must publish once through the atomic adapter with its native error receipt"
		case "duplicate-publication":
			Mutant := StrReplace(Seg, Call, Call . "`n" . Call)
			Expected := "TOML_BatchWrite must publish once through the atomic adapter with its native error receipt"
		case "early-error":
			Mutant := StrReplace(Seg, Call, "Premature := MoveError`n" . Call)
			Expected := "the native error must not be consumed before publication"
		case "missing-diagnostic":
			AssertEqual(1, StrSplit(Seg, "native error {2}").Length - 1,
				"the actual native diagnostic mutation seam must be unique")
			Mutant := StrReplace(Seg, "native error {2}", "unknown native status")
			Expected := "the atomic refusal diagnostic must identify the operation and its native error"
	}
	Observed := 0
	try _TBA_AssertPublication(Mutant)
	catch as Err
		Observed := Err
	Assert(Observed is Error, "the actual source oracle must refuse the named mutation")
	AssertEqual("Error", Type(Observed), "the source refusal must be a plain assertion error")
	AssertEqual(Expected, Observed.Message, "the source mutation must fail at its intended invariant")
}
for Mode in ["missing-receipt", "duplicate-publication", "early-error", "missing-diagnostic"]
	Test("toml_helpers: atomic source oracle refuses " . Mode . " (toml-write-through-atomic)",
		_TBA_SourceMutant.Bind(Mode))

_TBA_SourceFormattingControl() {
	Seg := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(Seg != "", "the formatting control must read the actual renderer")
	Call := "Moved := FSAtomicMoveReplace(tmp, Path, &MoveError)"
	AssertEqual(1, StrSplit(Seg, Call).Length - 1, "the formatting seam must be unique")
	Seg := StrReplace(Seg, Call, "Moved := FSATOMICMOVEREPLACE( tmp , Path , &MoveError )")
	Seg := "; FSAtomicMoveReplace(tmp, Path, &MoveError)`n"
		. 'Decoy := "FSAtomicMoveReplace(tmp, Path, &MoveError)"' . "`n" . Seg
	_TBA_AssertPublication(Seg)
}
Test("toml_helpers: atomic source oracle accepts legal formatting and ignores data (toml-write-through-atomic)",
	_TBA_SourceFormattingControl)
