; tests/unit/test_personal_read_clears_unreadable_latch.ahk

; ==============================================================================
; MODULE: Regression — the reader that raises the unreadable latch must lower it
;         (personal-toml-unreadable-latch-never-lowered)
; DESCRIPTION:
; _TomlUnreadableFiles is a process-wide Map keyed by PATH, shared by three
; unrelated readers. ReadPersonalToml raises the flag in its catch;
; WritePersonalToml refuses while it is up, and its own comment asserts that
; "the flag is cleared by any successful read of the same path, so this unblocks
; itself".
;
; ROOT CAUSE ENCODED: that sentence was false for the very reader whose model
; the writer guards. ReadPersonalToml had no Delete on its success path, and the
; only code anywhere that lowers the latch is ReadTomlFile — which is reached
; for the personal path only through LoadHotstringsSection (skipped for every
; DISABLED section, which is the default) or by opening the delay/colour window.
; So one transient lock at boot blocked every personal-hotstrings save for the
; rest of the session, while _ReadPersonalTomlCache happily held the user's real
; model from a later, successful read. Three of the four editor call sites
; discard the refusal and repaint the GUI as if the save had happened.
;
; NOTE ON THE SHIPPED TEST NEXT DOOR: _UCP_PersonalReadStillWorks looks like it
; covers this, but it clears the flag on a freshly-created unique path before
; reading, so its "not flagged" assertion passes vacuously. This test raises the
; latch FIRST, which is the only way the property can fail.
; ==============================================================================

#Requires AutoHotkey v2.0

; Point the personal-hotstrings reader at a throwaway file. It resolves its own
; path through PersonalTomlPath() and takes no path argument, so redirecting the
; resolver is the only way to keep the test off the user's real data.
_PRCL_WithTempPersonalToml(Path, Fn) {
	global ScriptInformation, _ReadPersonalTomlCache
	if !IsSet(ScriptInformation)
		ScriptInformation := Map()
	HadKey := ScriptInformation.Has("PersonalTomlPath")
	PrevPath := HadKey ? ScriptInformation["PersonalTomlPath"] : ""
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






; ===============================================================
; ===============================================================
; ======= 1/ A successful read lowers the latch it raised =======
; ===============================================================
; ===============================================================

_PRCL_SuccessfulReadClearsAStaleLatch() {
	global _TomlUnreadableFiles
	Q := Chr(34)
	LF := Chr(10)
	Path := A_Temp . "\ergopti_test_personal_latch_" . A_TickCount . ".toml"
	Assert(IsSet(_TomlUnreadableFiles),
		"the shared unreadable-file sentinel must exist for this property to mean anything")

	try FileDelete(Path)
	FileAppend("[_meta]" . LF . "description = " . Q . "mine" . Q . LF, Path, "UTF-8")
	; Raise the latch exactly as a transient boot lock would have, then let the
	; lock clear and read again — the sequence the writer's comment claims
	; unblocks itself.
	_TomlUnreadableFiles[Path] := true

	Result := _PRCL_WithTempPersonalToml(Path, ReadPersonalToml)
	StillFlagged := _TomlUnreadableFiles.Has(Path)

	if _TomlUnreadableFiles.Has(Path)
		_TomlUnreadableFiles.Delete(Path)
	try FileDelete(Path)

	Assert(Result is Map, "the reader must still return its model")
	Assert(!StillFlagged,
		"a successful ReadPersonalToml must clear the unreadable latch it set. Nothing else on this path lowers it — the only Delete in the driver lives in ReadTomlFile, which a disabled personal section never reaches — so one transient boot lock blocked every personal-hotstrings save for the whole session while the cache already held the user's real hotstrings")
}
Test("personal TOML: a successful read lowers the unreadable latch (personal-toml-unreadable-latch-never-lowered)",
	_PRCL_SuccessfulReadClearsAStaleLatch)
