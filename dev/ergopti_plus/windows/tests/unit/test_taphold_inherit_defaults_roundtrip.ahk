; tests/unit/test_taphold_inherit_defaults_roundtrip.ahk

; ==============================================================================
; MODULE: Regression — inherit_defaults must survive a load, not only a write
; DESCRIPTION:
; « Tout désactiver » writes `[tap_hold]` / `inherit_defaults = false` and sets
; the same flag on the live TapHold map, so the next reload skips the shipped
; defaults overlay. That half was fixed and is guarded. The other half was not.
;
; ROOT CAUSE ENCODED:
; LoadTapHoldToml read inherit_defaults into a parse-time LOCAL and never copied
; it into the map it RETURNS. The flag was therefore a one-way trip: the writer
; could put it on disk, but a reload could never bring it back into memory. And
; _TH_WriteTapHoldToml gates its `[tap_hold]` emit on Data.Has("inherit_defaults")
; — so after any reload, the very next individual tray change (one tap action,
; one hold modifier) rewrote the file WITHOUT that line, and the reload after
; that re-merged every shipped tap-hold the user had deliberately switched off.
; Nothing warned: the loader's truncated-write sentinel is deliberately exempt
; for this case, and the following boot logs an ordinary success.
;
; The existing guard for this bug is a set of source greps over the WRITER plus
; a "the loader source mentions inherit_defaults" check — which the broken
; loader satisfied, because it did mention it. This test asserts the round trip
; itself instead.
; ==============================================================================

#Requires AutoHotkey v2.0

_TIR_Write(Content) {
	Path := A_Temp . "\ergopti_tir_tap_hold_" . A_TickCount . ".toml"
	FileAppend(Content, Path, "UTF-8")
	return Path
}

_TIR_Clean(Path) {
	global _TomlFileCache, _TomlUnreadableFiles
	if _TomlFileCache.Has(Path)
		_TomlFileCache.Delete(Path)
	if _TomlUnreadableFiles.Has(Path)
		_TomlUnreadableFiles.Delete(Path)
	try FileDelete(Path)
}





; ==============================================================
; ==============================================================
; ======= 1/ The opt-out must come back into memory ============
; ==============================================================
; ==============================================================

_TIR_InheritDefaultsFalseRoundTrips() {
	Path := _TIR_Write(
		"[tap_hold]`r`ninherit_defaults = false`r`n"
		. "[tap_hold.keys.space]`r`ntap_action = " . Chr(34) . "tab" . Chr(34) . "`r`n"
	)
	try {
		TH := LoadTapHoldToml(Path, "some_defaults_that_do_not_exist.toml")
		AssertTrue(TH.Has("inherit_defaults"),
			"LoadTapHoldToml must carry inherit_defaults into the map it RETURNS: the writer gates its [tap_hold] emit on Data.Has(inherit_defaults) and serializes the live map, so a loader that keeps the flag to itself makes the next individual tray write drop the opt-out and silently re-enable every shipped tap-hold")
		AssertEqual(false, TH["inherit_defaults"],
			"inherit_defaults = false in the user file must survive the load as false")
	} finally {
		_TIR_Clean(Path)
	}
}


; The flag must NOT be materialised when the user never opted out: the writer's
; gate is a .Has() test, so inventing the key would start emitting a
; `[tap_hold]` section for everyone and change what the file means.
_TIR_AbsentFlagStaysAbsent() {
	Path := _TIR_Write("[tap_hold.keys.space]`r`ntap_action = " . Chr(34) . "tab" . Chr(34) . "`r`n")
	try {
		TH := LoadTapHoldToml(Path, "some_defaults_that_do_not_exist.toml")
		AssertFalse(TH.Has("inherit_defaults"),
			"a user file with no inherit_defaults must produce a map with no inherit_defaults key — the writer's emit gate is a .Has() test, and materialising the key would make every write claim an opt-out the user never made")
		AssertEqual("tab", TapHoldTapAction(TH, "space"),
			"control: the rest of the user file must still load")
	} finally {
		_TIR_Clean(Path)
	}
}


Test("tap-hold: inherit_defaults = false round-trips into the returned map",
	_TIR_InheritDefaultsFalseRoundTrips)
Test("tap-hold: an absent inherit_defaults is not invented by the loader",
	_TIR_AbsentFlagStaysAbsent)
