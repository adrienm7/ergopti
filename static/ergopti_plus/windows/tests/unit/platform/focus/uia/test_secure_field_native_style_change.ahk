; tests/unit/platform/focus/uia/test_secure_field_native_style_change.ahk

; Each child installs the actual native focus hook. The conclusive Edit path
; uses the real adapter; UIA is forbidden rather than replaced with an admission.
_SFS_ChildSource() {
	global _DriverDir
	static Cached := ""
	if Cached != ""
		return Cached
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#Warn All, StdOut`n"
	for Name in ["SFD_IsSecureField", "SFD_FocusedHwnd", "SFD_DetectNative", "SFD_CommitFieldVerdict",
		"SFD_TryGetCachedVerdict", "SFD_FocusSnapshot", "SFD_InvalidateFocus", "SFD_FocusEventCallback",
		"SFD_FreeFocusCallback", "SFD_EnsureFocusTracking", "SFD_Stop", "TickElapsed64", "TickExpired64",
		"SFD_IsSecureAppWindow", "SFD_IsSecureApp", "SFD_ProcessNameOf"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "The actual native detector dependency must exist: " . Name)
		Source .= Definition . "`n"
	}
	Owners := 0
	for Path in _DriverProductionSourceCensus().Paths {
		Candidate := FileRead(Path, "UTF-8")
		Begin := InStr(Candidate, "global SFD_FIELD_CACHE := Map(")
		if !Begin
			continue
		Owners += 1
		End := InStr(Candidate, "`n)", false, Begin)
		AssertTrue(End > Begin, "The actual detector cache initializer must have its closing delimiter")
		Source .= SubStr(Candidate, Begin, End - Begin + 2) . "`n"
		AssertTrue(RegExMatch(Candidate, "m)^global SFD_FIELD_CACHE_TTL_MS := [0-9]+$", &Ttl),
			"The native probe must retain the actual detector TTL")
		Source .= Ttl[0] . "`n"
		; The secure-application gate runs first in SFD_IsSecureField (ADD-1).
		AssertTrue(RegExMatch(Candidate, "m)^global SFD_SECURE_APP_ROOT := .+$", &Root),
			"The detector must retain its per-window secure-application cache")
		Source .= Root[0] . "`n"
	}
	AssertEqual(1, Owners, "One actual adapter owns the detector cache")
	; The child's windows belong to AutoHotkey, never a secure application: the
	; shared list is not this probe's subject, so it holds none while the ADD-1
	; gate of SFD_IsSecureField stays the real one.
	Source .= 'SFD_SecureApps() {`n`tApps := Map()`n`tApps.CaseSense := "Off"`n`treturn Apps`n}`n'
	return Cached := Source . FileRead(_DriverDir . "\tests\fixtures\core\secure_field_native_style_body.ahk", "UTF-8")
}
_SFS_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}
_SFS_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired native detector child prevents another probe")
	Directory := A_Temp . "\ergopti_sfd_style_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Retired := false, Primary := 0
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Directory)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The child requires an exclusively acquired directory")
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SFS_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, "--allow-owned-native-password-style-probe"], _SFS_Complete.Bind(State))
		AssertTrue(Handle.start(), "The private native detector child must start")
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# sfd-style mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS secure-field-native-style " . Mode)
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
		else if Created && Retired
			DirDelete(Directory, true)
	} catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Only a retired exact child permits private source cleanup")
}
for _SFS_Mode in ["normal-current", "password-current", "password-expired"]
	Test("Secure field native style: " . _SFS_Mode . " follows the same owned Edit (secure-field-native-style-change)",
		_SFS_Case.Bind(_SFS_Mode))
