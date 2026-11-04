; tests/unit/platform/remap/tap_hold/test_tap_hold_migration.ahk

; ==============================================================================
; MODULE: Versioned tap_hold.toml (Windows)
; DESCRIPTION:
; Replays the shared migration corpus on the Windows interpreter, then pins the
; driver side as the Linux suite does: the boot publishes the migrated file once
; after a byte-exact backup, a current file is never rewritten, the user's own
; delays survive, a newer or unreadable file is left alone and refused to every
; writer, the loader reads an unmigrated file as the migration leaves it, and the
; boot migrates before the loader reads the file.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_THM_Defaults() {
	global _SharedDir
	return _SharedDir . "\tap_hold\defaults.toml"
}

; Runs Body(Path) on a tap_hold.toml in a throwaway folder, then removes the folder.
; @param Text {String} Initial bytes; "" leaves the file absent.
_THM_WithFile(Text, Body) {
	static Sequence := 0
	Sequence += 1
	Dir := A_Temp . "\ergopti_tap_hold_migration_" . DllCall("GetCurrentProcessId") . "_" . Sequence
	DirCreate(Dir)
	Path := Dir . "\tap_hold.toml"
	if (Text != "")
		AssertEqual(1, FSWriteDurable(Path, Text))
	try Body.Call(Path)
	finally {
		_TOML_InvalidateParseCache(Path)
		DirDelete(Dir, true)
	}
}

_THM_ReadFile(Path) => FSReadUtf8Exact(Path)

_THM_OldFile() {
	return '[tap_hold]`ninherit_defaults = false`n'
		. '[tap_hold.keys.caps_lock]`ntap_action = "enter"`nhold_modifier = "ctrl"`ntime_activation_seconds = 0.35`n'
		. '[tap_hold.keys.left_ctrl]`ntime_activation_seconds = 0.45`n'
}





; ==================================
; ==================================
; ======= 2/ Shared registry =======
; ==================================
; ==================================

_THM_ShippedRegistryParses() {
	Registry := TapHoldMigrationRegistry()
	AssertEqual(0, Registry["unstamped"])
	AssertTrue(Registry["current"] >= 1)
	AssertEqual(Registry["current"], Registry["steps"].Length)
}
Test("tap-hold migration: the shipped registry reads as a gap-free chain (tap-hold-versioned-file)", _THM_ShippedRegistryParses)

_THM_RefusesABrokenRegistry() {
	Good := '[registry]`ncurrent_version = 1`nunstamped_version = 0`n[steps.v0_to_v1]`nfrom = 0`nto = 1`nops = [`n{ op = "delete", section = "a", key = "b" },`n]`n'
	AssertEqual(1, TapHoldMigrationParseRegistry(TOML_ParseDocument(Good))["current"], "the control registry is accepted")
	for Broken in [
		'[registry]`ncurrent_version = 0`nunstamped_version = 0`n',
		'[registry]`ncurrent_version = 1`nunstamped_version = 0`n',
		'[registry]`ncurrent_version = 1`nunstamped_version = 0`n[steps.v0_to_v2]`nfrom = 0`nto = 2`nops = []`n',
		StrReplace(Good, 'op = "delete"', 'op = "explode"'),
		StrReplace(Good, 'key = "b"', 'key = "b.c"'),
	] {
		Refused := false
		try TapHoldMigrationParseRegistry(TOML_ParseDocument(Broken))
		catch
			Refused := true
		AssertTrue(Refused, "refused: " . Broken)
	}
}
Test("tap-hold migration: a registry defect throws instead of guessing a version", _THM_RefusesABrokenRegistry)

_THM_ReplaysTheCorpus() {
	global _SharedDir
	Corpus := _SharedDir . "\tests\corpus\tap_hold_migrations"
	Cases := TOML_ParseDocument(FSReadUtf8Exact(Corpus . "\cases.toml"))["corpus"]["cases"]
	AssertTrue(Cases.Length > 0)
	Registry := TapHoldMigrationRegistry()
	for Name in Cases {
		Dir := Corpus . "\" . Name
		Meta := TOML_ParseDocument(FSReadUtf8Exact(Dir . "\case.toml"))["case"]
		Listed := false
		for Driver in Meta["drivers"]
			Listed := Listed || (Driver == "windows")
		AssertTrue(Listed, Name . " names the Windows driver")
		Input := FSReadUtf8Exact(Dir . "\input.toml")
		Plan := TapHoldMigrationPlanSource(Input, Registry, _THM_Defaults())
		AssertEqual(Meta["outcome"], Plan["outcome"], Name . ": outcome")
		if (Meta["outcome"] != "migrated") {
			AssertFalse(Plan.Has("candidate"), Name . ": nothing to write")
			continue
		}
		AssertEqual(Meta["from_version"], Plan["version"], Name . ": from_version")
		Expected := TOML_ParseDocument(FSReadUtf8Exact(Dir . "\expected.toml"))
		Migrated := TOML_ParseDocument(Plan["candidate"])
		AssertTrue(TOML_SameValue(Expected, Migrated), Name . ": the migrated document")
		; The view the loader reads and the bytes the boot writes are the same edit.
		View := TOML_ParseDocument(Input)
		TapHoldMigrationApply(View, Registry, _THM_Defaults())
		AssertTrue(TOML_SameValue(Expected, View), Name . ": the document view")
		AssertEqual("current", TapHoldMigrationPlanSource(Plan["candidate"], Registry, _THM_Defaults())["outcome"], Name . ": replay")
	}
}
Test("tap-hold migration: the Windows interpreter replays the shared corpus (tap-hold-versioned-file)", _THM_ReplaysTheCorpus)





; ======================================
; ======================================
; ======= 3/ The file at boot ==========
; ======================================
; ======================================

_THM_MigratesOnceWithBackup() {
	_THM_WithFile(_THM_OldFile(), (Path) => _THM_MigratesOnceBody(Path))
}
_THM_MigratesOnceBody(Path) {
	Result := TapHoldMigrateFile(Path, _THM_Defaults(), "20261030-000000")
	AssertEqual("migrated", Result["status"])
	AssertEqual(0, Result["from"])
	AssertTrue(FSUtf8ExactMatches(Result["backup"], _THM_OldFile()), "the backup holds the exact old bytes")
	Text := _THM_ReadFile(Path)
	AssertContains(Text, "schema_version = 1", "stamped")
	Assert(!InStr(Text, "explicit_delays"), "no marker is written")
	Assert(!InStr(Text, "0.35"), "the shipped delay of Caps Lock went")
	Loaded := LoadTapHoldToml(Path, _THM_Defaults())
	AssertFalse(TapHoldHasOwnDuration(Loaded, "caps_lock"), "the key follows the global delay")
	AssertEqual(0.45, TapHoldDuration(Loaded, "left_ctrl"), "the user's own delay survives")
	AssertEqual("current", TapHoldMigrateFile(Path, _THM_Defaults())["status"])
	AssertTrue(FSUtf8ExactMatches(Path, Text), "a second boot changes nothing")
}
Test("tap-hold migration: an old file migrates once, copied delays go, the user's stay, a backup holds the bytes (tap-hold-versioned-file)",
	_THM_MigratesOnceWithBackup)

_THM_KeepsHandFormatting() {
	Hand := "# My tap-hold setup: keep this comment`r`n"
		. "[tap_hold]   # master switch`r`n"
		. "enabled   =   true`r`n"
		. "explicit_delays = false`r`n"
		. "`r`n"
		. "# Caps Lock is my Ctrl`r`n"
		. "[tap_hold.keys.caps_lock]`r`n"
		. "tap_action = 'enter'   # single quotes stay`r`n"
		. "time_activation_seconds = 0.35   # shipped copy`r`n"
		. 'hold_modifier = "ctrl"`r`n'
		. "`r`n"
		. "[tap_hold.keys.tab]`r`n"
		. "time_activation_seconds = 0.2`r`n"
		. "`r`n"
		. "[tap_hold.keys.left_ctrl]`r`n"
		. "time_activation_seconds   =   0.45 # my own`r`n"
	_THM_WithFile(Hand, (Path) => _THM_KeepsHandFormattingBody(Path, Hand))
}
_THM_KeepsHandFormattingBody(Path, Hand) {
	Result := TapHoldMigrateFile(Path, _THM_Defaults(), "20261030-000001")
	AssertEqual("migrated", Result["status"])
	AssertTrue(FSUtf8ExactMatches(Result["backup"], Hand))
	Text := _THM_ReadFile(Path)
	for Kept in ["# My tap-hold setup: keep this comment`r`n", "[tap_hold]   # master switch`r`n",
			"enabled   =   true`r`n", "# Caps Lock is my Ctrl`r`n",
			"tap_action = 'enter'   # single quotes stay`r`n", 'hold_modifier = "ctrl"`r`n',
			"time_activation_seconds   =   0.45 # my own`r`n"]
		AssertContains(Text, Kept, "every byte outside the migrated lines survives")
	for Gone in ["explicit_delays", "0.35", "[tap_hold.keys.tab]", "0.2`r`n"]
		Assert(!InStr(Text, Gone), "removed: " . Gone)
	AssertContains(Text, "schema_version = 1")
}
Test("tap-hold migration: a commented, hand-formatted file is edited in place (tap-hold-byte-preserving)", _THM_KeepsHandFormatting)

_THM_DottedAndInlineSpellings() {
	for Source in [
		'tap_hold.keys.caps_lock.time_activation_seconds = 0.35`ntap_hold.keys.left_ctrl.time_activation_seconds = 0.45`n',
		'[tap_hold]`nkeys = { caps_lock = { time_activation_seconds = 0.35, enabled = false }, left_ctrl = { time_activation_seconds = 0.45 } }`n',
		'["tap_hold"."keys"."caps_lock"]`ntime_activation_seconds = 0.35`nfuture_note = "001"`n["tap_hold"."keys"."left_ctrl"]`ntime_activation_seconds = 0.45`n',
	] {
		Plan := TapHoldMigrationPlanSource(Source, TapHoldMigrationRegistry(), _THM_Defaults())
		AssertEqual("migrated", Plan["outcome"], Source)
		Document := TOML_ParseDocument(Plan["candidate"])
		AssertEqual(1, Document["_meta"]["schema_version"])
		AssertEqual(0.45, Document["tap_hold"]["keys"]["left_ctrl"]["time_activation_seconds"])
		Caps := Document["tap_hold"]["keys"].Get("caps_lock", Map())
		AssertFalse(Caps.Has("time_activation_seconds"), "the copied delay went from " . Source)
	}
}
Test("tap-hold migration: dotted, inline and quoted spellings are migrated where they are", _THM_DottedAndInlineSpellings)

_THM_FlaggedFileKeepsEveryDelay() {
	Flagged := StrReplace(_THM_OldFile(), "[tap_hold]`n", "[tap_hold]`nexplicit_delays = true`n")
	_THM_WithFile(Flagged, (Path) => _THM_FlaggedBody(Path))
}
_THM_FlaggedBody(Path) {
	AssertEqual("migrated", TapHoldMigrateFile(Path, _THM_Defaults(), "20261030-000002")["status"])
	Assert(!InStr(_THM_ReadFile(Path), "explicit_delays"), "the marker is not kept")
	AssertEqual(0.35, TapHoldDuration(LoadTapHoldToml(Path, _THM_Defaults()), "caps_lock"),
		"a delay of a flagged file is the user's own")
}
Test("tap-hold migration: an old file with the marker keeps every delay and loses the marker", _THM_FlaggedFileKeepsEveryDelay)

_THM_StampedDelayIsTheUsers() {
	_THM_WithFile('[_meta]`nschema_version = 1`n[tap_hold]`ninherit_defaults = false`n'
		. '[tap_hold.keys.caps_lock]`ntime_activation_seconds = 0.35`n', (Path) => _THM_StampedBody(Path))
}
_THM_StampedBody(Path) {
	Before := _THM_ReadFile(Path)
	AssertEqual("current", TapHoldMigrateFile(Path, _THM_Defaults())["status"])
	AssertTrue(FSUtf8ExactMatches(Path, Before), "a current file is never rewritten")
	AssertEqual(0.35, TapHoldDuration(LoadTapHoldToml(Path, _THM_Defaults()), "caps_lock"),
		"a delay equal to a shipped one in a stamped file is the user's")
}
Test("tap-hold migration: in a stamped file a once-shipped delay is the user's and nothing is rewritten", _THM_StampedDelayIsTheUsers)

_THM_AbsentStaysAbsent() {
	_THM_WithFile("", (Path) => _THM_AbsentBody(Path))
}
_THM_AbsentBody(Path) {
	AssertEqual("absent", TapHoldMigrateFile(Path, _THM_Defaults())["status"])
	Assert(!FileExist(Path), "reading an absent file creates nothing")
}
Test("tap-hold migration: an absent file stays absent", _THM_AbsentStaysAbsent)

_THM_RefusesWhatItCannotVersion() {
	for Row in [["newer", '[_meta]`nschema_version = 2`n[tap_hold.keys.caps_lock]`ntime_activation_seconds = 0.35`n'],
			["invalid", '[_meta]`nschema_version = "1"`n'],
			["invalid", '_meta = 3`n'],
			["failed", "[tap_hold`n"]] {
		_THM_WithFile(Row[2], _THM_RefusesBody.Bind(, Row[1], Row[2]))
	}
}
_THM_RefusesBody(Path, Status, Text) {
	AssertEqual(Status, TapHoldMigrateFile(Path, _THM_Defaults())["status"], Text)
	AssertTrue(FSUtf8ExactMatches(Path, Text), "untouched: " . Text)
	Assert(TOML_WriteRefusal(Path) != "", "the session refuses every later write: " . Text)
	Assert(TapHoldMigrationWriteRefusal(Path) != "", "the whole-file rewrite is refused: " . Text)
}
Test("tap-hold migration: a newer, invalid or malformed file is left untouched and refused to the writers", _THM_RefusesWhatItCannotVersion)

_THM_RefusesWithoutABootToo() {
	_THM_WithFile('[_meta]`nschema_version = 2`n', (Path) => _THM_RefusesWithoutABootBody(Path))
}
_THM_RefusesWithoutABootBody(Path) {
	Assert(InStr(TapHoldMigrationWriteRefusal(Path), "newer"), "a file a newer build saved after this boot is still refused")
	Refused := false
	try TapHoldMigrateSource(FSReadUtf8Exact(Path), _THM_Defaults())
	catch
		Refused := true
	AssertTrue(Refused, "no writer starts from it")
}
Test("tap-hold migration: a file that became newer after the boot still refuses the writers", _THM_RefusesWithoutABootToo)

_THM_BackupFailureStopsTheMigration() {
	_THM_WithFile(_THM_OldFile(), (Path) => _THM_BackupFailureBody(Path))
}
_THM_BackupFailureBody(Path) {
	Result := TapHoldMigrateFile(Path, _THM_Defaults(), "20261030-000003", (BackupPath, Content) => false)
	AssertEqual("failed", Result["status"])
	AssertTrue(FSUtf8ExactMatches(Path, _THM_OldFile()), "no backup, no publication")
}
Test("tap-hold migration: a backup that cannot be made stops the publication", _THM_BackupFailureStopsTheMigration)

_THM_LoaderReadsAnUnmigratedFile() {
	_THM_WithFile(_THM_OldFile(), (Path) => _THM_LoaderReadsBody(Path))
}
_THM_LoaderReadsBody(Path) {
	Loaded := LoadTapHoldToml(Path, _THM_Defaults())
	AssertFalse(TapHoldHasOwnDuration(Loaded, "caps_lock"))
	AssertEqual(0.45, TapHoldDuration(Loaded, "left_ctrl"))
	AssertTrue(FSUtf8ExactMatches(Path, _THM_OldFile()), "reading never writes")
	AssertFalse(Loaded.Has("explicit_delays"), "the marker is not state any more")
}
Test("tap-hold migration: the loader reads a file the boot has not migrated as the migration leaves it", _THM_LoaderReadsAnUnmigratedFile)

_THM_LoaderReadsANewerFileAsItIs() {
	_THM_WithFile('[_meta]`nschema_version = 2`n[tap_hold]`ninherit_defaults = false`n[tap_hold.keys.caps_lock]`ntime_activation_seconds = 0.35`n',
		(Path) => AssertEqual(0.35, TapHoldDuration(LoadTapHoldToml(Path, _THM_Defaults()), "caps_lock")))
}
Test("tap-hold migration: a newer file is read as it is", _THM_LoaderReadsANewerFileAsItIs)

_THM_BootMigratesBeforeTheLoader() {
	Source := FSReadUtf8Exact(A_ScriptDir . "\..\ErgoptiPlus.ahk")
	Migrate := InStr(Source, "`nTapHoldMigrateFile(")
	Load := InStr(Source, "`nglobal TapHold := LoadTapHoldToml(")
	AssertTrue(Migrate > 0 && Load > 0 && Migrate < Load, "the boot migrates tap_hold.toml before the loader reads it")
}
Test("tap-hold migration: the boot migrates before the loader reads the file (tap-hold-migrate-boot-order)", _THM_BootMigratesBeforeTheLoader)
