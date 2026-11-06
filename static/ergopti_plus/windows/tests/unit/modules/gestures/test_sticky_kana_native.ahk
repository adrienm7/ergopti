; tests/unit/modules/gestures/test_sticky_kana_native.ahk

_SKN_ChildSource() {
	global _DriverDir
	Source := _SSM_ChildSource()
	Footer := FSReadStrict(_DriverDir . "\tests\fixtures\sticky_modifier_flags_body.ahk")
	AssertEqual(Footer, SubStr(Source, -StrLen(Footer)), "Only the unrelated Shift fixture entry may be replaced")
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	return Source . FSReadStrict(_DriverDir . "\tests\fixtures\sticky_kana_native_body.ahk")
}
_SKN_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}
_SKN_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired child prevents another native probe")
	Directory := A_Temp . "\ergopti_sticky_kana_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Retired := false, Primary := 0
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Directory)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The child requires an exclusively acquired directory")
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SKN_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-owned-native-kana-sticky", Mode], _SKN_Complete.Bind(State))
		AssertTrue(Handle.start(), "The actual sticky producer child must start")
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# sticky-kana mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS sticky-kana-native " . Mode)
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
for _SKN_Mode in ["plain", "kana-held"]
	Test("sticky native Kana admission: " . _SKN_Mode . " retains the following modified F6 (sticky-kana-native)",
		_SKN_Case.Bind(_SKN_Mode))

Test("sticky native Kana release: captured original flags survive native modifier release before replay (sticky-kana-native-released)",
	_SKN_Case.Bind("kana-released"))

Test("sticky native Kana endpoint: a custom modifier released before F6 does not leak into replay (sticky-kana-native-up-before)",
	_SKN_Case.Bind("kana-up-before-key"))

Test("sticky native Kana initial hold: native OEM held before admission survives release at endpoint (sticky-kana-native-preheld)",
	_SKN_Case.Bind("kana-preheld-released"))
