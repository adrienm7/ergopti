; tests/unit/modules/shortcuts/test_wrap_selection_action.ahk

; ==============================================================================
; MODULE: wrap_selection Action and its wrap_pair Parameter (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/action_parameters/wrap_pair_vectors.json, which
; the macOS and Linux suites replay too, through GestureValidateActionParameter
; and GestureWrapPairFor over the real built-in catalogue, and checks that the
; action wraps the selection with the pair stored for its binding.
;
; ROOT CAUSE ENCODED:
; The only wrap action (surround_parens) wrapped the line in parentheses; no
; action could wrap the selection with a chosen pair, and parameter validation
; only knew URLs.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body with the built-in catalogue loaded from the shared JSON, then puts
; the harness globals back.
_WSA_WithCatalogue(Body) {
	global _WS_BUILTIN_PAIRS, _WS_BUILTIN_GROUPS
	SavedPairs := _WS_BUILTIN_PAIRS
	SavedGroups := _WS_BUILTIN_GROUPS
	try {
		_WS_LoadBuiltinCatalogue()
		AssertTrue(_WS_BUILTIN_PAIRS.Length >= 30, "the shared catalogue must load")
		return Body.Call()
	} finally {
		_WS_BUILTIN_PAIRS := SavedPairs
		_WS_BUILTIN_GROUPS := SavedGroups
	}
}

_WSA_ReplayCorpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\action_parameters\wrap_pair_vectors.json"
	AssertTrue(FileExist(Path) != "", "the wrap-pair corpus must exist at " . Path)
	Corpus := JsonParse(FileRead(Path, "UTF-8"))
	AssertEqual("wrap_pair", GestureActionParameterSpec("wrap_selection"), "wrap_selection parameter kind")
	Checked := _WSA_WithCatalogue(() => _WSA_ReplayVectors(Corpus["vectors"]))
	AssertTrue(Checked >= 15, "expected at least 15 wrap-pair vectors, found " . Checked)
}

; @returns {Integer} The number of vectors replayed.
_WSA_ReplayVectors(Vectors) {
	Checked := 0
	for _, Vector in Vectors {
		Valid := !Vector.Has("valid") || Vector["valid"]
		ErrorText := ""
		AssertEqual(Valid, GestureValidateActionParameter("wrap_selection", Vector["value"], &ErrorText),
			Vector["id"] . ": validation")
		Pair := GestureWrapPairFor(Vector["value"])
		if Valid {
			AssertTrue(Pair is Map, Vector["id"] . ": a valid value names a pair")
			AssertEqual(Vector["left"], Pair["left"], Vector["id"] . ": left")
			AssertEqual(Vector["right"], Pair["right"], Vector["id"] . ": right")
		} else {
			AssertEqual("", Pair, Vector["id"] . ": an invalid value names no pair")
			AssertTrue(ErrorText != "", Vector["id"] . ": a refusal explains itself")
		}
		Checked += 1
	}
	return Checked
}
Test("wrap_selection: the wrap_pair parameter replays the shared corpus", _WSA_ReplayCorpus)

_WSA_WrapsWithTheBindingPair() {
	global GestureActionParameters, GESTURE_ACTIONS
	AssertTrue(GESTURE_ACTIONS.Has("wrap_selection"), "wrap_selection must be a registered action")
	Saved := GestureActionParameters
	try {
		GestureActionParameters := Map(GestureActionParameterKey("tap_3", "wrap_selection"), "«")
		_WSA_WithCatalogue(() => (
			AssertEqual("« été »", GestureWrapSelectionTransform("tap_3").Call("été"),
				"the stored pair wraps the selection"),
			AssertEqual("", GestureWrapSelectionTransform("tap_4"),
				"a binding without a stored pair builds no transform")
		))
	} finally {
		GestureActionParameters := Saved
	}
}
Test("wrap_selection: wraps with the pair stored for its binding", _WSA_WrapsWithTheBindingPair)

_WRCF_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Code .= "#Include " . _DriverDir . "\_generated\config_keys.ahk`n"
	ClipboardOwner := _DriverProductionFileForSymbol("CB_Write")
	AssertTrue(ClipboardOwner != "")
	ClipboardSource := FSReadStrict(ClipboardOwner)
	ClipboardSource := StrReplace(ClipboardSource, "CB_WriteTextWithReceipt(Text, &OwnedSequence := 0) {",
		"_WRF_ActualWriteTextWithReceipt(Text, &OwnedSequence := 0) {", true, &Receipts)
	AssertEqual(1, Receipts, "Only the actual authenticated publication receipt boundary may be observed")
	Code .= ClipboardSource . "`n"
	for Symbol in ["_TextTailCodeUnits"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The real native wrap dependency must exist: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	for Name in ["TickElapsed", "TickElapsed64", "WrapTextIfSelected", "WrapSymbols_IsEnabled", "GetUIASelection",
		"UIASW_ConsumeSelectionSnapshot", "_UIA_CurrentInputEpoch", "KS_GetPhysicalInputEpoch", "WIGetForegroundHwnd",
		"WIGetFocusedControlToken", "_TextSenderNativeFocus", "_SendVerdictSucceeded", "_SendInstantReport", "_SendInstant_RestoreClipboard"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "The complete original wrap owner must exist: " . Name)
		if Name == "_SendInstant_RestoreClipboard" {
			Definition := StrReplace(Definition, "_SendInstant_RestoreClipboard(OldClip, OwnedSequence, OwnerToken) {",
				"_WRF_ActualRestoreClipboard(OldClip, OwnedSequence, OwnerToken) {", true, &Restores)
			AssertEqual(1, Restores, "The exact restore helper may only receive a passive fire observer")
		}
		Code .= Definition . "`n"
	}
	Body := _DriverFuncBody("SendInstant")
	AssertTrue(Body != "")
	Body := StrReplace(Body, "SetTimer(RestoreCallback, -SEND_INSTANT_PASTE_DELAY_MS)",
		"_WRF_ObserveRestoreTimer(RestoreCallback, -SEND_INSTANT_PASTE_DELAY_MS)", true, &Timers)
	AssertEqual(1, Timers, "The real timer registration must delegate unchanged and retain its exact callback for owned teardown")
	Masked := _DriverMaskNonCode(&Body)
	Position := 1, Overlaid := "", Count := 0
	while RegExMatch(Masked, "\bSendInput(?=[ `t]*\()", &Site, Position) {
		Overlaid .= SubStr(Body, Position, Site.Pos - Position) . "_WRF_NativeSend"
		Position := Site.Pos + Site.Len
		Count += 1
	}
	AssertEqual(3, Count, "Only the native paste/direct transports may be decorated with owned-window guards")
	Code .= Overlaid . SubStr(Body, Position) . "`n"
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\wrap_clipboard_render_focus_body.ahk")
}

_WRCF_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_WRCF_Case(Mode) {
	global SEND_INSTANT_PASTE_DELAY_MS, UIA_SELECTION_MAX_AGE_MS
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired owned clipboard probe prevents another native publisher.")
	Root := A_Temp . "\ergopti_wrap_render_focus_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The fixture must exclusively own its script and evidence directory.")
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _WRCF_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-clipboard-render-focus", Mode,
				String(SEND_INSTANT_PASTE_DELAY_MS), String(UIA_SELECTION_MAX_AGE_MS)], _WRCF_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact native clipboard/render subject must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 12000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# wrap-render-focus " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls, "The actual clipboard and native paste owner must settle exactly once.")
		AssertEqual(0, State.Code, "The native wrap render focus probe failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS wrap-render-focus " . Mode)
	} catch as Err {
		Primary := Err
	}
	try Retired := !IsObject(Handle) || ((Receipt := Handle.terminate()) is Integer && Receipt == 1)
	catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	try {
		if !Retired && Created
			RetirementDebt := {Handle: Handle, Root: Root}
		else if Retired && Created && !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact clipboard subject must retire before its script directory is removed.")
}

for _WRCF_Mode in ["current", "redirect"]
	Test("wrap selection native clipboard renderer: " . _WRCF_Mode . " (wrap-native-render-focus)", _WRCF_Case.Bind(_WRCF_Mode))
