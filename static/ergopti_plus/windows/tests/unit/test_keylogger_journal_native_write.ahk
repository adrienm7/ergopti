; tests/unit/test_keylogger_journal_native_write.ahk

; ==============================================================================
; MODULE: Keylogger Journal Native Receipt Tests
; DESCRIPTION:
; The real persistent writer must reject native write denial even when AHK's
; text buffer reports acceptance. Retry must leave each Unicode record once.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk
#Include ../../modules/keylogger/keylogger_device.ahk
#Include ../../modules/keylogger/keylogger_journal_io.ahk

_KJNW_Receipt(Existing, Locked) {
	Saved := Map()
	for Name in ["today_log_path", "_today_fh", "_today_fh_date"] {
		if Keylogger.HasOwnProp(Name)
			Saved[Name] := Keylogger.%Name%
	}
	Path := _FSWL_Path()
	Lock := _FSWL_Lock()
	LockFile := 0
	Writer := 0
	Prefix := Existing ? "prior`n" : ""
	Line := '{"text":"é😀"}'
	try {
		Keylogger.today_log_path := Path
		Keylogger._today_fh := unset
		Keylogger._today_fh_date := ""
		if Existing
			FileAppend(Prefix, Path, "UTF-8")
		Writer := KL_OpenTodayFh()
		if Locked
			LockFile := Lock.Open(Path, "a", "UTF-8-RAW")
		Accepted := _KL_JournalAppendDefault(Writer, Line)
		AssertEqual(!Locked, Accepted, "journal acceptance must be an OS write receipt")
		if Locked {
			AssertTrue(Lock.Acquired)
			AssertEqual(Prefix, FileRead(Path, "UTF-8"))
			Lock.Release()
			AssertTrue(_KL_JournalAppendDefault(Writer, Line))
		}
		AssertTrue(KL_FlushTodayFh(Writer))
		AssertTrue(KL_CloseTodayFh())
		Writer := 0
		AssertEqual(Prefix . Line . "`n", FileRead(Path, "UTF-8"))
		AssertEqual(StrPut(Prefix . Line . "`n", "UTF-8") + 2, FileGetSize(Path),
			"one UTF-8 BOM and one complete newline-owned record must remain")
	} finally {
		; Flush any legacy AHK buffer while denial still holds, before unlocking.
		if IsObject(Writer)
			Writer.Close()
		Lock.Release()
		if IsObject(LockFile)
			LockFile.Close()
		for Name in ["today_log_path", "_today_fh", "_today_fh_date"] {
			if Saved.Has(Name)
				Keylogger.%Name% := Saved[Name]
			else
				Keylogger.%Name% := unset
		}
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Existing in [false, true] {
	for Locked in [false, true]
		Test("keylogger: journal native receipt existing=" . Existing . " locked=" . Locked
			. " (keylogger-journal-native-write)", _KJNW_Receipt.Bind(Existing, Locked))
}
