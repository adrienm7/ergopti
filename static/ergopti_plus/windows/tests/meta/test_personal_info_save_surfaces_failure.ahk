; tests/meta/test_personal_info_save_surfaces_failure.ahk

; ==============================================================================
; MODULE: Regression — a failed personal-information write must not be followed
;         by a Reload (personal-info-save-surfaces-failure)
; DESCRIPTION:
; _PiEdWeb_Save wrote the edited values into the in-memory PersonalInformation
; map, called WritePersonalInfoToml(...), THREW THE RESULT AWAY, logged "Saved
; personal information — reloading…" and called Reload(). On a read-only or
; locked personal_info.toml (mid-sync cloud folder, AV scanner, copied read-only
; profile) the writer catches the OSError and returns False — and the Reload then
; re-read the unchanged file, so the user's edits disappeared while every
; user-visible signal reported success.
;
; ROOT CAUSE ENCODED: the F-29 hardening — "a failed config write must be
; surfaced, and must not be followed by a Reload() that hides it" — was applied
; to _PathsEdWeb_Save and the structurally identical sibling was never triaged.
; Making the WRITER log was only half of it: a caller that ignores the result
; turns a reported failure back into a silent one.
;
; SCOPE: source-level — the personal-information editor creates a WebView2 host
; at open time and is outside the headless include graph.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ The caller branches on the write result ===============
; ==================================================================
; ==================================================================

_PISF_SaveBranchesBeforeReload() {
	Body := _DriverFuncBody("_PiEdWeb_Save")
	Assert(Body != "", "_PiEdWeb_Save must exist in the driver source")

	GuardPos := InStr(Body, "if !WritePersonalInfoToml")
	Assert(GuardPos > 0,
		"_PiEdWeb_Save must branch on WritePersonalInfoToml's result — discarding it is what turned a reported write failure back into a silent one")

	ReloadPos := InStr(Body, "Reload()")
	Assert(ReloadPos > 0, "prerequisite: the success path still reloads so the engine rebuilds its expansions")
	Assert(GuardPos < ReloadPos,
		"the failure branch must come BEFORE Reload(). Reloading after a failed write re-reads the unchanged file and discards the in-memory edits — the editor window is the only place the user's values still exist at that point")

	Assert(RegExMatch(Body, "if !WritePersonalInfoToml[\s\S]{0,400}?return") > 0,
		"the failure branch must RETURN — falling through reaches the very Reload() this guards against")
	Assert(RegExMatch(Body, "if !WritePersonalInfoToml[\s\S]{0,400}?LoggerError") > 0,
		"the failure must be logged at ERROR level by the caller too: the writer's own line says the file could not be written, this one says the user's edits were kept and not saved")
}
Test("meta personal-info-save: a failed write is not followed by a Reload that hides it",
	_PISF_SaveBranchesBeforeReload)





; ==================================================================
; ==================================================================
; ======= 2/ The writer really does report failure =================
; ==================================================================
; ==================================================================

; The branch above is only worth anything if the writer's contract holds: a
; boolean, false on failure, true on success. An implicit return would make the
; new guard fire on every successful save instead.
_PISF_WriterReportsBothOutcomes() {
	Body := _DriverFuncBody("WritePersonalInfoToml")
	Assert(Body != "", "WritePersonalInfoToml must exist in the driver source")
	Assert(RegExMatch(Body, "i)return\s+false") > 0,
		"WritePersonalInfoToml must return false when it refuses or fails, or its callers cannot branch on anything")
	Assert(RegExMatch(Body, "i)return\s+true") > 0,
		"WritePersonalInfoToml must return true on success — an implicit return is falsy in AHK v2, which would make a caller's `if !Write…` guard fire on every successful save")
}
Test("meta personal-info-save: the writer reports both outcomes explicitly",
	_PISF_WriterReportsBothOutcomes)
