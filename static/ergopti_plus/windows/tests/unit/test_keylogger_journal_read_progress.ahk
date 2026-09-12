; tests/unit/test_keylogger_journal_read_progress.ahk

; ==============================================================================
; MODULE: Journal Read Progress Tests
; DESCRIPTION: A refused ReadLine must fail before spinning until a lock disappears.
; ==============================================================================

#Requires AutoHotkey v2.0

_KJRP_RefusedReadDoesNotSpin(LockedOffset) {
	Path := _FSWL_Path()
	Probe := Map("file", 0, "locked", false, "page_size", 1, "overlap", Buffer(32, 0))
	Release := _KLRCC_ReleaseLock.Bind(Probe)
	PreviousCritical := Critical("Off")
	try {
		Padding := ""
		if LockedOffset {
			Loop 8192
				Padding .= "x"
			NumPut("UInt", LockedOffset, Probe["overlap"], 16)
		}
		FileAppend('{"type":"typing","_event_id":1,"text":"' . Padding . '"}' . "`n", Path, "UTF-8-RAW")
		Before := KLR_LedgerSnapshot(Path)
		Probe["file"] := FileOpen(Path, "r")
		Probe["locked"] := DllCall("Kernel32\LockFileEx", "Ptr", Probe["file"].Handle,
			"UInt", 3, "UInt", 0, "UInt", 1, "UInt", 0, "Ptr", Probe["overlap"], "Int")
		AssertTrue(Probe["locked"])
		; Bound the broken implementation: it spins until this native lock ends.
		SetTimer(Release, -500)
		Read := _KL_JournalReadLines(Path, 0, 1, KL_JsonDecode)
		AssertFalse(Read["ok"], "a refused read must fail rather than spin until it can return success")
		AssertEqual(0, Read["offset"])
		AssertEqual(0, Read["entries"].Length)
		AssertFalse(Read["eof"], "read refusal must not authorize journal retirement")
		SetTimer(Release, 0)
		Release.Call()
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
		Read := _KL_JournalReadLines(Path, 0, 10, KL_JsonDecode)
		AssertTrue(Read["ok"])
		AssertTrue(Read["eof"])
		AssertEqual(1, Read["entries"].Length)
		AssertEqual(1, Read["entries"][1]["_event_id"])
	} finally {
		SetTimer(Release, 0)
		Release.Call()
		Critical(PreviousCritical)
		if FileExist(Path)
			FileDelete(Path)
	}
}
for LockedOffset in [0, 4096]
	Test("keylogger: native journal read refusal offset=" . LockedOffset . " preserves progress (journal-read-progress)",
		_KJRP_RefusedReadDoesNotSpin.Bind(LockedOffset))
