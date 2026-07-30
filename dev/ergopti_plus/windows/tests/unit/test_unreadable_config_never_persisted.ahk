; static/ergopti_plus/windows/tests/unit/test_unreadable_config_never_persisted.ahk

; ==============================================================================
; MODULE: Regression — an unreadable config file is never turned into an empty
;         one (unreadable-config-never-persisted)
; DESCRIPTION:
; The same mistake at two more readers, after the config.toml boot apply and
; wrap_symbols.toml were fixed for it.
;
;   L-14  ReadPersonalToml's FileRead was unguarded. A locked
;         personal_hotstrings.toml threw out of the boot loader and out of the
;         menu handlers that call it at click time — and the empty model it
;         would otherwise return is indistinguishable from "this user has no
;         personal hotstrings", which WritePersonalToml serializes directly.
;
;   L-15  CS_Read swallowed a locked config.toml into an empty Map, so CS_Load
;         kept the in-memory metrics DEFAULTS, and the first SaveFullConfig
;         wrote those over the user's real metrics settings.
;
; ROOT CAUSE ENCODED: each of these readers can produce a state byte-for-byte
; identical to what a legitimately-empty file produces, and each feeds something
; that is later written back. The distinction between "could not read" and "was
; empty" therefore has to be recorded at READ time and honoured by the writer.
; Checking at write time is useless: the transient lock has almost always
; cleared by then, so the write looks perfectly safe.
;
; SCOPE: behavioural for the personal-hotstrings pair, provoked with a real
; exclusive lock; source-level for CS_Read, whose module is outside the headless
; include graph.
; ==============================================================================

#Requires AutoHotkey v2.0

global _UCP_EXCLUSIVE_LOCK_FLAGS := "r-rwd"

; Read and clear the shared unreadable-file sentinel defensively, so a build
; without it fails these assertions by NAME rather than with "variable has not
; been assigned a value".
_UCP_IsFlagged(Path) {
	global _TomlUnreadableFiles
	return IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(Path)
}

_UCP_ClearFlag(Path) {
	global _TomlUnreadableFiles
	if (IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(Path))
		_TomlUnreadableFiles.Delete(Path)
}

; Point the personal-hotstrings reader and writer at a THROWAWAY file.
;
; Both resolve their own path through PersonalTomlPath(), which normally returns
; the user's real personal_hotstrings.toml. Driving a writer at the user's own
; data from a test is unacceptable regardless of what the guard is supposed to
; do — if the guard ever regressed, the test itself would be the thing that
; destroyed their hotstrings. Redirecting the resolver is also the only way to
; retarget them: neither function takes a path argument, so passing one is an
; arity error rather than an override.
_UCP_WithTempPersonalToml(Path, Fn) {
	global ScriptInformation, _ReadPersonalTomlCache
	if !IsSet(ScriptInformation)
		ScriptInformation := Map()
	HadKey    := ScriptInformation.Has("PersonalTomlPath")
	PrevPath  := HadKey ? ScriptInformation["PersonalTomlPath"] : ""
	PrevCache := IsSet(_ReadPersonalTomlCache) ? _ReadPersonalTomlCache : false

	ScriptInformation["PersonalTomlPath"] := Path
	_ReadPersonalTomlCache := false   ; the reader memoises; force a real read
	try {
		return Fn()
	} finally {
		if HadKey
			ScriptInformation["PersonalTomlPath"] := PrevPath
		else
			ScriptInformation.Delete("PersonalTomlPath")
		_ReadPersonalTomlCache := PrevCache
	}
}




; ==================================================================
; ==================================================================
; ======= 1/ The personal-hotstrings reader ========================
; ==================================================================
; ==================================================================

; The reader must survive the lock: it is called both from the boot loader and
; from menu click handlers, and a throw in either is user-visible damage.
_UCP_PersonalReadIsGuardedAndFlags() {
	Path := A_Temp . "\ergopti_test_personal_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend("[_meta]`ndescription = " . Chr(34) . "x" . Chr(34) . "`n", Path, "UTF-8")
	_UCP_ClearFlag(Path)

	Lock := FileOpen(Path, _UCP_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock), "the test could not take an exclusive lock — it would otherwise assert nothing")
	Threw  := ""
	Result := ""
	try {
		Result := _UCP_WithTempPersonalToml(Path, ReadPersonalToml)
	} catch as Err {
		Threw := Err.Message
	}
	Flagged := _UCP_IsFlagged(Path)
	Lock.Close()
	try FileDelete(Path)
	_UCP_ClearFlag(Path)

	Assert(Threw == "",
		"ReadPersonalToml must not throw on a locked file — it runs from the boot loader and from menu click handlers, where an exception is an aborted boot or a dead menu. Got: " . Threw)
	Assert(Result is Map, "it must still return a Map so callers' .Has checks keep working")
	Assert(Flagged,
		"a personal_hotstrings.toml that exists but cannot be read must be flagged unreadable. The empty model it returns is byte-for-byte what a user with no personal hotstrings produces, and the writer serializes exactly that shape")
}

; A readable file must still load, or the guard would be a regression dressed up
; as a fix.
_UCP_PersonalReadStillWorks() {
	Path := A_Temp . "\ergopti_test_personal_ok_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend("[_meta]`ndescription = " . Chr(34) . "mine" . Chr(34) . "`n", Path, "UTF-8")
	_UCP_ClearFlag(Path)

	Result  := _UCP_WithTempPersonalToml(Path, ReadPersonalToml)
	Flagged := _UCP_IsFlagged(Path)
	try FileDelete(Path)
	_UCP_ClearFlag(Path)

	Assert(Result is Map, "a readable file must still parse")
	Assert(!Flagged, "a readable file must not be flagged unreadable")
}

; The destructive half: the writer must refuse while the flag is up.
_UCP_PersonalWriteRefusesWhileFlagged() {
	global _TomlUnreadableFiles
	if !IsSet(_TomlUnreadableFiles)
		Assert(false, "the shared unreadable-file sentinel must exist for the writer to consult")

	Path := A_Temp . "\ergopti_test_personal_write_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend("[_meta]`ndescription = " . Chr(34) . "real content" . Chr(34) . "`n", Path, "UTF-8")
	Before := FileRead(Path, "UTF-8")

	_TomlUnreadableFiles[Path] := true
	Wrote := ""
	try {
		Wrote := _UCP_WithTempPersonalToml(Path,
			() => WritePersonalToml(Map("sections_order", [], "sections", Map())))
	} catch as Err {
		Wrote := "threw: " . Err.Message
	}
	After := FileRead(Path, "UTF-8")
	_UCP_ClearFlag(Path)
	try FileDelete(Path)

	Assert(Wrote == false,
		"WritePersonalToml must refuse while its file is flagged unreadable. What it would serialize is the EMPTY model a failed read produced, which replaces every personal hotstring the user has. Got: " . Wrote)
	Assert(After == Before,
		"the file must be untouched — refusing must mean not writing, not writing something harmless")
}




; ==================================================================
; ==================================================================
; ======= 2/ The metrics/shortcuts reader ==========================
; ==================================================================
; ==================================================================

; Source-level, not behavioural: lib/config_shortcuts.ahk is outside the
; headless include graph. The assertions below pin every part of the fix — the
; explicit catch, the ERROR, and the latch — and the latch's effect on
; persistence is covered behaviourally by
; test_config_boot_read_failure_blocks_persist.
_UCP_ShortcutsReadReportsItsFailure() {
	Body := _DriverFuncBody("CS_Read")
	Assert(Body != "", "CS_Read() must exist in the driver source")
	Assert(InStr(Body, "catch") > 0,
		"CS_Read must catch its FileRead explicitly — a bare `try` discards the OSError with no signal and no log")
	Assert(InStr(Body, "LoggerError") > 0,
		"a failed read must be logged at ERROR: it costs the user their metrics settings on the next save")
	Assert(InStr(Body, "_ConfigBootReadFailed") > 0,
		"CS_Read must latch the shared config sentinel so SaveFullConfig refuses to serialize the defaults it left behind")
}


Test("unreadable-config-never-persisted: the personal reader is guarded and flags",
	_UCP_PersonalReadIsGuardedAndFlags)
Test("unreadable-config-never-persisted: a readable personal file still loads",
	_UCP_PersonalReadStillWorks)
Test("unreadable-config-never-persisted: the personal writer refuses while flagged",
	_UCP_PersonalWriteRefusesWhileFlagged)
Test("unreadable-config-never-persisted: the shortcuts reader reports its failure",
	_UCP_ShortcutsReadReportsItsFailure)
