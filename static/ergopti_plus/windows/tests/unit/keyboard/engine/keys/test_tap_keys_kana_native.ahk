; tests/unit/keyboard/engine/keys/test_tap_keys_kana_native.ahk

; The genuine tap predicates, handlers and static declarations receive native
; INPUT40 scan codes. Only the foreground layout-family identity and action
; sink are ports: an ordinary native VK_OEM_8 is the Kana logical AltGr seam.
; This does not claim an installed Kana layout or physical hardware injection.
_TKN_ChildSource() {
	global _DriverDir
	static Cached := ""
	if Cached != ""
		return Cached
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#Warn All, StdOut`n"
	for Name in ["TapKeyShouldFire", "_TapKeysCategoryEnabled", "TapKeyFire", "TapKeyBindingId",
		"TapHoldKanaAltGrHeld", "KS_AltGrKeyName", "AiActionBlocked", "AiActionIsAi", "GestureBindingId"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "The actual tap-key dependency must exist: " . Name)
		Source .= Definition . "`n"
	}
	Declarations := "", Owners := 0
	for Path in _DriverProductionSourceCensus().Paths {
		Candidate := FileRead(Path, "UTF-8")
		if !InStr(Candidate, 'SC029:: TapKeyFire("number_row_left")')
			continue
		Owners += 1
		for Line in StrSplit(Candidate, "`n") {
			if SubStr(Line, 1, 6) == "#HotIf" || RegExMatch(Line, "^SC[0-9A-F]+:: TapKeyFire\(")
				Declarations .= Line . "`n"
		}
	}
	AssertEqual(1, Owners, "There must be one actual static tap-key producer")
	AssertEqual(3, StrSplit(Declarations, "::").Length - 1, "All three genuine static suffixes must be retained")
	; Static declarations follow the fixture's completed auto-execute section.
	return Cached := Source . FileRead(_DriverDir . "\tests\fixtures\keyboard\tap_keys_kana_native_body.ahk", "UTF-8")
		. "`n" . Declarations
}
_TKN_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}
_TKN_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired child prevents another native probe")
	Directory := A_Temp . "\ergopti_tap_kana_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Retired := false, Primary := 0
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Directory)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The child requires an exclusively acquired directory")
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _TKN_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, "--allow-owned-native-kana-tap-probe"], _TKN_Complete.Bind(State))
		AssertTrue(Handle.start(), "The actual static tap producer child must start")
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# tap-kana mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS tap-kana-native " . Mode)
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
			RetirementDebt := {Directory: Directory, Handle: Handle}
		else if Created && Retired && !IsObject(Primary)
			DirDelete(Directory, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Only a retired exact child permits private source cleanup")
}
for _TKN_Mode in ["kana-plain", "kana-held", "standard-held"]
	Test("tap keys native Kana admission: " . _TKN_Mode . " preserves all three suffixes (tap-keys-kana-native)",
		_TKN_Case.Bind(_TKN_Mode))
