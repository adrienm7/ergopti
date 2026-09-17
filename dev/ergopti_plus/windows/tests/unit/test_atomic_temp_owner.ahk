; tests/unit/test_atomic_temp_owner.ahk

; ==============================================================================
; MODULE: Atomic Temporary File Ownership Tests
; DESCRIPTION: Age alone cannot authorize retiring another writer's staged data.
; ==============================================================================

#Requires AutoHotkey v2.0

_ATO_ReapOwnedDebris(ReapFn) {
	_KLRDC_Reset()
	try {
		Path := _KLRDC_Root() . "snapshot.json"
		Window := Gui()
		DeadOwner := Window.Hwnd
		Window.Destroy()
		AssertFalse(DllCall("IsWindow", "Ptr", DeadOwner, "Int"))
		Cases := Map(
			"live", "." . A_ScriptHwnd . "-1.tmp",
			"dead", "." . DeadOwner . "-1.tmp",
			"fresh", "." . DeadOwner . "-2.tmp",
			"foreign", ".foreign.tmp",
			"zero", ".0-1.tmp",
			"overflow", ".4294967296-1.tmp",
			"zero-sequence", "." . DeadOwner . "-0.tmp",
			"extra-prefix", ".foreign." . DeadOwner . "-1.tmp")
		for Label, Suffix in Cases {
			FileAppend(Label, Path . Suffix, "UTF-8-RAW")
			if Label != "fresh"
				FileSetTime(DateAdd(A_Now, -120, "Seconds"), Path . Suffix, "M")
		}
		ReapFn.Call(Path, 60000)
		Unexpected := ""
		for Label, Suffix in Cases {
			if Label = "dead" {
				AssertFalse(FileExist(Path . Suffix), "the aged, dead owner's recognized stage must be retired")
			} else if !FileExist(Path . Suffix) {
				Unexpected .= Label . " "
			} else {
				AssertEqual(Label, FileRead(Path . Suffix, "UTF-8-RAW"))
			}
		}
		AssertEqual("", Unexpected, "cleanup must retain live, recent and unrecognized staging files")
	} finally _KLRDC_Cleanup()
}
_ATO_KeyloggerReap(Path, MaxAgeMs) {
	; The full keylogger installs hooks. Execute its actual helper in isolation.
	Body := _DriverFuncBody("_KL_ReapStaleTemps")
	AssertTrue(Body != "")
	Script := _KLRDC_Root() . "isolated_reaper.ahk"
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . "#Requires AutoHotkey v2.0`n"
		. '#Include ' . A_ScriptDir . '\..\adapters\file_system.ahk' . "`n"
		. Body . "`n_KL_ReapStaleTemps(A_Args[1], Integer(A_Args[2]))`nExitApp(0)`n") != 0)
	ExitCode := -1
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Script, Path, String(MaxAgeMs)],
		(Code, *) => ExitCode := Code)
	try {
		AssertTrue(Handle.start())
		Started := A_TickCount
		while ExitCode = -1 && TickElapsed(Started) < 5000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(0, ExitCode, "the isolated production reaper must finish")
	} finally AssertTrue(Handle.terminate())
}
for Spec in [["keylogger", _ATO_KeyloggerReap], ["prefetch", _KLPF_ReapStaleTemps], ["toml", _TOML_ReapStaleTemps]]
	Test("Atomic stage cleanup: " . Spec[1] . " requires a dead owner (atomic-temp-owner)",
		_KLRDC_CheckTeardown.Bind(_ATO_ReapOwnedDebris.Bind(Spec[2])))
