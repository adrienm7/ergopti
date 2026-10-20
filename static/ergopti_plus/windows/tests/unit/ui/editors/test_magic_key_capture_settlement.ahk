; tests/unit/ui/editors/test_magic_key_capture_settlement.ahk

; The actual editors run in an isolated child with only their native factory
; and physical-state lookup ports bound. GUI Close, Suspend, the Stop owner,
; capture poll and nested successor all execute their genuine product paths.
_MESC_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Name in ["MagicKeyEditor", "MagicKeySourceCapture", "_MagicKeyEditorClose", "_MagicKeyEditorStopOwned",
		"_MagicKeySourceCapturePoll", "_MagicKeySourcePressedScan", "_MagicKeySourceCaptureKeyDown"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the editor fixture requires its genuine owner: " . Name)
		if Name == "MagicKeyEditor" || Name == "MagicKeySourceCapture" {
			Definition := StrReplace(Definition, "InputHook(", "_MESC_CreateHook(", true, &Bindings)
			AssertEqual(1, Bindings, "only the native factory is bound in " . Name)
		}
		if Name == "MagicKeySourceCapture" {
			Definition := StrReplace(Definition, "_MagicKeySourceCaptureState()", "_MESC_CreateSourceState()", true, &Bindings)
			AssertEqual(1, Bindings, "only physical-state construction is bound in the source editor")
		}
		Code .= Definition . "`n"
	}
	return Code . FileRead(_DriverDir . "\tests\fixtures\magic_key_capture_settlement_body.ahk", "UTF-8")
}

_MESC_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_MESC_Case(Editor, Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "a preceding unsettled editor child must retire before another opens")
	SourceState := _MagicKeySourceCaptureState((*) => false)
	AssertTrue(SourceState.Scans.Length > 0, "the physical fixture uses the real manifest's candidate roster")
	Scan := SourceState.Scans[1]
	Code := LayoutRegistry_KeyCode(Scan, LayoutRegistry_Keycodes())
	AssertTrue(MagicKeySourceIsCandidate(Code), "the fixture's physical key must be admitted by the actual manifest")
	Scans := ""
	for Candidate in SourceState.Scans
		Scans .= (Scans == "" ? "" : ",") . Candidate
	Script := A_Temp . "\ergopti_magic_capture_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999) . ".ahk"
	AssertFalse(FileExist(Script), "the editor child requires a fresh source")
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _MESC_ChildSource()) != 0)
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Editor, Mode, Code, Scan, Scans,
				String(TimingsGet("ui", "magic_key_capture_poll_ms")), String(TimingsGet("ui", "magic_key_capture_timeout_ms"))],
			_MESC_Complete.Bind(State))
		AssertTrue(Handle.start(), "the real editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the exact editor child must complete once: " . State.ErrorText . State.Output)
		AssertEqual(0, State.Code, "the editor rejected its settlement oracle: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "a parse, UI or timer error must never pass as capture refusal")
		AssertContains(State.Output, "PASS magic-key-capture-settlement " . Editor . " " . Mode)
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
				Retired := (Result is Integer) && Result == 1
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
	AssertTrue(Retired, "the exact editor child must retire before its source is removed")
}

for _MESC_Editor in ["character", "source"]
	for _MESC_Mode in ["live", "cancel", "completed-close", "completed-paused-resumed", "completed-close-successor", "stop-refusal", "stop-reentrant"]
		Test("Magic Key capture settlement: " . _MESC_Editor . " " . _MESC_Mode . " (magic-key-capture-settlement)",
			_MESC_Case.Bind(_MESC_Editor, _MESC_Mode))
