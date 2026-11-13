; tests/unit/hotstrings/engine/prefix/test_backspace_native_owned.ahk

; Isolated child: genuine native style/focus/I1 input and both public producers.
; The deferred publication and transport services are explicitly passive ports;
; immediate buffer retirement and captured privacy are the only business oracle.
_SFBX_ChildSource() {
	global _DriverDir
	static Cached := ""
	if Cached != ""
		return Cached
	Detector := _SFS_ChildSource()
	Boundary := InStr(Detector, "; tests/fixtures/core/secure_field_native_style_body.ahk")
	AssertTrue(Boundary > 0, "the shared genuine native detector builder must expose its fixture boundary")
	Source := SubStr(Detector, 1, Boundary - 1)
	for Name in ["LLM_Bridge_FeedCharForPrefix", "LLM_Bridge_FeedKeyDownIfActive", "LLM_Bridge_OnBackspace",
		"_LLM_Bridge_ReadFocusReceipt", "_LLM_Bridge_BindTypingSource", "_LLM_Bridge_SameTypingSource",
		"_LLM_Bridge_TypingFieldCurrent", "_LLM_Bridge_TypingStateCurrent", "_LLM_Bridge_CachedTypingSecure",
		"_LLM_Bridge_RejectPrivateTyping", "_LLM_Bridge_ApplyBufferEdit", "_LLM_Bridge_ClearBuffer",
		"_LLM_Bridge_PrepareInput", "LLM_Bridge_HasIncompleteInput", "LLM_Bridge_DiscardIncompleteInput",
		"_LLM_Bridge_InvalidateIncompleteTyping", "_LLM_Bridge_SchedulePrefixObserver", "LLM_Bridge_CancelPrefixObserver",
		"_TextTailCodeUnits", "_TextCompleteTailScalar", "_TextTailWithinUnits", "_TextCodepointStart",
		"WIGetForegroundHwnd", "WIGetFocusedControlToken", "KS_GetPhysicalInputGeneration",
		"TimerSetCallback", "_TimerAdapterSetNative", "_TimerAdapterFitsNative", "TimerDelayWithinCeiling"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the actual Backspace dependency must exist: " . Name)
		Source .= Definition . "`n"
	}
	for Symbol in ["LLM_BRIDGE_BUFFER_MAX_CHARS", "TIMER_ADAPTER_MAX_INTERVAL_MS", "TIMER_MAX_DELAY_MS"] {
		Found := 0
		for Path in _DriverProductionSourceCensus().Paths {
			Candidate := FileRead(Path, "UTF-8")
			if RegExMatch(Candidate, "m)^global " . Symbol . " := [^`n]+$", &Declaration) {
				Source .= Declaration[0] . "`n"
				Found += 1
			}
		}
		AssertEqual(1, Found, "the shared native producer limit must have one actual declaration: " . Symbol)
	}
	return Cached := Source . FileRead(_DriverDir . "\tests\fixtures\prefix_backspace_native_owned_body.ahk", "UTF-8")
}
_SFBX_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}
_SFBX_Case(Mode) {
	static Debt := 0
	AssertFalse(IsObject(Debt), "a retained native Backspace child blocks another probe")
	Directory := A_Temp . "\ergopti_bsgap_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Retired := false, Primary := 0
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Directory)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "the native child requires an exclusively acquired directory")
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SFBX_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, "--allow-owned-native-backspace-gap"], _SFBX_Complete.Bind(State))
		AssertTrue(Handle.start())
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# backspace-native mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS prefix-backspace-native " . Mode)
	} catch Any as Failure {
		Primary := Failure
	}
	try Retired := !IsObject(Handle) || ((Receipt := Handle.terminate()) is Integer && Receipt == 1)
	catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if Created && !Retired
			Debt := {Directory: Directory, Handle: Handle}
		else if Created && Retired
			DirDelete(Directory, true)
	} catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the private source directory can retire only after its exact child")
}
for _SFBX_Mode in ["private", "normal"]
	Test("Native Backspace privacy: " . _SFBX_Mode . " uses the actual owned Edit (prefix-backspace-native-owned)", _SFBX_Case.Bind(_SFBX_Mode))
