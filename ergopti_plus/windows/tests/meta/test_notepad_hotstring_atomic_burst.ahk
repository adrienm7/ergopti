; tests/meta/test_notepad_hotstring_atomic_burst.ahk
;
; ==============================================================================
; MODULE: Notepad Hotstring Atomic Burst Meta Test
; DESCRIPTION:
; Modern literal output uses a retained native edit owner and commits only after
; verified completion. Keyboard/paste strategies must not re-enter this route.
; Legacy compatibility callbacks retain their separate indivisible send contract.
; ==============================================================================

#Requires AutoHotkey v2.0

; Masked, balanced owner inspection prevents comment and nested-branch decoys.
_NHAB_NativeBranch(Dispatch) {
	Code := _DriverMaskNonCode(&Dispatch)
	Assert(RegExMatch(Code, "i)\bif\s+IsNotepadApp\s*\{", &Open), "native Notepad branch must exist")
	First := Open.Pos + Open.Len - 1
	Depth := 1
	Position := First + 1
	while Position <= StrLen(Code) && Depth {
		Char := SubStr(Code, Position, 1)
		if Char == "{"
			Depth += 1
		else if Char == "}"
			Depth -= 1
		Position += 1
	}
	AssertEqual(0, Depth, "native Notepad branch must have balanced code braces")
	return SubStr(Dispatch, First + 1, Position - First - 2)
}

_NHAB_AssertNativeRoute(Dispatch := unset, Begin := unset) {
	if !IsSet(Dispatch)
		Dispatch := _DriverFuncBody("HSE_DispatchMatch")
	if !IsSet(Begin)
		Begin := _DriverFuncBody("_HSE_BeginOwnedNotepadTransaction")
	Assert(Dispatch != "" && Begin != "", "native Notepad owners must exist")
	Branch := _NHAB_NativeBranch(Dispatch)
	Code := _DriverMaskNonCode(&Branch)
	Assert(RegExMatch(Code, "i)\bDeferredOwner\s*:=\s*_HSE_NewNotepadOwner\("),
		"native Notepad branch must freeze its literal edit owner")
	Assert(RegExMatch(Code, "i)\breturn\s+_HSE_BeginOwnedNotepadTransaction\(\s*DeferredOwner\s*,"),
		"native Notepad branch must return its owned transaction")
	Assert(!RegExMatch(Code, "i)\b(?:SendInstant|SendInput|SendEvent|SendNewResult)\s*\("),
		"native Notepad branch must not execute a keyboard or paste strategy")
	Assert(!RegExMatch(Code, "i)\b(?:UpdateLastSentCharacter|_LSC[A-Za-z0-9_]*)\s*\("),
		"native Notepad dispatch must not publish the ring before verified completion")
	BeginCode := _DriverMaskNonCode(&Begin)
	Assert(RegExMatch(BeginCode, "im)^\s*Opts\s*:=\s*Map\(", &OptsCode),
		"native Notepad owner must construct its sender options")
	OptsRaw := SubStr(Begin, OptsCode.Pos)
	Assert(RegExMatch(OptsRaw, 'i)^\s*Opts\s*:=\s*Map\(\s*"mode"\s*,\s*"native"\s*,'),
		"native Notepad owner must select the native literal sender")
	Assert(RegExMatch(BeginCode, "i)_HSE_NotepadOwnerIsCurrent\.Bind\(Owner\)"),
		"native Notepad output must retain its actual admission owner")
	Assert(RegExMatch(BeginCode, "i)_HSE_CommitNotepadOwner\.Bind\(Owner\)"),
		"native Notepad output must retain its canonical commit owner")
	Assert(RegExMatch(BeginCode, "i)_HSE_RecoverNotepadOwner\.Bind\(Owner\)"),
		"native Notepad output must retain its uncertainty recovery owner")
	Assert(RegExMatch(BeginCode, "i)\bSendFn\.Call\(\s*Owner\["),
		"native Notepad owner must call its literal sender")
	Assert(RegExMatch(BeginCode, "i)_HSE_CompleteNotepadOwner\.Bind\(Owner\)"),
		"native Notepad output must retain its completion callback")
	Publish := InStr(BeginCode, "_HSE_TerminalOwner := Owner")
	Restore := InStr(BeginCode, "finally Critical(PreviousCritical)")
	Send := InStr(BeginCode, "SendFn.Call(")
	Assert(Publish > 0 && Restore > Publish && Send > Restore,
		"native Notepad ownership must publish under Critical and send after restoration")
}

_NHAB_NotepadEraseAndPasteAreOneBurst() {
	_NHAB_AssertNativeRoute()
	Legacy := _DriverFuncBody("_HotstringDispatch")
	Sender := _DriverFuncBody("SendInstant")
	Assert(Legacy != "" && Sender != "", "legacy callback send owners must exist")
	AssertContains(Legacy, "try Pasted := SendInstant(Replacement . EndChar, BackSpaceSeq)",
		"the separate compatibility callback must retain its indivisible erase/paste burst")
	AssertContains(Sender, 'SendInput(Prefix . "^v")', "the compatibility sender must retain its single batch")
}

_NHAB_RequirePolicyRefusal(Dispatch, Begin, Expected) {
	Rejected := false
	try _NHAB_AssertNativeRoute(Dispatch, Begin)
	catch as Err {
		if Type(Err) != "Error" || SubStr(Err.Message, 1, StrLen(Expected)) != Expected
			throw Err
		Rejected := true
	}
	AssertTrue(Rejected, "the mutated native strategy must be rejected by its actual policy assertion")
}

_NHAB_NativePolicyRejectsKeyboardAndClipboardMutants() {
	Dispatch := _DriverFuncBody("HSE_DispatchMatch")
	Begin := _DriverFuncBody("_HSE_BeginOwnedNotepadTransaction")
	_NHAB_AssertNativeRoute(Dispatch, Begin)
	BadDispatch := StrReplace(Dispatch, "return _HSE_BeginOwnedNotepadTransaction(DeferredOwner, NativeSendFn?)",
		'return SendInstant("replacement")', true, &Changed)
	AssertEqual(1, Changed, "the keyboard-strategy mutation must alter exactly the actual native return")
	_NHAB_RequirePolicyRefusal(BadDispatch, Begin, "native Notepad branch must return its owned transaction")
	BadBegin := StrReplace(Begin, 'Map("mode", "native"', 'Map("mode", "clipboard"', true, &Changed)
	AssertEqual(1, Changed, "the clipboard-strategy mutation must alter exactly the actual options")
	_NHAB_RequirePolicyRefusal(Dispatch, BadBegin, "native Notepad owner must select the native literal sender")
	EarlyRing := StrReplace(Dispatch, "DeferredOwner := _HSE_NewNotepadOwner(Spec, Replacement,",
		'UpdateLastSentCharacter("x")`nDeferredOwner := _HSE_NewNotepadOwner(Spec, Replacement,', true, &Changed)
	AssertEqual(1, Changed, "the early-ring mutation must alter exactly the actual native owner branch")
	_NHAB_RequirePolicyRefusal(EarlyRing, Begin, "native Notepad dispatch must not publish the ring before verified completion")
	Spoof := BadDispatch . '`n; return _HSE_BeginOwnedNotepadTransaction(DeferredOwner, NativeSendFn?)'
	_NHAB_RequirePolicyRefusal(Spoof, Begin, "native Notepad branch must return its owned transaction")
}
Test("hotstrings: native Notepad policy rejects keyboard and clipboard strategy mutants",
	_NHAB_NativePolicyRejectsKeyboardAndClipboardMutants)

Test("hotstrings: Notepad literal output uses verified native completion (notepad-hotstring-atomic-burst)",
    _NHAB_NotepadEraseAndPasteAreOneBurst)
