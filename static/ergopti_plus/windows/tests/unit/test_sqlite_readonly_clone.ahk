; tests/unit/test_sqlite_readonly_clone.ahk

; ==============================================================================
; MODULE: Readonly SQLite Clone Tests
; DESCRIPTION:
; Native read failures and small-tail allocations guard private snapshot copies.
; Fixtures use real SQLite handles and owned temporary files.
; ==============================================================================

#Requires AutoHotkey v2.0

_SQLRC_WithSource(Scenario) {
	_KLRDC_Reset()
	Writer := 0
	Source := 0
	try {
		Path := _KLRDC_Root() . "source.sqlite"
		Writer := SQLite_Open(Path)
		AssertTrue(Writer != 0)
		AssertTrue(SQLite_Exec(Writer, "CREATE TABLE clone_probe(id INTEGER PRIMARY KEY, value TEXT, payload BLOB);"
			. "INSERT INTO clone_probe VALUES(1,'original',zeroblob(8388608));"))
		Source := SQLite_Open(Path, SQLiteConst.OPEN_RO)
		AssertTrue(Source != 0)
		AssertEqual(1, DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly", "Ptr", Source, "AStr", "main", "Int"))
		Scenario.Call(Source, Writer)
	} finally {
		SQLite_Close(Source)
		SQLite_Close(Writer)
		_KLRDC_Cleanup()
	}
}

_SQLRC_MemoryUsed() {
	return DllCall(SQLiteConst.DLL . "\sqlite3_memory_used", "Int64")
}

_SQLRC_WarmSource(Source) {
	Control := SQLite_CloneMemory(Source)
	AssertTrue(Control != 0, "the control must exercise successful native ownership transfer")
	SQLite_Close(Control)
}

_SQLRC_ReadFailure(Source, Writer) {
	Path := _KLRDC_Root() . "source.sqlite"
	PageSize := SQLite_Query(Source, "PRAGMA page_size;")[1]["page_size"]
	Pages := SQLite_Query(Source, "PRAGMA page_count;")[1]["page_count"]
	AssertTrue(Pages > 2, "the owned fixture must contain uncached overflow pages")
	ProbeSource := SQLite_Open(Path, SQLiteConst.OPEN_RO)
	AssertTrue(ProbeSource != 0)
	Baseline := SQLite_Open(":memory:")
	Candidate := 0
	File := FileOpen(Path, "rw")
	Overlap := Buffer(32, 0)
	NumPut("UInt", (Pages - 1) * PageSize, Overlap, 16)
	Locked := false
	try {
		AssertTrue(Baseline != 0)
		; A byte-range lock makes ReadFile fail without corrupting the fixture.
		Locked := DllCall("Kernel32\LockFileEx", "Ptr", File.Handle, "UInt", 3,
			"UInt", 0, "UInt", PageSize, "UInt", 0, "Ptr", Overlap, "Int")
		AssertTrue(Locked, "the last source page must be unreadable through other handles")
		AssertFalse(SQLite_BackupInto(Baseline, Source), "the original native backup must reject a source read error")
		Candidate := SQLite_CloneMemory(ProbeSource)
		AssertEqual(0, Candidate, "a clone must not replace unreadable source pages with zero-filled successful data")
	} finally {
		SQLite_Close(Candidate)
		SQLite_Close(Baseline)
		SQLite_Close(ProbeSource)
		try {
			if Locked
				AssertTrue(DllCall("Kernel32\UnlockFileEx", "Ptr", File.Handle, "UInt", 0,
					"UInt", PageSize, "UInt", 0, "Ptr", Overlap, "Int"))
		} finally File.Close()
	}
	; A fresh source after unlocking proves that rejection was caused by the lock.
	ProbeSource := SQLite_Open(Path, SQLiteConst.OPEN_RO)
	Candidate := 0
	try {
		AssertTrue(ProbeSource != 0)
		Candidate := SQLite_CloneMemory(ProbeSource)
		AssertTrue(Candidate != 0, "the same file must become cloneable after unlocking")
		AssertEqual("ok", SQLite_Query(Candidate, "PRAGMA integrity_check;")[1]["integrity_check"])
		AssertEqual(8388608, SQLite_Query(Candidate, "SELECT length(payload) AS n FROM clone_probe;")[1]["n"])
	} finally {
		SQLite_Close(Candidate)
		SQLite_Close(ProbeSource)
	}
}
Test("SQLite readonly clone: unreadable pages reject the complete candidate (sqlite-readonly-clone-read-failure)",
	_KLRDC_CheckTeardown.Bind(_SQLRC_WithSource.Bind(_SQLRC_ReadFailure)))

_SQLRC_GrowthAllocations(Source, Writer) {
	_SQLRC_WarmSource(Source)
	AssertTrue(_SQLRC_MemoryUsed() > 0, "native allocation accounting must be active")
	Allocations := Map()
	ImageBytes := Map()
	for Mode in ["legacy", "candidate"] {
		BeforeBytes := _SQLRC_MemoryUsed()
		Db := Mode = "candidate" ? SQLite_CloneMemory(Source) : SQLite_Open(":memory:")
		AssertTrue(Db != 0)
		try {
			if Mode = "legacy"
				AssertTrue(SQLite_BackupInto(Db, Source))
			AssertTrue(SQLite_Exec(Db, "INSERT INTO clone_probe VALUES(2,'grown',zeroblob(1048576));"))
			AssertEqual(1048576, SQLite_Query(Db, "SELECT length(payload) AS n FROM clone_probe WHERE id=2;")[1]["n"])
			ImageBytes[Mode] := SQLite_Query(Db, "PRAGMA page_count;")[1]["page_count"]
				* SQLite_Query(Db, "PRAGMA page_size;")[1]["page_size"]
			Allocations[Mode] := _SQLRC_MemoryUsed() - BeforeBytes
			AssertTrue(Allocations[Mode] > 0)
		} finally SQLite_Close(Db)
	}
	AssertEqual(ImageBytes["legacy"], ImageBytes["candidate"], "both growth paths must build the same image size")
	AssertTrue(Allocations["candidate"] <= Allocations["legacy"],
		"a small tail must not retain more native memory than the established memory-pager clone; legacy="
		. Allocations["legacy"] . " candidate=" . Allocations["candidate"])
	AssertEqual(1, SQLite_Query(Source, "SELECT COUNT(*) AS n FROM clone_probe;")[1]["n"],
		"both grown candidates must remain private")
}
Test("SQLite readonly clone: small growth preserves the native allocation budget (sqlite-readonly-clone-growth-memory)",
	_KLRDC_CheckTeardown.Bind(_SQLRC_WithSource.Bind(_SQLRC_GrowthAllocations)))
