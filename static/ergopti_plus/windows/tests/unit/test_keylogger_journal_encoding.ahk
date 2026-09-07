; tests/unit/test_keylogger_journal_encoding.ahk

; ==============================================================================
; MODULE: Keylogger Journal Encoding Admission Tests
; DESCRIPTION:
; A native UTF-8 append must not publish or mutate an existing UTF-16 journal.
; The failed candidate must leave the previous singleton properties recoverable.
; ==============================================================================

#Requires AutoHotkey v2.0

_KJE_RejectUtf16() {
	Saved := Map()
	for Name in ["today_log_path", "_today_fh", "_today_fh_date"] {
		if Keylogger.HasOwnProp(Name)
			Saved[Name] := Keylogger.%Name%
	}
	Path := _FSWL_Path()
	Writer := 0
	try {
		FileAppend("user-owned é😀", Path, "UTF-16")
		Before := FileRead(Path, "RAW")
		Keylogger.today_log_path := Path
		Keylogger._today_fh := unset
		Keylogger._today_fh_date := ""
		Failure := 0
		try Writer := KL_OpenTodayFh()
		catch Any as Err
			Failure := Err
		AssertTrue(Failure is ValueError, "UTF-16 journal must be refused at encoding admission")
		AssertFalse(Keylogger.HasOwnProp("_today_fh"), "invalid handle must not be published")
		AssertEqual("", Keylogger._today_fh_date)
		After := FileRead(Path, "RAW")
		AssertEqual(Before.Size, After.Size)
		AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory",
			"Ptr", Before, "Ptr", After, "UPtr", Before.Size, "UPtr"))
	} finally {
		if IsObject(Writer)
			Writer.Close()
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

Test("keylogger: UTF-16 journal is refused before handle publication (keylogger-journal-encoding)", _KJE_RejectUtf16)
