; tests/unit/updater/engine/test_config_restore_custody.ahk

; ==============================================================================
; MODULE: Configuration Restore Custody Tests
; DESCRIPTION:
; Restore used to verify one stage by pathname and publish whatever held that
; name a moment later, reporting success with foreign bytes live. The cases
; below run a separate same-user process against the real restore; the control
; shows the same process winning against the pathname pipeline the restore
; left, so a refusal here means the handles refused it. Every path is temporary.
; ==============================================================================

_CRC_Root(Label) {
	static Sequence := 0
	Sequence += 1
	Root := A_Temp . "\ergopti_restore_custody_" . Label . "_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . "_" . Sequence
	DirCreate(Root . "\parent\cfg")
	return Root
}

_CRC_Attacker() {
	return A_ScriptDir . "\fixtures\restore_stage_attacker.ahk"
}

_CRC_Write(Path, Text) {
	FileAppend(Text, Path, "UTF-8-RAW")
}

_CRC_Read(Path) {
	return FileRead(Path, "UTF-8-RAW")
}

_CRC_Quote(Value) {
	return '"' . Value . '"'
}

; Runs the attacker once and returns its receipt as a Map of Integers.
_CRC_Attack(Stage, Folder, Parent, Foreign, Root) {
	Receipt := Root . "\attack-receipt.txt"
	Line := _CRC_Quote(A_AhkPath) . " /force " . _CRC_Quote(_CRC_Attacker()) . " once"
	for _, Part in [Stage, Folder, Parent, Foreign, Receipt]
		Line .= " " . _CRC_Quote(Part)
	AssertEqual(0, RunWait(Line, , "Hide"), "the attacker process must run to its end")
	Results := Map()
	for _, Row in StrSplit(RTrim(_CRC_Read(Receipt), "`n"), "`n") {
		Pair := StrSplit(Row, "=")
		Results[Pair[1]] := Integer(Pair[2])
	}
	FileDelete(Receipt)
	return Results
}

; The real restore of one file, with the attacker in the held window.
_CRC_SubstitutionFails() {
	Root := _CRC_Root("attack")
	Parent := Root . "\parent", Cfg := Parent . "\cfg", Live := Cfg . "\config.toml"
	Stage := Live . ".ergopti-restore.tmp", Foreign := Root . "\foreign.toml"
	Source := Root . "\backup.toml"
	Rename := _FSHeldRename, Attack := 0
	Observe(Self, StageHandle, Folder, Name) {
		Rename.DeleteProp("Call")
		Attack := _CRC_Attack(Stage, Cfg, Parent, Foreign, Root)
		return Rename.Call(StageHandle, Folder, Name)
	}
	try {
		_CRC_Write(Source, "restored bytes`n")
		_CRC_Write(Live, "current bytes`n")
		_CRC_Write(Foreign, "foreign bytes`n")
		Rename.DefineProp("Call", {Call: Observe})
		Published := FSCopyReplaceAtomic(Source, Cfg, "config.toml", &Detail)
		AssertEqual(1, Attack["write_sibling"], "the attacker really runs with write access to the folder")
		for _, Name in ["rename_stage", "replace_stage", "write_stage", "delete_stage", "rename_folder", "rename_parent"]
			AssertEqual(0, Attack[Name], "Windows must refuse the attacker's " . Name)
		AssertTrue(Published, "the restore goes through: " . Detail)
		AssertEqual("restored bytes`n", _CRC_Read(Live))
		AssertEqual("foreign bytes`n", _CRC_Read(Foreign), "the foreign file was not consumed")
		AssertFalse(FileExist(Stage), "the stage became the destination")
	} finally {
		if Rename.HasOwnProp("Call")
			Rename.DeleteProp("Call")
		DirDelete(Root, true)
	}
}
Test("Config restore custody: a same-user process cannot substitute the held stage (restore-held-stage)", _CRC_SubstitutionFails)

; The same attacker against verify-by-name then rename-by-name, the old pipeline.
_CRC_PathnameControl() {
	Root := _CRC_Root("control")
	Parent := Root . "\parent", Cfg := Parent . "\cfg", Live := Cfg . "\config.toml"
	Stage := Live . ".ergopti-restore.tmp", Foreign := Root . "\foreign.toml"
	Source := Root . "\backup.toml"
	try {
		_CRC_Write(Source, "restored bytes`n")
		_CRC_Write(Live, "current bytes`n")
		_CRC_Write(Foreign, "foreign bytes`n")
		AssertTrue(FSCopyCreateVerified(Source, Stage))
		DirCreate(Root . "\free\folder")
		Attack := _CRC_Attack(Stage, Root . "\free\folder", Root . "\free", Foreign, Root)
		AssertEqual(1, Attack["rename_stage"], "a stage held by name moves away")
		AssertEqual(1, Attack["replace_stage"], "a foreign file takes its name")
		AssertEqual(1, Attack["write_stage"], "a stage held by name can be written")
	} finally {
		DirDelete(Root, true)
	}
}
Test("Config restore custody: the attacker wins against a stage held by name (restore-held-stage)", _CRC_PathnameControl)

; A racing process in real time, with no pause in the restore.
_CRC_ConcurrentRace() {
	Root := _CRC_Root("race")
	Cfg := Root . "\parent\cfg", Live := Cfg . "\config.toml"
	Stage := Live . ".ergopti-restore.tmp", Foreign := Root . "\foreign.toml"
	Source := Root . "\backup.toml", Stop := Root . "\stop", Receipt := Root . "\race-receipt.txt"
	try {
		_CRC_Write(Source, "restored bytes`n")
		_CRC_Write(Live, "current bytes`n")
		_CRC_Write(Foreign, "foreign bytes`n")
		Run(_CRC_Quote(A_AhkPath) . " /force " . _CRC_Quote(_CRC_Attacker()) . " loop "
			. _CRC_Quote(Stage) . " " . _CRC_Quote(Foreign) . " " . _CRC_Quote(Stop) . " " . _CRC_Quote(Receipt), , "Hide", &Attacker)
		Restored := 0
		loop 60 {
			if FSCopyReplaceAtomic(Source, Cfg, "config.toml")
				Restored += 1
			Text := _CRC_Read(Live)
			AssertTrue(Text == "restored bytes`n" || Text == "current bytes`n", "foreign bytes never become the destination")
		}
		_CRC_Write(Stop, "")
		AssertTrue(ProcessWaitClose(Attacker, 10) == 0, "the attacker stops on its stop file")
		AssertTrue(InStr(_CRC_Read(Receipt), "attempts=") == 1, "the attacker reports its attempts")
		AssertFalse(RegExMatch(_CRC_Read(Receipt), "attempts=0\b"), "the attacker really raced")
		FileAppend("# restore-race restored=" . Restored . " of 60`n", "*")
	} finally {
		if !FileExist(Stop)
			_CRC_Write(Stop, "")
		ProcessWaitClose(Attacker ?? 0, 10)
		DirDelete(Root, true)
	}
}
Test("Config restore custody: a racing process never reaches the destination (restore-held-stage)", _CRC_ConcurrentRace)

; What CopyFileW carried over must survive the move to handles.
_CRC_NativeCopyContract() {
	static FILE_ATTRIBUTE_READONLY := 1
	Root := _CRC_Root("contract")
	Cfg := Root . "\parent\cfg", Source := Root . "\backup.toml", Live := Cfg . "\nested\deep\config.toml"
	Stamp := "20240102030405"
	try {
		_CRC_Write(Source, "restored bytes`n")
		_CRC_Write(Source . ":ergopti.stream", "named stream bytes`n")
		FileSetTime(Stamp, Source, "M")
		FileSetAttrib("+RH", Source)
		AssertTrue(FSCopyReplaceAtomic(Source, Cfg, "nested/deep/config.toml", &Detail), "the copy goes through: " . Detail)
		AssertEqual("restored bytes`n", _CRC_Read(Live))
		AssertEqual("named stream bytes`n", _CRC_Read(Live . ":ergopti.stream"), "a named stream follows the file")
		AssertEqual(Stamp, FileGetTime(Live, "M"), "the write time follows the file")
		AssertTrue(InStr(FileExist(Live), "R") && InStr(FileExist(Live), "H"), "the attributes follow the file")
		FileSetAttrib("-RH", Source)
		FileSetAttrib("-RH", Live)
	} finally {
		DirDelete(Root, true)
	}
}
Test("Config restore custody: streams, attributes and write time follow the copy (restore-native-contract)", _CRC_NativeCopyContract)

; Larger than one copy block, so the read-back compares across block ends.
_CRC_MultiBlockContent() {
	Root := _CRC_Root("blocks")
	Cfg := Root . "\parent\cfg", Source := Root . "\backup.toml", Live := Cfg . "\config.toml"
	try {
		Bytes := Buffer(FS_RESTORE_COPY_BLOCK * 2 + 17)
		loop Bytes.Size
			NumPut("UChar", A_Index & 0xFF, Bytes, A_Index - 1)
		File := FileOpen(Source, "w")
		File.RawWrite(Bytes)
		File.Close()
		AssertTrue(FSCopyReplaceAtomic(Source, Cfg, "config.toml", &Detail), "the copy goes through: " . Detail)
		AssertTrue(FSSameBytes(Source, Live), "every block is published")
	} finally {
		DirDelete(Root, true)
	}
}
Test("Config restore custody: a file of several copy blocks is exact (restore-native-contract)", _CRC_MultiBlockContent)

; A junction among the segments is someone else's folder: nothing lands there.
_CRC_LinkedFolderRefused() {
	Root := _CRC_Root("junction")
	Cfg := Root . "\parent\cfg", Outside := Root . "\outside", Source := Root . "\backup.toml"
	try {
		DirCreate(Outside)
		_CRC_Write(Source, "restored bytes`n")
		AssertEqual(0, RunWait(A_ComSpec . ' /c mklink /J "' . Cfg . '\linked" "' . Outside . '"', , "Hide"), "the junction exists")
		AssertFalse(FSCopyReplaceAtomic(Source, Cfg, "linked/config.toml", &Detail), "a link in the path refuses the copy")
		AssertTrue(InStr(Detail, "link"), "the refusal says why: " . Detail)
		AssertFalse(FileExist(Outside . "\config.toml"), "nothing reaches the far side of the link")
		AssertFalse(FileExist(Outside . "\config.toml.ergopti-restore.tmp"), "no stage reaches it either")
	} finally {
		DirDelete(Root, true)
	}
}
Test("Config restore custody: a junction in the path receives nothing (restore-linked-folder)", _CRC_LinkedFolderRefused)

; A refused publication removes its own stage and leaves the live file alone.
_CRC_RefusedRenameDiscardsItsStage() {
	static GENERIC_READ := 0x80000000, FILE_SHARE_READ := 1, OPEN_EXISTING := 3
	Root := _CRC_Root("refused")
	Cfg := Root . "\parent\cfg", Live := Cfg . "\config.toml"
	Stage := Live . ".ergopti-restore.tmp", Source := Root . "\backup.toml"
	try {
		_CRC_Write(Source, "restored bytes`n")
		FileSetAttrib("+R", Source)
		_CRC_Write(Live, "current bytes`n")
		Lock := DllCall("kernel32\CreateFileW", "Str", Live, "UInt", GENERIC_READ, "UInt", FILE_SHARE_READ,
			"Ptr", 0, "UInt", OPEN_EXISTING, "UInt", 0, "Ptr", 0, "Ptr")
		AssertTrue(Lock != -1, "the live file has a handle denying delete sharing")
		try Published := FSCopyReplaceAtomic(Source, Cfg, "config.toml", &Detail)
		finally DllCall("kernel32\CloseHandle", "Ptr", Lock, "Int")
		AssertFalse(Published, "a destination that cannot be replaced refuses the copy")
		AssertTrue(InStr(Detail, "rename refused"), "the refusal says why: " . Detail)
		AssertEqual("current bytes`n", _CRC_Read(Live), "the live file is untouched")
		AssertFalse(FileExist(Stage), "the read-only stage left through its own handle")
		FileSetAttrib("-R", Source)
	} finally {
		DirDelete(Root, true)
	}
}
Test("Config restore custody: a refused rename discards the stage by handle (restore-refused-stage)", _CRC_RefusedRenameDiscardsItsStage)

; An existing file of the stage's name is foreign: refused, kept, never adopted.
_CRC_ForeignStageNameKept() {
	Root := _CRC_Root("foreign")
	Cfg := Root . "\parent\cfg", Live := Cfg . "\config.toml"
	Stage := Live . ".ergopti-restore.tmp", Source := Root . "\backup.toml"
	try {
		_CRC_Write(Source, "restored bytes`n")
		_CRC_Write(Live, "current bytes`n")
		_CRC_Write(Stage, "foreign bytes`n")
		AssertFalse(FSCopyReplaceAtomic(Source, Cfg, "config.toml", &Detail))
		AssertEqual("foreign bytes`n", _CRC_Read(Stage), "the discard goes through a handle it owns, never this name")
		AssertEqual("current bytes`n", _CRC_Read(Live))
	} finally {
		DirDelete(Root, true)
	}
}
Test("Config restore custody: a file already at the stage name stays foreign (restore-refused-stage)", _CRC_ForeignStageNameKept)

_CRC_RelativeRefused() {
	Root := _CRC_Root("relative")
	try {
		_CRC_Write(Root . "\backup.toml", "restored bytes`n")
		for _, Relative in ["..\escape.toml", "a/../b.toml", "/rooted.toml", "config.toml:stream", "dir/", ""]
			AssertFalse(FSCopyReplaceAtomic(Root . "\backup.toml", Root . "\parent\cfg", Relative), "refused: " . Relative)
		AssertFalse(FileExist(Root . "\parent\escape.toml"))
	} finally {
		DirDelete(Root, true)
	}
}
Test("Config restore custody: a relative path leaving its anchor is refused (restore-linked-folder)", _CRC_RelativeRefused)
