; tests/meta/test_hcw_patch_toml_meta_refuses_unread_file.ahk

; ==============================================================================
; MODULE: Regression — the config window must not rewrite a personal TOML it
;         could not read (hcw-patch-toml-meta-unread-file)
; DESCRIPTION:
; _HCW_PatchTomlMeta is a read-modify-rewrite over a file that holds the user's
; own hotstrings. It seeds itself from ReadTomlFile, which returns "" for an
; EXISTING file it could not open (an exclusive handle from a sync client, an AV
; scan, the file open in another editor) and records the path in the shared
; _TomlUnreadableFiles sentinel precisely so writers of this shape refuse.
;
; ROOT CAUSE ENCODED: without that check, "I could not read it" is
; indistinguishable from "it was empty". The scan finds nothing, the rewrite
; serialises that emptiness back over the original, and "Réinitialiser tout" —
; which calls this six times per personal entry, each invalidating the cache so
; the next call really hits the disk — truncates personal_hotstrings.toml to zero
; bytes under a success notification. The three siblings of the same shape
; (ApplyConfigToml, WritePersonalToml, TOML_BatchWrite) all consult the sentinel;
; this was the one that did not.
;
; The ORDER matters as much as the presence: FileOpen(Path, "w") truncates
; immediately, so a guard placed after it would run on an already-emptied file.
;
; SCOPE: source-level. The config window builds a native Gui at top level and is
; outside the headless include graph, exactly like
; test_config_window_patch_toml_meta_error.ahk, whose assertions cover the failed
; WRITE — this file covers the failed READ, which is the destructive half.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ The refusal exists, and comes before the write ========
; ==================================================================
; ==================================================================

_PTMU_PatchTomlMetaRefusesAnUnreadFile() {
	Body := _DriverFuncBody("_HCW_PatchTomlMeta")
	Assert(Body != "", "_HCW_PatchTomlMeta must exist in the driver source")

	ReadPos := InStr(Body, "ReadTomlFile(")
	Assert(ReadPos > 0,
		"prerequisite: the patcher still seeds its rewrite from ReadTomlFile — that read is what makes the guard necessary")

	GuardPos := InStr(Body, "TOML_UnreadableFile")
	Assert(GuardPos > 0,
		"_HCW_PatchTomlMeta must ask whether ReadTomlFile actually read the file. It rewrites the user's personal_hotstrings.toml from that content, so a failed read serialises an empty file over every personal hotstring it holds — silently, under a success notification")
	Assert(ReadPos < GuardPos,
		"the guard must follow the read that sets the sentinel, or it inspects the previous call's verdict")

	WritePos := InStr(Body, "FileOpen(")
	Assert(WritePos > 0, "prerequisite: the patcher still opens the file for writing")
	Assert(GuardPos < WritePos,
		'the refusal must come BEFORE the file is opened for writing — FileOpen(Path, "w") truncates in place the moment it succeeds, so a guard placed after it would only ever report on a file that is already empty')
}
Test("meta hcw-patch-toml-meta-unread-file: the patcher refuses a file it could not read",
	_PTMU_PatchTomlMetaRefusesAnUnreadFile)


; A guard that neither stops the function nor says anything would satisfy the
; ordering assertions above while still destroying the file.
_PTMU_RefusalIsLoudAndStopsTheRewrite() {
	Body := _DriverFuncBody("_HCW_PatchTomlMeta")
	Assert(Body != "", "_HCW_PatchTomlMeta must exist in the driver source")

	Assert(RegExMatch(Body, "TOML_UnreadableFile[\s\S]{0,400}?LoggerError") > 0,
		"the refusal must be logged as an ERROR — the user sees a success TrayTip either way, so the log is the only place this failure can surface")
	Assert(RegExMatch(Body, "TOML_UnreadableFile[\s\S]{0,400}?return false") > 0,
		"the refusal must RETURN — falling through after logging still rewrites the file from the content that was never read")
}
Test("meta hcw-patch-toml-meta-unread-file: the refusal is logged and stops the rewrite",
	_PTMU_RefusalIsLoudAndStopsTheRewrite)
