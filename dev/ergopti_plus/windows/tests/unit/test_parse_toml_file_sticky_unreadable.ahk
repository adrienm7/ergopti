; tests/unit/test_parse_toml_file_sticky_unreadable.ahk

; ==============================================================================
; MODULE: Regression — ParseTomlFile must raise the STICKY unreadable sentinel
; DESCRIPTION:
; The driver has two read-failure sentinels with different lifetimes.
; _TomlUnreadableFiles is sticky and is cleared only by a successful read of the
; SAME path; _TomlReadFailures is per-parse and is deleted at the top of the
; very next parse of that path.
;
; ROOT CAUSE ENCODED:
; ParseTomlFile — the reader behind _IniCache, and therefore behind the locale,
; the magic key, the log level, the updater cadence, every metrics setting, the
; gesture assignments, both shortcut tables and every category master gate — set
; only the volatile flag, and its single call site inspected neither. The
; snapshot is taken once at boot and never refreshed, so a lock that clears
; during the next few hundred milliseconds left every one of those families at
; its compiled-in default while the file became perfectly readable again. The
; deferred SaveFullConfig then wrote those defaults over the user's real
; config.toml through a completely ordinary, successful batch write: the
; per-parse flag it would have consulted had already been cleared by an
; unrelated re-parse.
;
; Two things close it: the parser raises the sticky sentinel for an EXISTING
; file it could not read, and the boot call site latches the session flag
; SaveFullConfig honours at the one instant that fact is still knowable.
; A MISSING file must keep parsing empty and unflagged, or a fresh install can
; never save anything.
; ==============================================================================

#Requires AutoHotkey v2.0

global _PTS_EXCLUSIVE_LOCK_FLAGS := "r-rwd"

_PTS_Clear(Path) {
	global _ParseTomlCache, _TomlUnreadableFiles, _TomlReadFailures
	if _ParseTomlCache.Has(Path)
		_ParseTomlCache.Delete(Path)
	if _TomlUnreadableFiles.Has(Path)
		_TomlUnreadableFiles.Delete(Path)
	if _TomlReadFailures.Has(Path)
		_TomlReadFailures.Delete(Path)
}





; ==============================================================
; ==============================================================
; ======= 1/ The sticky sentinel ===============================
; ==============================================================
; ==============================================================

_PTS_UnreadableFileRaisesTheStickySentinel() {
	Path := A_Temp . "\ergopti_pts_config_" . A_TickCount . ".toml"
	FileAppend("[script]`r`nlocale = " . Chr(34) . "fr" . Chr(34) . "`r`n", Path, "UTF-8")
	_PTS_Clear(Path)

	Lock := FileOpen(Path, _PTS_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock), "the exclusive lock must actually be taken")
	Threw    := false
	Sections := ""
	try {
		Sections := ParseTomlFile(Path)
	} catch {
		Threw := true
	} finally {
		Lock.Close()
	}

	try {
		AssertFalse(Threw,
			"ParseTomlFile must stay non-throwing — the fuzz corpus requires it and every preference read would otherwise be able to abort startup")
		AssertEqual(0, Sections.Count,
			"an unreadable file parses to an empty Map, which is exactly why the failure has to be reported out of band")
		AssertTrue(TOML_UnreadableFile(Path),
			"ParseTomlFile must record the STICKY unreadable-file sentinel, not only the per-parse one: the per-parse flag is deleted by the very next parse of the same path, so a lock that clears between the boot snapshot and the deferred save is invisible to every writer that asks later")

		; The mirror: the sentinel must clear once the file really is readable
		; again, or one transient lock would block persistence forever. Nothing is
		; reset by hand here — the failed parse deliberately caches nothing, so
		; this call re-reads from disk and the clearing must be the parser's own.
		ParseTomlFile(Path)
		AssertFalse(TOML_UnreadableFile(Path),
			"a successful re-read of the same path must clear the sticky sentinel — it marks 'the last read of this file saw nothing', not 'this file is cursed'")
	} finally {
		_PTS_Clear(Path)
		try FileDelete(Path)
	}
}


; A file that does not exist legitimately parses empty. Flagging it would refuse
; the very first save of a fresh install.
_PTS_MissingFileIsNotFlagged() {
	Path := A_Temp . "\ergopti_pts_absent_" . A_TickCount . ".toml"
	try FileDelete(Path)
	_PTS_Clear(Path)
	try {
		Sections := ParseTomlFile(Path)
		AssertEqual(0, Sections.Count, "a missing file parses to an empty Map")
		AssertFalse(TOML_UnreadableFile(Path),
			"a MISSING file must never be flagged unreadable — the writer honours this sentinel, and flagging it would make a fresh install unable to save its first config")
	} finally {
		_PTS_Clear(Path)
	}
}





; ==============================================================
; ==============================================================
; ======= 2/ The write that follows must refuse =================
; ==============================================================
; ==============================================================

_PTS_BatchWriteRefusesWhileUnreadable() {
	Path := A_Temp . "\ergopti_pts_write_" . A_TickCount . ".toml"
	Original := "[script]`r`nlocale = " . Chr(34) . "fr" . Chr(34) . "`r`n"
	FileAppend(Original, Path, "UTF-8")
	_PTS_Clear(Path)

	Lock := FileOpen(Path, _PTS_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock), "the exclusive lock must actually be taken")
	Written := ""
	try {
		Written := TOML_BatchWrite(Path, [{ Section: "script", Key: "locale", Value: "en" }])
	} finally {
		Lock.Close()
	}

	try {
		AssertEqual(false, Written,
			"TOML_BatchWrite must refuse while the file cannot be read: it serializes ONLY what its seed parse returned and then moves the result over the original, so writing here replaces the user's whole config with the handful of keys in Updates")
		AssertEqual(Original, FileRead(Path, "UTF-8"),
			"the refused write must leave the file byte-identical — a partial rewrite is the damage this guard exists to prevent")
	} finally {
		_PTS_Clear(Path)
		try FileDelete(Path)
	}
}





; ============================================================
; ============================================================
; ======= 3/ The boot snapshot latches its own failure =======
; ============================================================
; ============================================================

; ErgoptiPlus.ahk is not loaded by the headless harness, so the wiring of the
; widest-blast-radius reader of config.toml is asserted against the source.
_PTS_BootSnapshotLatchesTheSessionSentinel() {
	Src := _DriverSourceNoComments()
	Anchor := "_IniCache := ParseTomlFile(ConfigurationFile)"
	Pos := InStr(Src, Anchor)
	Assert(Pos > 0,
		"the boot snapshot of config.toml must still be taken through ParseTomlFile — if this anchor moved, the guard below is silently guarding nothing")

	Window := SubStr(Src, Pos, 500)
	Assert(InStr(Window, "_ConfigBootReadFailed") > 0,
		"the boot snapshot must latch the session sentinel SaveFullConfig honours: it is taken once and never refreshed, yet it seeds the locale, the magic key, every category master gate, both shortcut tables, the gesture assignments and the metrics settings — all of which SaveFullConfig serialises back a few hundred milliseconds later, by which time the transient lock has usually cleared and no write-time check can tell the payload came from nothing")
}


Test("toml_helpers: an unreadable existing file raises the sticky sentinel",
	_PTS_UnreadableFileRaisesTheStickySentinel)
Test("toml_helpers: a missing file is not flagged unreadable",
	_PTS_MissingFileIsNotFlagged)
Test("toml_helpers: a batch write refuses while the file cannot be read",
	_PTS_BatchWriteRefusesWhileUnreadable)
Test("boot: the _IniCache snapshot latches its own read failure",
	_PTS_BootSnapshotLatchesTheSessionSentinel)
