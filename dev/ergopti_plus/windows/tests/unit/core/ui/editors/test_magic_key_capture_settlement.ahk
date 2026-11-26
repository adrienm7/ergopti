; tests/unit/core/ui/editors/test_magic_key_capture_settlement.ahk

; The actual editor runs in an isolated child with only its native factory
; bound. GUI Close, Suspend, the Stop owner,
; capture poll and nested successor all execute their genuine product paths.
_MESC_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Name in ["_SIHO_ScalarEndKeys", "_SIHO_FillUnitRun", "_SIHO_ReadScalar", "MagicKeyEditor", "_MagicKeyEditorClose", "_MagicKeyEditorStopOwned"] {
		Definition := _DriverFuncBody(Name)
		AssertTrue(Definition != "", "the editor fixture requires its genuine owner: " . Name)
		if Name == "MagicKeyEditor" {
			Definition := StrReplace(Definition, "InputHook(", "_MESC_CreateHook(", true, &Bindings)
			AssertEqual(1, Bindings, "only the native factory is bound in " . Name)
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
	Script := A_Temp . "\ergopti_magic_capture_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999) . ".ahk"
	AssertFalse(FileExist(Script), "the editor child requires a fresh source")
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _MESC_ChildSource()) != 0)
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Editor, Mode],
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

for _MESC_Mode in ["live", "cancel", "completed-close", "completed-paused-resumed", "completed-close-successor", "stop-refusal", "stop-reentrant"]
	Test("Magic Key capture settlement: character " . _MESC_Mode . " (magic-key-capture-settlement)",
		_MESC_Case.Bind("character", _MESC_Mode))

; The magic key character capture runs while paused (EDD-1, decided by the
; coordinator on 2026-11-14): it refused in silence while paused, its tray row
; live (paused-magic-capture).
Test("Magic Key capture settlement: character paused-live persists the character captured while paused (paused-magic-capture)",
	_MESC_Case.Bind("character", "paused-live"))

for _MESC_ScalarMode in ["scalar-pair", "invalid-high-BMP", "invalid-low", "invalid-max"]
	Test("Magic Key scalar settlement: " . _MESC_ScalarMode . " never persists partial units (magic-key-scalar-settlement)",
		_MESC_Case.Bind("character", _MESC_ScalarMode))
