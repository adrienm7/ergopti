; tests/meta/test_personal_editor_section_guard.ahk

; ==============================================================================
; MODULE: Personal Editor Section Pointer Guard Meta Test
; DESCRIPTION:
; _PersonalEditorSection is a pointer that can outlive its target: the persisted
; default_section names a section that may have been deleted in an earlier
; session. A Map read on a missing key THROWS UnsetItemError in AHK v2, so every
; consumer of that pointer must prove the section is still live before touching
; it.
;
; "Selected" is two conditions, not one — non-empty AND present. Checking only
; the first is what left _RenameSection and _DeleteSection broken after four of
; their six sibling consumers were guarded: both tested for "", guarded their
; read with .Has(), and then threw on the very next write (a ["description"] :=
; assignment and a sections.Delete respectively).
;
; FEATURES & RATIONALE:
; 1. Enumerates every occurrence of the indexed read across the file, per
;    project-ahk-guard-tests-must-loop-the-class, so a seventh consumer added
;    without a guard fails immediately. The previous fix guarded four of six
;    precisely because it worked from a list rather than from the class.
; 2. Encodes the ROOT CAUSE — an unproven pointer — rather than the two
;    functions where it happened to surface.
;
; SCOPE: source introspection of ui/personal_toml_editor.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Every consumer proves the pointer =======
; ====================================================
; ====================================================

; Every function that indexes sections[_PersonalEditorSection] must first prove
; the key exists — either inline with .Has(), or through the shared helper.
_PESG_EveryConsumerIsGuarded() {
	Src := _DriverDirConcat("ui")
	Assert(InStr(Src, "_PersonalEditorSection") > 0,
		'the personal editor source must be reachable from the ui/ directory concat')

	Needle := '_PersonalEditorData["sections"][_PersonalEditorSection]'
	Pos := 1
	Checked := 0
	while (Pos := InStr(Src, Needle, , Pos)) {
		Checked += 1
		; Look back over a bounded window for either form of the guard. The
		; window is generous enough to span a function preamble but far short of
		; the whole file, so a guard in an unrelated earlier function cannot
		; vouch for this one.
		WinStart := (Pos > 1400) ? Pos - 1400 : 1
		Window := SubStr(Src, WinStart, Pos - WinStart)
		Guarded := InStr(Window, ".Has(_PersonalEditorSection)") > 0
			or InStr(Window, "_PersonalEditorRequireSection(") > 0
		Assert(Guarded,
			"an indexed read of sections[_PersonalEditorSection] at offset " . Pos
			. " is not preceded by a .Has() check or a _PersonalEditorRequireSection() call — a stale default_section pointer throws UnsetItemError here")
		Pos += StrLen(Needle)
	}
	Assert(Checked >= 6,
		"expected at least six indexed reads to police (found " . Checked . ") — if the count dropped, confirm the consumers were removed rather than the scan silently missing them")
}

; The shared helper must test BOTH halves of "selected". A helper that only
; checked for "" would reintroduce the exact defect it exists to prevent.
_PESG_HelperChecksPresenceNotJustEmptiness() {
	Body := _DriverFuncBody("_PersonalEditorRequireSection")
	Assert(Body != "", "_PersonalEditorRequireSection() must exist")

	Assert(InStr(Body, '_PersonalEditorSection == ""') > 0,
		"the helper must reject an empty pointer")
	Assert(InStr(Body, ".Has(_PersonalEditorSection)") > 0,
		"the helper must also reject a pointer that names a section which no longer exists — that is the half the previous fix missed")
	Assert(InStr(Body, "return false") > 0 and InStr(Body, "return true") > 0,
		"the helper must return a boolean its callers can branch on")
}


Test("meta personal-editor: every consumer proves the section pointer is live",
	_PESG_EveryConsumerIsGuarded)
Test("meta personal-editor: the shared guard checks presence, not just emptiness",
	_PESG_HelperChecksPresenceNotJustEmptiness)
