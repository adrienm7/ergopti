; tests/meta/test_ahk_os_purity_inputs.ahk

; ==============================================================================
; MODULE: OS Purity Scanner Input Tests
; DESCRIPTION: Incomplete source reads must never certify a reduced OS-call count.
; ==============================================================================

#Requires AutoHotkey v2.0

_AOPRI_ReadFailure(Count, Category, LockedFile := false) {
	Root := A_Temp . "\ergopti_purity_" . A_ScriptHwnd . "_" . A_TickCount
	AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Root, "Ptr", 0, "Int"),
		"the fixture must exclusively acquire its temporary directory")
	Handle := -1
	try {
		Readable := Root . "\readable.ahk"
		Unavailable := Root . "\unavailable.ahk"
		FileAppend('DllCall("fixture")' . "`nSetTimer(Fixture, 1)`n", Readable, "UTF-8")
		AssertEqual(1, Count.Call([Readable])[Category], "the control must count actual fixture source")
		if LockedFile {
			FileCopy(Readable, Unavailable)
			Handle := DllCall("kernel32\CreateFileW", "Str", Unavailable, "UInt", 0x80000000,
				"UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
			AssertTrue(Handle != -1, "the fixture must acquire the native exclusive lock")
		}
		Failure := 0
		try Count.Call([Readable, Unavailable])
		catch OSError as Err
			Failure := Err
		AssertTrue(Failure is OSError,
			"an incomplete source scan must surface the read error instead of returning partial counts")
		if Handle != -1 {
			DllCall("kernel32\CloseHandle", "Ptr", Handle)
			Handle := -1
		} else FileCopy(Readable, Unavailable)
		AssertEqual(2, Count.Call([Readable, Unavailable])[Category],
			"a later readable scan must count both files")
	} finally {
		if Handle != -1
			DllCall("kernel32\CloseHandle", "Ptr", Handle)
		DirDelete(Root, true)
	}
}
Test("OS purity inputs: missing source rejects direct-call counts (os-purity-input-failure)",
	_AOPRI_ReadFailure.Bind(_AOPR_CountFiles, "DllCall"))
Test("OS purity inputs: locked source rejects direct-call counts (os-purity-input-failure)",
	_AOPRI_ReadFailure.Bind(_AOPR_CountFiles, "DllCall", true))
Test("OS purity inputs: missing source rejects platform-family counts (os-purity-input-failure)",
	_AOPRI_ReadFailure.Bind(_AOPR_CountFamilies, "Timer"))
Test("OS purity inputs: locked source rejects platform-family counts (os-purity-input-failure)",
	_AOPRI_ReadFailure.Bind(_AOPR_CountFamilies, "Timer", true))

_AOPRI_MissingTree() {
	Missing := "__purity_missing_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(_AOPR_DriverRoot() . "\" . Missing), "the missing-tree fixture must be absent")
	AssertTrue(_AOPR_FilesIn(["platform"]).Length > 0, "the other requested tree must contain source")
	AssertThrows(() => _AOPR_FilesIn(["platform", Missing]),
		"one readable tree must not hide another requested tree's absence")
}
Test("OS purity inputs: reject a missing requested tree (os-purity-tree-failure)", _AOPRI_MissingTree)
