; tests/meta/test_keylogger_critical_restore.ahk

; ==============================================================================
; MODULE: Keylogger Critical-State Restore Meta Test
; DESCRIPTION:
; Guards every short keylogger transaction that temporarily enables Critical.
; Calling Critical("Off") at the end clobbers a caller that was already critical,
; allowing a timer to interrupt a shared-state mutation and lose input events.
; ==============================================================================

#Requires AutoHotkey v2.0


_KCR_AssertPreservesCallerCritical(FuncName, RequiredFragment) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must exist")
	StartIdx := InStr(Body, "previous_critical := Critical(" . Chr(34) . "On" . Chr(34) . ")")
	FinallyIdx := InStr(Body, "finally")
	RestoreIdx := InStr(Body, "Critical(previous_critical)")
	WorkIdx := InStr(Body, RequiredFragment, , StartIdx)
	Assert(StartIdx > 0 and FinallyIdx > StartIdx and RestoreIdx > FinallyIdx,
		FuncName . " must restore the caller's Critical state in finally (keylogger-critical-restore)")
	Assert(WorkIdx > StartIdx and WorkIdx < FinallyIdx,
		FuncName . " must keep its shared-state mutation inside the restore-owned transaction (keylogger-critical-restore)")
	Assert(InStr(Body, 'Critical("Off")') = 0,
		FuncName . " must not clobber a caller Critical state with Critical('Off') (keylogger-critical-restore)")
}

_KCR_FlushSnapshotPreservesCritical() {
	_KCR_AssertPreservesCallerCritical("KL_FlushBuffer", "Keylogger.buffer_events    := []")
}
Test("keylogger: flush snapshot restores caller Critical state (keylogger-critical-restore)", _KCR_FlushSnapshotPreservesCritical)


_KCR_IngestQueueTransactionsPreserveCritical() {
	_KCR_AssertPreservesCallerCritical("KL_IngestOnce", "Keylogger._pending_entries := []")
	Body := _DriverFuncBody("KL_IngestOnce")
	Assert(InStr(Body, "Keylogger._pending_entries.InsertAt") > 0,
		"KL_IngestOnce must retain its failure requeue transaction (keylogger-critical-restore)")
	Assert(InStr(Body, "Critical(previous_critical)", false, InStr(Body, "Keylogger._pending_entries.InsertAt")) > 0,
		"KL_IngestOnce requeue transaction must restore caller Critical state (keylogger-critical-restore)")
}
Test("keylogger: ingest queue transactions restore caller Critical state (keylogger-critical-restore)", _KCR_IngestQueueTransactionsPreserveCritical)

_KCR_MouseAndRoiTransactionsPreserveCritical() {
	Scroll := _DriverFuncBody("KL_Mouse_FlushScroll")
	Assert(RegExMatch(_DriverMaskNonCode(&Scroll), "\{\s*[^}\s]"),
		"the scroll claim owner must contain executable code (keylogger-critical-restore)")
	_KCR_AssertScrollTransaction(Scroll)
	_KCR_AssertPreservesCallerCritical("KL_Roi_IncrementWordCount", "word_counts_generation += 1")
	_KCR_AssertPreservesCallerCritical("KL_Roi_SnapshotWordCounts", "word_counts.Clone()")
	_KCR_AssertPreservesCallerCritical("KL_Roi_TryPublishPrunedCounts", "State.word_counts := NextCounts")
	_KCR_AssertPreservesCallerCritical("KL_Roi_HalflifeTick", "snapshot[trig] := last_tick")
}
Test("keylogger: mouse and ROI snapshots preserve caller Critical state (keylogger-critical-restore)", _KCR_MouseAndRoiTransactionsPreserveCritical)


; The scroll owner now has injectable callouts and a compactly formatted claim.
; Guard the actual transaction rather than a whitespace-sensitive assignment.
_KCR_ScrollRequire(Condition) {
	if !Condition
		throw Error("Scroll claim must restore caller Critical before dispatch (keylogger-critical-restore)")
}

_KCR_ScrollUnique(Code, Pattern, &Match) {
	Position := RegExMatch(Code, "i)" . Pattern, &Match)
	_KCR_ScrollRequire(Position > 0)
	_KCR_ScrollRequire(!RegExMatch(Code, "i)" . Pattern, , Position + Match.Len))
	return Position
}

_KCR_ScrollBlock(Code, Opening, &Closing) {
	_KCR_ScrollRequire(SubStr(Code, Opening, 1) == "{")
	Depth := 0
	loop StrLen(Code) - Opening + 1 {
		Position := Opening + A_Index - 1
		Char := SubStr(Code, Position, 1)
		if Char == "{"
			Depth += 1
		else if Char == "}"
			Depth -= 1
		if Depth == 0 {
			Closing := Position
			return SubStr(Code, Opening, Closing - Opening + 1)
		}
	}
	_KCR_ScrollRequire(false)
}

_KCR_ScrollWriteCount(Code, Name) {
	Pattern := "i)(?<![A-Za-z0-9_.])(?:" . Name
		. "(?![A-Za-z0-9_])\s*(?::=|[+*/.&|^-]?=(?!=)|\+\+|--)|(?:\+\+|--)\s*"
		. Name . "(?![A-Za-z0-9_]))"
	Count := 0
	Position := 1
	while RegExMatch(Code, Pattern, &Write, Position) {
		Count += 1
		Position := Write.Pos + Write.Len
	}
	return Count
}

_KCR_AssertScrollTransaction(Body) {
	Code := _DriverMaskNonCode(&Body)
	_KCR_ScrollRequire(RegExMatch(Code, "\{\s*[^}\s]"))
	Start := _KCR_ScrollUnique(Code,
		"\b([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*Critical\s*\(\s*\)", &Entry)
	Saved := Entry[1]
	_KCR_ScrollRequire(RegExMatch(SubStr(Body, Start, Entry.Len),
		'i)^' . Saved . '\s*:=\s*Critical\s*\(\s*"On"\s*\)$'))
	AfterEntry := Start + Entry.Len
	_KCR_ScrollRequire(RegExMatch(SubStr(Code, AfterEntry), "i)^\s*try\s*\{", &TryClause))
	TryOpening := AfterEntry + TryClause.Len - 1
	Claim := _KCR_ScrollBlock(Code, TryOpening, &TryClosing)
	_KCR_ScrollRequire(RegExMatch(SubStr(Code, TryClosing + 1), "i)^\s*finally\s*\{", &Final))
	FinallyOpening := TryClosing + Final.Len
	Restoration := _KCR_ScrollBlock(Code, FinallyOpening, &FinallyClosing)
	_KCR_ScrollRequire(RegExMatch(Restoration,
		"i)^\{\s*Critical\s*\(\s*" . Saved . "\s*\)\s*\}$"))
	_KCR_ScrollRequire(_KCR_ScrollWriteCount(Code, Saved) == 1)
	_KCR_ScrollRequire(!RegExMatch(Claim, "i)\b(?:Call|Critical|MF_ShouldFilter|SetTimer|MouseGetPos|CoordMode|KL_AppendLog)\s*\("))
	for Pair in [["ticks", "scroll_ticks"], ["h_ticks", "scroll_h_ticks"], ["start", "scroll_start"]] {
		CapturedAt := _KCR_ScrollUnique(Claim,
			"\b" . Pair[1] . "\s*:=\s*KLMouse\." . Pair[2] . "\b", &Captured)
		_KCR_ScrollRequire(_KCR_ScrollWriteCount(Code, Pair[1]) == 1)
		ResetAt := _KCR_ScrollUnique(Claim,
			"\bKLMouse\." . Pair[2] . "\s*:=\s*0\b", &Reset)
		_KCR_ScrollRequire(CapturedAt < ResetAt)
	}
	_KCR_ScrollUnique(Claim, "\bKLMouse\.scroll_last\s*:=\s*0\b", &LastReset)
	Tail := SubStr(Code, FinallyClosing + 1)
	for Call in ["FilterFn.Call", "MF_ShouldFilter", "RefreshFn.Call", "SetTimer",
		"PositionFn.Call", "CoordMode", "MouseGetPos", "AppendFn.Call", "KL_AppendLog"] {
		Pattern := "\b" . StrReplace(Call, ".", "\.") . "\s*\("
		_KCR_ScrollUnique(Tail, Pattern, &Dispatch)
		_KCR_ScrollRequire(!RegExMatch(SubStr(Code, 1, FinallyClosing), "i)" . Pattern))
	}
}

_KCR_ExpectScrollRefusal(Body) {
	Caught := false
	try _KCR_AssertScrollTransaction(Body)
	catch Error as Err {
		if Type(Err) != "Error" || !(Err.Message == "Scroll claim must restore caller Critical before dispatch (keylogger-critical-restore)")
			throw Err
		Caught := true
	}
	Assert(Caught, "the mutated scroll transaction must fail for its ownership policy")
}

_KCR_ScrollTransactionMutations() {
	Body := _DriverFuncBody("KL_Mouse_FlushScroll")
	Assert(RegExMatch(_DriverMaskNonCode(&Body), "\{\s*[^}\s]"), "scroll mutation subject must contain executable code")
	_KCR_AssertScrollTransaction(Body)
	for Fragment in ["ticks := KLMouse.scroll_ticks", "h_ticks := KLMouse.scroll_h_ticks", "start := KLMouse.scroll_start",
		"KLMouse.scroll_ticks := 0", "KLMouse.scroll_h_ticks := 0", "KLMouse.scroll_start := 0", "KLMouse.scroll_last := 0"] {
		Assert(InStr(Body, Fragment) > 0, "the actual source mutation must remove a present claim statement")
		Mutant := StrReplace(Body, Fragment, "; removed claim statement")
		_KCR_ExpectScrollRefusal(Mutant)
	}
	Mutants := [
		StrReplace(Body, 'Critical(previous_critical)', 'Critical("Off")'),
		StrReplace(Body, "ticks := KLMouse.scroll_ticks", "ticks := KLMouse.scroll_ticks`n`t`tFilterFn.Call()"),
		StrReplace(Body, "ticks := KLMouse.scroll_ticks", "ticks := KLMouse.scroll_ticks`n`t`tTICKS := KLMouse.scroll_ticks"),
		StrReplace(Body, "KLMouse.scroll_last := 0", "KLMouse.scroll_last := 1"),
		StrReplace(Body, "start := KLMouse.scroll_start", 'Decoy := "start := KLMouse.scroll_start"'),
		StrReplace(Body, "finally {", "if true {"),
		StrReplace(Body, "filtered := false", "previous_critical := 0`n`tfiltered := false")
	]
	for Mutant in Mutants
		_KCR_ExpectScrollRefusal(Mutant)
}
Test("keylogger: scroll claim ownership rejects code mutations (keylogger-critical-restore)", _KCR_ScrollTransactionMutations)

_KCR_ScrollTransactionFormatting() {
	Body := _DriverFuncBody("KL_Mouse_FlushScroll")
	Assert(RegExMatch(_DriverMaskNonCode(&Body), "\{\s*[^}\s]"), "scroll formatting subject must contain executable code")
	_KCR_AssertScrollTransaction(StrReplace(Body, "KLMouse.scroll_ticks := 0", "KLMouse.scroll_ticks   :=   0"))
	_KCR_AssertScrollTransaction(StrReplace(Body, "previous_critical", "PRIOR_Critical"))
	_KCR_AssertScrollTransaction(RegExReplace(Body, "i)\btry\b", "TRY"))
	_KCR_AssertScrollTransaction(RegExReplace(Body, "i)\bfinally\b", "FINALLY"))
}
Test("keylogger: scroll claim ownership accepts whitespace and coherent local names (keylogger-critical-restore)", _KCR_ScrollTransactionFormatting)
