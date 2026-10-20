; tests/unit/ui/editors/test_magic_key_startup_close.ahk

#Requires AutoHotkey v2.0

; Native windows/Show/WM_CLOSE and genuine editor lifecycle execute in an owned
; child. Only hook construction, physical-state and persistence I/O are passive.
_MSUC_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Name in ["_SIHO_ScalarEndKeys", "_SIHO_ReadScalar", "MagicKeyEditor", "MagicKeySourceCapture", "_MagicKeyEditorClose", "_MagicKeyEditorStopOwned",
		"_MagicKeySourceCapturePoll", "_MagicKeySourcePressedScan", "_MagicKeySourceCaptureKeyDown"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "The startup child requires its genuine owner: " . Name)
		if Name == "MagicKeyEditor" || Name == "MagicKeySourceCapture" {
			Definition := StrReplace(Definition, "InputHook(", "_MSUC_CreateHook(", true, &Bindings)
			AssertEqual(1, Bindings, "Only the native hook factory is bound in " . Name)
		}
		if Name == "MagicKeySourceCapture" {
			Definition := StrReplace(Definition, "_MagicKeySourceCaptureState()", "_MSUC_CreateSourceState()", true, &Bindings)
			AssertEqual(1, Bindings, "Only physical-state construction is bound in the source editor")
		}
		Code .= Definition . "`n"
	}
	return Code . FileRead(_DriverDir . "\tests\fixtures\magic_key_startup_close_body.ahk", "UTF-8")
}

_MSUC_Case(Editor, Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "A preceding unsettled editor child must retire first")
	SourceState := _MagicKeySourceCaptureState((*) => false)
	AssertTrue(SourceState.Scans.Length > 0, "The child uses the real manifest's candidate roster")
	Scan := SourceState.Scans[1]
	Code := LayoutRegistry_KeyCode(Scan, LayoutRegistry_Keycodes())
	AssertTrue(MagicKeySourceIsCandidate(Code), "The physical candidate must be admitted by the real manifest")
	Scans := ""
	for Candidate in SourceState.Scans
		Scans .= (Scans == "" ? "" : ",") . Candidate
	Script := A_Temp . "\ergopti_magic_startup_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999) . ".ahk"
	AssertFalse(FileExist(Script), "The child requires a fresh source")
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _MSUC_ChildSource()) != 0)
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Editor, Mode, Code, Scan, Scans,
				String(TimingsGet("ui", "magic_key_capture_poll_ms")), String(TimingsGet("ui", "magic_key_capture_timeout_ms"))],
			_MESC_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "The exact child must complete once: " . State.ErrorText . State.Output)
		AssertEqual(0, State.Code, "The genuine startup rejected its oracle: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "A parse/UI/timer error must never pass as cancellation")
		AssertContains(State.Output, "PASS magic-key-editor-startup-close " . Editor . " " . Mode)
	} catch as Err {
		Primary := Err
	}
	Retired := false
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Result := Handle.terminate()
				Retired := Result is Integer && Result == 1
				if Retired || TickElapsed(Started) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	if !Retired
		RetirementDebt := { handle: Handle, script: Script }
	try {
		if Retired && !IsObject(Primary)
			FileDelete(Script)
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its source is removed")
}

for _MSUC_Editor in ["character", "source"]
	for _MSUC_Mode in ["constructor-close", "show-close"]
		Test("Magic Key startup: " . _MSUC_Editor . " " . _MSUC_Mode . " (magic-key-editor-startup-close)",
			_MSUC_Case.Bind(_MSUC_Editor, _MSUC_Mode))
