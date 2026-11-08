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
	ClipboardSource := StrReplace(ClipboardSource, "CB_WritePlainSnapshot(Capture, Text, &OwnedSequence) {",
		"_WRF_ActualWritePlainSnapshot(Capture, Text, &OwnedSequence) {", true, &NativeReceipts)
	AssertEqual(1, NativeReceipts, "Only the actual complete native CAS publication receipt may be observed")
	Code .= ClipboardSource . "`n"
	for Symbol in ["_TextTailCodeUnits"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The real native wrap dependency must exist: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	for Name in ["TickElapsed", "TickElapsed64", "WrapTextIfSelected", "_WrapSelectionNeedsFreshRead", "_WrapSelectionReady", "_WrapSelectionEmpty", "WrapSymbols_IsEnabled", "GetUIASelection",
		"UIASW_ConsumeSelectionSnapshot", "_UIA_CurrentInputEpoch", "KS_GetPhysicalInputEpoch", "_SendInstantCaptureTarget", "_SendInstantTargetCurrent", "WIGetForegroundHwnd",
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
	Code .= _WRCF_CustomPairSource()
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

; WrapTextIfSelected asks the saved custom pairs which delimiters a key owns.
; The child receives that real lookup with the owner's own empty default, so
; the built-in delimiters stay the ones wrapped.
_WRCF_CustomPairSource() {
	Definition := _DriverFuncBody("WrapSymbols_CustomPairFor")
	AssertTrue(Definition != "", "The real custom-pair lookup must exist")
	Source := FSReadStrict(_DriverProductionFileForSymbol("WrapSymbols_CustomPairFor"))
	AssertTrue(RegExMatch(Source, "m)^global _WS_Custom := \[\][ `t]*$", &Default),
		"The custom-pair owner must declare its empty default list")
	return Default[0] . "`n" . Definition . "`n"
}

_WRCF_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_WRCF_Case(Mode) {
	global SEND_INSTANT_PASTE_DELAY_MS
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
		OwnerSource := FSReadStrict(_DriverProductionFileForSymbol("GetUIASelection"))
		AssertTrue(RegExMatch(OwnerSource, "m)^global UIA_SELECTION_MAX_AGE_MS := ([0-9]+)[ `t]*$", &Age),
			"The isolated child must receive the actual production snapshot age literal, not an unavailable harness global.")
		MaxAge := Integer(Age[1])
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-clipboard-render-focus", Mode,
				String(SEND_INSTANT_PASTE_DELAY_MS), String(MaxAge)], _WRCF_Complete.Bind(State))
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

; No hardware or physical-key claim: the native F6/I0 no-hook child exercises
; the canonical GetLastInputInfo fallback. Physical hook ordering is separate
; source evidence; production's installed-hook behavior is not qualified here.
_WTE_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Code .= "#Include " . _DriverDir . "\_generated\config_keys.ahk`n"
	Owner := _DriverProductionFileForSymbol("_TextTailCodeUnits")
	AssertTrue(Owner != "")
	Code .= "#Include " . Owner . "`n"
	Source := FSReadStrict(_DriverProductionFileForSymbol("GetUIASelection"))
	AssertTrue(RegExMatch(Source, "m)^global UIA_SELECTION_MAX_AGE_MS := ([0-9]+)[ `t]*$", &Age))
	Code .= "global UIA_SELECTION_MAX_AGE_MS := " . Integer(Age[1]) . "`n"
	for Name in ["ErgoptiLayout_Action", "WrapTextIfSelected", "_WrapSelectionNeedsFreshRead", "_WrapSelectionReady", "_WrapSelectionEmpty", "WrapSymbols_IsEnabled", "GetUIASelection",
		"UIASW_ConsumeSelectionSnapshot", "_UIA_CurrentInputEpoch", "KS_GetPhysicalInputEpoch", "_SendInstantCaptureTarget", "_SendInstantTargetCurrent", "WIGetForegroundHwnd",
		"WIGetFocusedControlToken", "TickElapsed", "TickElapsed64", "SendInstant", "_SendInstantReport", "SendNewResult", "_SendVerdictSucceeded"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "The unchanged trigger admission owner must exist: " . Name)
		Code .= Definition . "`n"
	}
	Code .= _WRCF_CustomPairSource()
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\wrap_trigger_epoch_body.ahk")
}

_WTE_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired trigger child prevents another native sender.")
	Root := A_Temp . "\ergopti_wrap_trigger_epoch_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created)
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _WTE_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-wrap-trigger", Mode], _WRCF_Complete.Bind(State))
		AssertTrue(Handle.start())
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# wrap-trigger-epoch " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, "Native no-hook trigger admission failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS wrap-trigger-epoch " . Mode)
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
	AssertTrue(Retired)
}

for _WTE_Mode in ["direct"]
	Test("wrap native trigger admission: " . _WTE_Mode . " (wrap-native-trigger-epoch)", _WTE_Case.Bind(_WTE_Mode))

; Real public gesture, real async clipboard capture; no fabricated admission ports.
_GTRF_ChildSource() {
	global _DriverDir
	Code := _WRCF_ChildSource()
	Suffix := FSReadStrict(_DriverDir . "\tests\fixtures\wrap_clipboard_render_focus_body.ahk")
	AssertEqual(Suffix, SubStr(Code, -StrLen(Suffix)), "Only the previous fixture body may be replaced; all real clipboard/send owners remain intact.")
	Code := SubStr(Code, 1, StrLen(Code) - StrLen(Suffix))
	Code := StrReplace(Code, "_CB_ReleaseRestoreLock(Lock) {", "_GTRF_ActualReleaseRestoreLock(Lock) {", true, &Releases)
	AssertEqual(1, Releases, "Only the complete native restore-release boundary may be decorated.")
	for Name in ["GestureTransformSelection", "_GestureSendTransformedSelection", "GetSelectionAsync",
		"_SelectionCaptureForeground", "_SelectionReportClipboardBusy", "_SelectionForegroundProcess",
		"_SelectionCaptureStartCurrent", "_SelectionCaptureAbortStart", "_SelectionCaptureReleaseTimer",
		"_SelectionCapturePoll", "_SelectionCaptureReadReady", "_SelectionCaptureProbeSequence",
		"_SelectionCaptureFinish", "_SelectionCaptureCurrentContext", "_SelectionClipboardSequence",
		"GetSelectionCancel", "KS_GetPhysicalInputGeneration", "TapHoldNewOwner", "TapHoldOwnerCurrent", "_TextSenderAtSendLevel",
		"KL_MarkSynthetic", "KL_ClearSynthetic", "TimingsGet", "IniCacheGet"]
		Code .= _DriverFuncBody(Name) . "`n"
	Copy := _DriverFuncBody("_SelectionSendCopy")
	Copy := StrReplace(Copy, 'SendEvent.Bind("^c")', "_GTRF_NativeCopy", true, &Copies)
	AssertEqual(1, Copies, "The real copy helper must delegate only its native transport to the owned-window guard.")
	Code .= Copy . "`n"
	Code .= "global _SelectionCaptureJob := false, _SelectionCaptureNextId := 0, _KS_PhysicalInputGeneration := 0, _TH_SyntheticEpoch := 0`n"
	for Name in ["SELECTION_CAPTURE_POLL_MS", "GET_SELECTION_TIMEOUT_SEC", "TEXT_SENDER_SEND_LEVEL"] {
		Pattern := "m)^global " . Name . " := ([0-9]+(?:\.[0-9]+)?)[ `t]*$"
		Owner := Name == "SELECTION_CAPTURE_POLL_MS" ? "GetSelectionAsync" : Name == "GET_SELECTION_TIMEOUT_SEC" ? "HotstringEngineInit" : "_TextSenderAtSendLevel"
		Source := FSReadStrict(_DriverProductionFileForSymbol(Owner))
		AssertTrue(RegExMatch(Source, Pattern, &Value), "The native child requires the production constant " . Name)
		Code .= "global " . Name . " := " . Value[1] . "`n"
	}
	Code .= 'global Keystats := {synth_owners: [], synth_active: 0, synth_type: "none", synth_private: false, scalar_fragment: false, scalar_history: false, scalar_epoch: 1}' . "`n"
	Code .= 'global _TimingsCache := Map("gestures", Map("synthetic_clear_ms", ' . TimingsGet("gestures", "synthetic_clear_ms") . "))`n"
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\gesture_transform_render_focus_body.ahk")
}
_GTRF_Case(Mode) {
	global SEND_INSTANT_PASTE_DELAY_MS
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired owned clipboard probe prevents another native publisher.")
	Root := A_Temp . "\ergopti_gesture_transform_render_focus_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The fixture must exclusively own its script and evidence directory.")
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _GTRF_ChildSource()))
		OwnerSource := FSReadStrict(_DriverProductionFileForSymbol("GetUIASelection"))
		AssertTrue(RegExMatch(OwnerSource, "m)^global UIA_SELECTION_MAX_AGE_MS := ([0-9]+)[ `t]*$", &Age),
			"The isolated child must receive the actual production snapshot age literal, not an unavailable harness global.")
		MaxAge := Integer(Age[1])
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-clipboard-render-focus", Mode,
				String(SEND_INSTANT_PASTE_DELAY_MS), String(MaxAge)], _WRCF_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact native clipboard/render subject must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 12000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# gesture-transform-render-focus " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls, "The actual clipboard and native paste owner must settle exactly once.")
		AssertEqual(0, State.Code, "The native wrap render focus probe failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS gesture-transform-render-focus " . Mode)
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

for _GTRF_Mode in ["current", "redirect"]
	Test("gesture transform native clipboard renderer: " . _GTRF_Mode . " (gesture-transform-native-render-focus)", _GTRF_Case.Bind(_GTRF_Mode))

; Requires the genuine gesture/capture composition defined alongside WRCF.
_SCCF_ChildSource() {
	global _DriverDir
	Code := _GTRF_ChildSource()
	Suffix := FSReadStrict(_DriverDir . "\tests\fixtures\gesture_transform_render_focus_body.ahk")
	AssertEqual(Suffix, SubStr(Code, -StrLen(Suffix)), "Only the private fixture body changes; every real capture/context/send owner remains intact.")
	return SubStr(Code, 1, StrLen(Code) - StrLen(Suffix))
		. FSReadStrict(_DriverDir . "\tests\fixtures\selection_capture_control_focus_body.ahk")
}
_SCCF_Case(Mode) {
	global SEND_INSTANT_PASTE_DELAY_MS
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired owned clipboard probe prevents another native publisher.")
	Root := A_Temp . "\ergopti_selection_capture_control_focus_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The fixture must exclusively own its script and evidence directory.")
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SCCF_ChildSource()))
		OwnerSource := FSReadStrict(_DriverProductionFileForSymbol("GetUIASelection"))
		AssertTrue(RegExMatch(OwnerSource, "m)^global UIA_SELECTION_MAX_AGE_MS := ([0-9]+)[ `t]*$", &Age),
			"The isolated child must receive the actual production snapshot age literal, not an unavailable harness global.")
		MaxAge := Integer(Age[1])
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-clipboard-render-focus", Mode,
				String(SEND_INSTANT_PASTE_DELAY_MS), String(MaxAge)], _WRCF_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact native clipboard/render subject must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 12000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# selection-capture-control-focus " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls, "The actual clipboard and native paste owner must settle exactly once.")
		AssertEqual(0, State.Code, "The native wrap render focus probe failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS selection-capture-control-focus " . Mode)
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

for _SCCF_Mode in ["current", "redirect"]
	Test("selection capture native same-window focus: " . _SCCF_Mode . " (selection-capture-native-control-focus)", _SCCF_Case.Bind(_SCCF_Mode))

_GTTL_ChildSource() {
	global _DriverDir
	Code := _GTRF_ChildSource()
	Suffix := FSReadStrict(_DriverDir . "\tests\fixtures\gesture_transform_render_focus_body.ahk")
	AssertEqual(Suffix, SubStr(Code, -StrLen(Suffix)), "Only the isolated fixture changes; actual capture/send/clipboard owners remain intact")
	Code := SubStr(Code, 1, StrLen(Code) - StrLen(Suffix))
	Code := StrReplace(Code, "KL_MarkSynthetic(source, is_private := false) {",
		"_GTTL_ActualMarkSynthetic(source, is_private := false) {", true, &Owners)
	AssertEqual(1, Owners, "The complete genuine synthetic-owner publication may only receive a passive scheduling observer")
	Title := _DriverFuncBody("TextCaseTitle")
	Title := StrReplace(Title, "TextCaseTitle(Text) {", "_GTTL_ActualTextCaseTitle(Text) {", true, &Transforms)
	AssertEqual(1, Transforms, "The actual title-case implementation must remain unchanged behind a passive running-phase observer")
	; The title of a word's first character comes from the generated Unicode
	; title table, so the child carries that real lookup beside the transform.
	Character := _DriverFuncBody("TextCaseTitleCharacter")
	AssertTrue(Character != "", "The actual title-case character lookup must exist")
	Title .= "`n" . Character . "`n#Include " . _DriverDir . "\_generated\unicode_title.ahk"
	return Code . Title . "`n" . FSReadStrict(_DriverDir . "\tests\fixtures\gesture_title_transform_target_body.ahk")
}
_GTTL_Case(Mode) {
	global SEND_INSTANT_PASTE_DELAY_MS
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired owned clipboard probe prevents another native publisher.")
	Root := A_Temp . "\ergopti_gesture_title_transform_target_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The fixture must exclusively own its script and evidence directory.")
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _GTTL_ChildSource()))
		OwnerSource := FSReadStrict(_DriverProductionFileForSymbol("GetUIASelection"))
		AssertTrue(RegExMatch(OwnerSource, "m)^global UIA_SELECTION_MAX_AGE_MS := ([0-9]+)[ `t]*$", &Age),
			"The isolated child must receive the actual production snapshot age literal, not an unavailable harness global.")
		MaxAge := Integer(Age[1])
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-clipboard-render-focus", Mode,
				String(SEND_INSTANT_PASTE_DELAY_MS), String(MaxAge)], _WRCF_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact native clipboard/render subject must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 12000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# gesture-title-transform-target " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls, "The actual clipboard and native paste owner must settle exactly once.")
		AssertEqual(0, State.Code, "The native wrap render focus probe failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS gesture-title-transform-target " . Mode)
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

for _GTTL_Mode in ["current", "redirect"]
	Test("gesture title transform native target: " . _GTTL_Mode . " (gesture-title-native-transform-target)", _GTTL_Case.Bind(_GTTL_Mode))


_WFC_ChildSource() {
	global _DriverDir
	Code := _GTRF_ChildSource()
	Suffix := FSReadStrict(_DriverDir . "\tests\fixtures\gesture_transform_render_focus_body.ahk")
	AssertEqual(Suffix, SubStr(Code, -StrLen(Suffix)), "Only the unrelated renderer fixture entry may be replaced")
	Code := SubStr(Code, 1, StrLen(Code) - StrLen(Suffix))
	Code .= _DriverFuncBody("ErgoptiLayout_Action") . "`n"
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\wrap_fresh_selection_body.ahk")
}
_WFC_Case(Mode) {
	global SEND_INSTANT_PASTE_DELAY_MS
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired owned clipboard probe prevents another native publisher.")
	Root := A_Temp . "\ergopti_wrap_fresh_selection_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The fixture must exclusively own its script and evidence directory.")
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _WFC_ChildSource()))
		OwnerSource := FSReadStrict(_DriverProductionFileForSymbol("GetUIASelection"))
		AssertTrue(RegExMatch(OwnerSource, "m)^global UIA_SELECTION_MAX_AGE_MS := ([0-9]+)[ `t]*$", &Age),
			"The isolated child must receive the actual production snapshot age literal, not an unavailable harness global.")
		MaxAge := Integer(Age[1])
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-wrap-fresh-selection", Mode,
				String(SEND_INSTANT_PASTE_DELAY_MS), String(MaxAge)], _WRCF_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact native clipboard/render subject must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 12000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# wrap-fresh-selection " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls, "The actual clipboard and native paste owner must settle exactly once.")
		AssertEqual(0, State.Code, "The native wrap render focus probe failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS wrap-fresh-selection " . Mode)
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

for _WFC_Mode in ["fresh", "empty", "timeout", "supersession"]
	Test("wrap fresh selection native receiver: " . _WFC_Mode . " (wrap-native-fresh-selection)", _WFC_Case.Bind(_WFC_Mode))
