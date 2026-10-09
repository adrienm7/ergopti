; tests/unit/test_taphold_unreadable_blocks_rewrite.ahk

; ==============================================================================
; MODULE: Regression — an unreadable tap_hold.toml must block the rewrite
; DESCRIPTION:
; LoadTapHoldToml merges the shipped _shared/tap_hold/defaults.toml UNDER the
; user file. When the user file exists but cannot be READ, the parse contributes
; nothing and the merged map is byte-for-byte what a user who customised nothing
; produces — the shipped defaults.
;
; ROOT CAUSE ENCODED:
; Nothing at any level could tell that apart from a healthy load. The loader's
; truncated-write sentinel only fires on ZERO keys, which the defaults overlay
; makes impossible, so the load was reported as a plain success with a plausible
; key count. Then the first tray tap-hold change rewrote tap_hold.toml FROM
; SCRATCH out of that defaults-only map: the user's per-key overrides, their
; hand-edited layer mappings and their explicit « Tout désactiver » opt-out were
; replaced on disk by the shipped defaults, permanently, with the menu happily
; re-rendering the default state as if it were theirs.
;
; ReadTomlFile already records "existing but unreadable" precisely so writers
; can ask. Only two consumers asked; this pair pins that the tap-hold loader and
; the tap-hold writer — the same file, the same config directory — ask too.
;
; SCOPE: behavioural for the loader (it is in the headless include graph);
; source introspection for the writer (platform/remap/tap_hold_writer.ahk is not
; loaded headlessly, so its guard cannot be provoked from here).
; ==============================================================================

#Requires AutoHotkey v2.0

; Deny-all sharing — the condition a sync client, an AV on-access scan, a backup
; agent or the user's own editor produces on a cloud-synced config directory.
global _TUB_EXCLUSIVE_LOCK_FLAGS := "r-rwd"

_TUB_ClearCaches(Path) {
	global _TomlFileCache, _TomlUnreadableFiles
	if _TomlFileCache.Has(Path)
		_TomlFileCache.Delete(Path)
	if _TomlUnreadableFiles.Has(Path)
		_TomlUnreadableFiles.Delete(Path)
}





; =================================================================
; =================================================================
; ======= 1/ The loader must flag an unreadable user file ==========
; =================================================================
; =================================================================

_TUB_LoaderFlagsAnUnreadableUserFile() {
	Path := A_Temp . "\ergopti_tub_tap_hold_" . A_TickCount . ".toml"
	FileAppend("[tap_hold.keys.caps_lock]`r`ntap_action = " . Chr(34) . "escape" . Chr(34) . "`r`n",
		Path, "UTF-8")
	_TUB_ClearCaches(Path)

	Lock := FileOpen(Path, _TUB_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock),
		"the exclusive lock must actually be taken — without it this case asserts nothing")
	Threw  := false
	Result := ""
	try {
		Result := LoadTapHoldToml(Path, "")
	} catch {
		Threw := true
	} finally {
		Lock.Close()
	}

	try {
		AssertFalse(Threw,
			"LoadTapHoldToml must not throw on an unreadable user file — it runs on the boot path and a throw there is a driver that never starts")
		AssertEqual("Map", Type(Result),
			"the loader must still return a usable scaffold when the read failed")
		AssertTrue(TOML_UnreadableFile(Path),
			"a tap_hold.toml that EXISTS but cannot be read must be flagged: the defaults overlay fills the merged map, so the result is indistinguishable from a user who customised nothing, and every writer that rebuilds the file from it erases their real configuration")
	} finally {
		_TUB_ClearCaches(Path)
		try FileDelete(Path)
	}
}


; The user's customisation must NOT be flagged when the file reads fine — a
; sentinel that is always up blocks every legitimate tray write instead.
_TUB_ReadableUserFileIsNotFlagged() {
	Path := A_Temp . "\ergopti_tub_ok_" . A_TickCount . ".toml"
	FileAppend("[tap_hold.keys.caps_lock]`r`ntap_action = " . Chr(34) . "escape" . Chr(34) . "`r`n",
		Path, "UTF-8")
	_TUB_ClearCaches(Path)
	try {
		TH := LoadTapHoldToml(Path, "")
		AssertEqual("escape", TapHoldTapAction(TH, "caps_lock"),
			"the user's override must load — this is the control that proves the case above measured a real failure")
		AssertFalse(TOML_UnreadableFile(Path),
			"a readable file must never be flagged unreadable, or every tap-hold write is refused for the rest of the session")
	} finally {
		_TUB_ClearCaches(Path)
		try FileDelete(Path)
	}
}





; =================================================================
; =================================================================
; ======= 2/ The writer must refuse to rebuild from it ============
; =================================================================
; =================================================================

_TUB_WriterRefusesToRebuildAnUnreadFile() {
	Body := _DriverFuncBody("_TH_WriteTapHoldToml")
	Assert(Body != "", "_TH_WriteTapHoldToml() must exist")
	Assert(InStr(Body, "TOML_UnreadableFile") > 0,
		"the tap-hold writer must ask whether the loader could READ the file it is about to rebuild — it serializes the in-memory map from scratch, and when the load saw nothing that map is the shipped defaults, not the user's configuration")

	GuardPos := InStr(Body, "TOML_UnreadableFile")
	for Writer in ["FileAppend", "FileMove"] {
		WritePos := InStr(Body, Writer)
		Assert(WritePos == 0 or GuardPos < WritePos,
			"the refusal must come BEFORE " . Writer . " — a guard after the staging write still replaces the user's file")
	}
	Assert(RegExMatch(Body, "TOML_UnreadableFile[^\r\n]*[\s\S]{0,400}?return false"),
		"the writer must RETURN FALSE when the file was unreadable: every caller re-publishes the live TapHold map only on a true return, so anything else leaves memory and disk disagreeing")
}


; The loader must say so out loud too. A success line with a plausible key count
; is what made this silent: the log asserted a load that never happened.
_TUB_LoaderReportsTheFailure() {
	Body := _DriverFuncBody("LoadTapHoldToml")
	Assert(Body != "", "LoadTapHoldToml() must exist")
	Assert(InStr(Body, "TOML_UnreadableFile") > 0,
		"the loader must consult the unreadable-file sentinel before declaring the load a success")
	Assert(InStr(Body, "LoggerError") > 0,
		"an unreadable tap_hold.toml must be logged at ERROR, not folded into the ordinary success line")
}


Test("tap-hold: an unreadable user file is flagged by the loader",
	_TUB_LoaderFlagsAnUnreadableUserFile)
Test("tap-hold: a readable user file is not flagged",
	_TUB_ReadableUserFileIsNotFlagged)
Test("tap-hold: the writer refuses to rebuild a file the loader could not read",
	_TUB_WriterRefusesToRebuildAnUnreadFile)
Test("tap-hold: the loader reports an unreadable file at ERROR",
	_TUB_LoaderReportsTheFailure)
