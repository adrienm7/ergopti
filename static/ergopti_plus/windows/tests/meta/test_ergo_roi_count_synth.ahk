; tests/meta/test_ergo_roi_count_synth.ahk

; ==============================================================================
; MODULE: Ergo ROI Count Synth Meta Test
; DESCRIPTION:
; The "ergo-roi-count-synthetic-keystrokes" policy follows the arrival receipt
; into the ordered commit owner. Every ergonomic/ROI/WPM effect must remain
; inside captured manual admission, even when live synthesis state changes.
; ==============================================================================

#Requires AutoHotkey v2.0

; The receipt captures synthesis before classification can yield. The shared
; commit owner must contain every ergonomic/ROI/WPM effect inside its negative
; synthesis guard, and reset physical timing only for the captured positive flag.
_TES_Check() {
	Capture := _DriverFuncBody("_KL_Hook_CaptureInput")
	Commit := _DriverFuncBody("_KL_Hook_CommitInput")
	Assert(Capture != "" && Commit != "", "actual capture and ordered commit owners must exist")
	_TES_ReceiptPolicy(Capture, Commit)
}

Test("Keylogger: synthetic strokes bypass ergo/roi counting", _TES_Check)

_TES_Count(Code, Pattern) {
	RegExReplace(Code, Pattern, "", &Count)
	return Count
}

_TES_ReceiptPolicy(Capture, Commit) {
	Assert(Capture != "" && Commit != "", "synthetic policy requires nonempty actual owner subjects")
	Capture := _DriverMaskNonCode(&Capture)
	Commit := _DriverMaskNonCode(&Commit)
	AssertEqual(1, _TES_Count(Capture, "(?i)\bsynth_active\s*:\s*Keylogger\.synth_active\b"),
		"the actual arrival object must capture the synthesis flag")
	Assert(RegExMatch(Commit, "(?im)^\s*if\s+(\w+)\.cancelled\b", &Receipt),
		"the commit receipt parameter must be discoverable from its admission guard")
	Name := Receipt[1]
	Pattern := "(?i)\bif\s+!" . Name . "\.synth_active\s*\{"
	AssertEqual(1, _TES_Count(Commit, Pattern), "the captured manual-only effects guard must be unique")
	RegExMatch(Commit, Pattern, &Guard)
	Open := Guard.Pos + InStr(Guard[0], "{") - 1
	Block := _DriverExtractDefinedBody(&Commit, {Idx: Guard.Pos, OpenPos: Open})
	Assert(Block != "", "the actual manual-only effects block must be balanced and nonempty")
	Assert(RegExMatch(Block, "(?im)^\s*(\w+)\s*:=.*\bKL_Ergo_OnKeystroke\b", &Ergo),
		"the default ergonomic owner must remain connected to the effect port")
	for Effect in [Ergo[1] . "\.Call\s*\(", "KL_Roi_OnChar\s*\(", "WPMWidget_Push\s*\("] {
		Total := _TES_Count(Commit, "(?i)\b" . Effect)
		Assert(Total > 0, "every protected effect must have an executable subject")
		AssertEqual(Total, _TES_Count(Block, "(?i)\b" . Effect),
			"every ergonomic/ROI/WPM call must be contained by captured manual admission")
	}
	DirectErgo := "(?i)\bKL_Ergo_OnKeystroke(?:\.Call)?\s*\("
	AssertEqual(_TES_Count(Commit, DirectErgo), _TES_Count(Block, DirectErgo),
		"a direct default-owner call must not bypass captured manual admission either")
	AssertEqual(1, _TES_Count(Commit, "(?im)^\s*if\s+" . Name
		. "\.synth_active\s*\n\s*KLHook\.last_tick\s*:=\s*0\b"),
		"captured synthetic output must reset the physical clock")
}

_TES_Reject(Capture, Commit, ExpectedMessage, PolicyFn := _TES_ReceiptPolicy) {
	Refused := false
	try PolicyFn.Call(Capture, Commit)
	catch as Err {
		if Type(Err) != "Error" || InStr(Err.Message, ExpectedMessage, true) != 1
			throw Err
		Refused := true
	}
	AssertTrue(Refused, "the actual synthetic policy must refuse the mutation")
}

_TES_NegativeControls() {
	Capture := _DriverFuncBody("_KL_Hook_CaptureInput")
	Commit := _DriverFuncBody("_KL_Hook_CommitInput")
	Assert(Capture != "" && Commit != "", "mutation controls require actual owner subjects")
	_TES_ReceiptPolicy(Capture, Commit)
	RegExMatch(_DriverMaskNonCode(&Commit), "(?im)^\s*if\s+(\w+)\.cancelled\b", &Receipt)
	Name := Receipt[1]
	for Token in ["if !" . Name . ".synth_active", "KLHook.last_tick := 0", "KL_Ergo_OnKeystroke"] {
		StrReplace(Commit, Token, "", true, &Count)
		AssertEqual(1, Count, "the mutated executable subject must be unique")
		Expected := Token = "KLHook.last_tick := 0" ? "captured synthetic output must reset the physical clock"
			: (Token = "KL_Ergo_OnKeystroke" ? "the default ergonomic owner must remain connected"
			: "the captured manual-only effects guard must be unique")
		for Spoof in ["'" . Token . "'", "; " . Token] {
			Changed := StrReplace(Commit, Token, Spoof, true)
			_TES_Reject(Capture, Changed, Expected)
		}
	}
	Changed := StrReplace(Commit, "if !" . Name . ".synth_active", "if " . Name . ".synth_active", true)
	_TES_Reject(Capture, Changed, "the captured manual-only effects guard must be unique")
	for Effect in ["KL_Roi_OnChar(0)", "WPMWidget_Push(false, false)",
		"KL_Ergo_OnKeystroke(0, 0, 0)", "KL_Ergo_OnKeystroke.Call(0, 0, 0)"] {
		Changed := RegExReplace(Commit, "(?s)\n\s*return true\s*\}\s*$",
			"`n`ttry " . Effect . "`n`treturn true`n}", &Count)
		AssertEqual(1, Count, "the outside-guard mutation must replace the actual final return")
		_TES_Reject(Capture, Changed, InStr(Effect, "KL_Ergo_OnKeystroke") = 1
			? "a direct default-owner call must not bypass" : "every ergonomic/ROI/WPM call must be contained")
	}
	for Unexpected in [UnsetError("unexpected source-policy failure"), Error("wrong assertion provenance")] {
		Propagated := false
		try _TES_Reject(Capture, Commit, "the captured manual-only effects guard must be unique",
			_TES_ThrowUnexpected.Bind(Unexpected))
		catch as Actual {
			Assert(Actual = Unexpected, "unexpected refusal must preserve its exact error identity")
			Propagated := true
		}
		AssertTrue(Propagated, "wrong type or assertion provenance cannot become a successful policy refusal")
	}
	; Descriptive text cannot manufacture, or invalidate, executable admission.
	_TES_ReceiptPolicy("; synth_active: Keylogger.synth_active`n" . Capture,
		"; if !" . Name . ".synth_active`n" . Commit)
}
Test("Keylogger synthetic source policy rejects bypasses and noncode decoys", _TES_NegativeControls)

_TES_ThrowUnexpected(Err, *) {
	throw Err
}
