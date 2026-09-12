; tests/unit/test_klr_cache_stages.ahk

; ==============================================================================
; MODULE: Reader Cache Stage Ownership Tests
; DESCRIPTION: Dead producers must not leave private SQLite preparation files.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCS_ReapDeadProducer(Mode := "normal") {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Locked := -1
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a", "b"]))
		_KLRDC_BuildAsWorker()
		CachePath := KLR_CachePath(_KLRDC_Root())
		Script := _KLRDC_Root() . "stage_owner.ahk"
		Receipt := _KLRDC_Root() . "stage_owner.txt"
		FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n"
			. 'Stage := A_Args[1] . ".stage." . A_ScriptHwnd . "." . A_TickCount' . "`n"
			. 'FileCopy(A_Args[1], Stage)' . "`n"
			. 'FileAppend(Stage, A_Args[2], "UTF-8-RAW")' . "`nExitApp(0)`n", Script, "UTF-8")
		AssertEqual(0, RunWait('"' . A_AhkPath . '" /ErrorStdOut "' . Script . '" "'
			. CachePath . '" "' . Receipt . '"', , "Hide"))
		DeadStage := FileRead(Receipt, "UTF-8")
		AssertTrue(RegExMatch(DeadStage, "\.stage\.(\d+)\.\d+$", &Owner))
		AssertFalse(DllCall("User32\IsWindow", "Ptr", Integer(Owner[1]), "Int"),
			"the actual hidden producer must have terminated")
		AliveStage := CachePath . ".stage." . A_ScriptHwnd . "." . A_TickCount
		FileCopy(CachePath, AliveStage)
		Lookalike := DeadStage . ".keep"
		FileAppend("foreign fixture", Lookalike, "UTF-8-RAW")
		Overflow := CachePath . ".stage.4294967296.1"
		FileCopy(CachePath, Overflow)
		if Mode = "locked" {
			Locked := DllCall("kernel32\CreateFileW", "Str", DeadStage, "UInt", 0x80000000,
				"UInt", 1, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
			AssertTrue(Locked != -1, "the fixture must hold the native stage handle")
		} else if Mode = "unknown" {
			FileDelete(DeadStage)
			FileAppend("foreign fixture", DeadStage, "UTF-8-RAW")
		} else if Mode = "journal" {
			FileAppend("recovery fixture", DeadStage . "-journal", "UTF-8-RAW")
		} else if Mode = "legacy" {
			Legacy := SQLite_Open(DeadStage)
			try AssertTrue(SQLite_Exec(Legacy, "UPDATE klr_cache_meta SET value='3' WHERE key='format_version';"))
			finally SQLite_Close(Legacy)
		} else if Mode = "missing-cache" {
			KLR_ResetCache()
			FileDelete(CachePath)
		}
		AssertTrue(FSExists(DeadStage), "the orphan must exist before the reader opens")
		Db := _KLRDC_BuildAsWorker()
		if Mode = "locked" || Mode = "unknown" || Mode = "journal" {
			AssertTrue(FSExists(DeadStage), "unverified or in-use stages must be retained")
			if Mode = "locked" {
				DllCall("kernel32\CloseHandle", "Ptr", Locked)
				Locked := -1
			} else if Mode = "unknown" {
				AssertEqual("foreign fixture", FileRead(DeadStage, "UTF-8"))
				FileCopy(CachePath, DeadStage, true)
			} else {
				AssertEqual("recovery fixture", FileRead(DeadStage . "-journal", "UTF-8"))
				FileDelete(DeadStage . "-journal")
			}
			KLR_CacheReapStages(_KLRDC_Root(), "")
		}
		AssertFalse(FSExists(DeadStage), "opening the cache must retire a dead producer's private stage")
		AssertTrue(FSExists(AliveStage), "a live hidden producer must retain its stage")
		AssertTrue(FSExists(Overflow), "an overflowing owner must not wrap into a native HWND")
		AssertEqual("foreign fixture", FileRead(Lookalike, "UTF-8"), "unrecognized sibling files must remain untouched")
		AssertEqual(2, SQLite_Query(Db, "SELECT chars FROM agg_app_day;")[1]["chars"],
			"stage retirement must preserve the canonical projection")
	} finally {
		if Locked != -1
			DllCall("kernel32\CloseHandle", "Ptr", Locked)
		_KLRDC_Cleanup()
	}
}
Test("KLR cache stages: retire a dead producer and preserve live ownership (klr-cache-stage-ownership)",
	_KLRDC_CheckTeardown.Bind(_KLRCS_ReapDeadProducer))
Test("KLR cache stages: retain a locked stage and retry after close (klr-cache-stage-ownership)",
	_KLRDC_CheckTeardown.Bind(_KLRCS_ReapDeadProducer.Bind("locked")))
Test("KLR cache stages: retain unknown content despite a matching name (klr-cache-stage-ownership)",
	_KLRDC_CheckTeardown.Bind(_KLRCS_ReapDeadProducer.Bind("unknown")))
Test("KLR cache stages: retain SQLite recovery companions (klr-cache-stage-ownership)",
	_KLRDC_CheckTeardown.Bind(_KLRCS_ReapDeadProducer.Bind("journal")))
Test("KLR cache stages: retire the previous cache format (klr-cache-stage-ownership)",
	_KLRDC_CheckTeardown.Bind(_KLRCS_ReapDeadProducer.Bind("legacy")))
Test("KLR cache stages: clean up before a cold rebuild (klr-cache-stage-ownership)",
	_KLRDC_CheckTeardown.Bind(_KLRCS_ReapDeadProducer.Bind("missing-cache")))
