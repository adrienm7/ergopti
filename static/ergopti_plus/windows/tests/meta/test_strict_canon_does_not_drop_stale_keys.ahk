; tests/meta/test_strict_canon_does_not_drop_stale_keys.ahk

; ==============================================================================
; MODULE: Strict-Canonicalization Docstring Truth Meta Test
; DESCRIPTION:
; Static source guard for finding strict-canon-does-not-drop-stale-keys.
;
; TOML_RunStrictCanonicalization re-serializes the unified config via
; SaveFullConfig. Its docstring used to claim it "rebuilds the file from the
; in-memory state so stale sections/keys are dropped". That is false:
; TOML_BatchWrite is a read-modify-MERGE and ParseTomlFile's cache feeds the
; previous on-disk values back in, so untouched sections/keys are PRESERVED,
; not dropped. The documented stale-key pruning never happens.
;
; The fix corrects the docstring to state the real merge/preserve semantics
; and removes the false "dropped" claim (rule 5.7 - docs must match behaviour).
; This meta-static test pins the documented behaviour: the docstring must not
; claim stale keys are dropped, and must state that untouched sections are
; preserved (merge semantics).
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helper ====================
; ==================================================
; ==================================================

; Returns the comment block immediately preceding a function declaration -
; from the last blank line before the declaration up to the declaration line.
; Good enough to scope the assertions to the function's own docstring.
_SCDD_DocBlock(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Head := SubStr(Src, 1, Idx - 1)
	; Walk back to the most recent run of two consecutive newlines (blank line)
	; so we capture only this function's leading comment, not earlier ones.
	Sep := InStr(Head, "`n`n", , -1)
	if Sep
		return SubStr(Head, Sep)
	return Head
}




; ==================================================
; ==================================================
; ======= 2/ Docstring truth assertions ============
; ==================================================
; ==================================================

_SCDD_DocstringMatchesMergeBehaviour() {
	; Move-resilient: scan the toml module dir via the framework helper (comments
	; preserved) instead of a pinned infra/toml/toml_helpers.ahk read. The DocBlock
	; extractor still scopes the assertion to TOML_RunStrictCanonicalization's own
	; leading comment, which is unique across the dir.
	Src := _DriverDirConcat("infra/toml")
	Doc := _SCDD_DocBlock(Src, "TOML_RunStrictCanonicalization(Path) {")
	Assert(Doc != "", "TOML_RunStrictCanonicalization docstring must exist in toml_helpers.ahk")
	; The false claim must be gone - the step does not drop stale sections/keys.
	Assert(InStr(Doc, "dropped") = 0,
		"TOML_RunStrictCanonicalization docstring must not claim stale sections/keys are 'dropped' - BatchWrite merges, so the pruning never happens (rule 5.7)")
	; The docstring must now state the real merge/preserve semantics.
	Assert(InStr(Doc, "PRESERVED") > 0,
		"TOML_RunStrictCanonicalization docstring must state that untouched sections/keys are PRESERVED (merge semantics)")
}
Test("toml_helpers: strict-canon docstring documents merge/preserve, not stale-key dropping (strict-canon-does-not-drop-stale-keys)", _SCDD_DocstringMatchesMergeBehaviour)
