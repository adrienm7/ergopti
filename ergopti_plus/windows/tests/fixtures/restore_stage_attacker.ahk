; tests/fixtures/restore_stage_attacker.ahk

; ==============================================================================
; MODULE: Restore Stage Attacker Fixture
; DESCRIPTION:
; A separate same-user process trying to substitute a restore stage through the
; pathnames anyone can reach, as test_config_restore_custody.ahk launches it.
; "once" tries each attack and writes one "name=result" line per attempt, where
; result is 1 when Windows allowed it. "loop" retries until the stop file
; appears, then writes how many attempts ran. Only the fixture's own temporary
; paths are touched.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

_Move(From, To, Flags := 0) {
	return DllCall("kernel32\MoveFileExW", "Str", From, "Str", To, "UInt", Flags, "Int") ? 1 : 0
}

_OpenForWriting(Path) {
	static GENERIC_WRITE := 0x40000000, SHARE_ALL := 7, OPEN_EXISTING := 3
	Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", GENERIC_WRITE, "UInt", SHARE_ALL,
		"Ptr", 0, "UInt", OPEN_EXISTING, "UInt", 0, "Ptr", 0, "Ptr")
	if Handle == -1
		return 0
	DllCall("kernel32\CloseHandle", "Ptr", Handle)
	return 1
}

_Once(Stage, Folder, Parent, Foreign, Receipt) {
	static MOVEFILE_REPLACE_EXISTING := 1
	; The proof that a refusal below comes from the stage, not from a broken child.
	Lines := "write_sibling=" . _OpenSibling(Folder . "\attacker-sibling.txt") . "`n"
	Lines .= "rename_stage=" . _Move(Stage, Stage . ".moved") . "`n"
	Lines .= "replace_stage=" . _Move(Foreign, Stage, MOVEFILE_REPLACE_EXISTING) . "`n"
	Lines .= "write_stage=" . _OpenForWriting(Stage) . "`n"
	Lines .= "delete_stage=" . (DllCall("kernel32\DeleteFileW", "Str", Stage, "Int") ? 1 : 0) . "`n"
	Lines .= "rename_folder=" . _Move(Folder, Folder . ".moved") . "`n"
	Lines .= "rename_parent=" . _Move(Parent, Parent . ".moved") . "`n"
	FileAppend(Lines, Receipt, "UTF-8-RAW")
}

_OpenSibling(Path) {
	FileAppend("sibling", Path, "UTF-8-RAW")
	return FileExist(Path) ? 1 : 0
}

_Loop(Stage, Foreign, Stop, Receipt) {
	static MOVEFILE_REPLACE_EXISTING := 1
	Attempts := 0
	Moved := 0
	while !FileExist(Stop) {
		Attempts += 1
		; A success can only be the free name between two restores: the test
		; asserts the destination never receives these bytes.
		if DllCall("kernel32\CopyFileW", "Str", Foreign, "Str", Stage, "Int", false, "Int")
			Moved += 1
		_Move(Stage, Stage . ".moved", MOVEFILE_REPLACE_EXISTING)
		DllCall("kernel32\DeleteFileW", "Str", Stage . ".moved", "Int")
	}
	FileAppend("attempts=" . Attempts . "`nplanted=" . Moved . "`n", Receipt, "UTF-8-RAW")
}

if A_Args.Length < 1
	ExitApp(2)
if A_Args[1] == "once"
	_Once(A_Args[2], A_Args[3], A_Args[4], A_Args[5], A_Args[6])
else
	_Loop(A_Args[2], A_Args[3], A_Args[4], A_Args[5])
ExitApp(0)
