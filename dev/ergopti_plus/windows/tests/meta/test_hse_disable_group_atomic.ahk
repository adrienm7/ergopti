; tests/meta/test_hse_disable_group_atomic.ahk

; ==============================================================================
; MODULE: HSE_DisableGroup Atomic Rebuild Meta Test
; DESCRIPTION:
; Static source guard for the disable-enable-group-unguarded-but-dead-path finding.
;
; HSE_DisableGroup() splices the star set and then resets the whole star prefix
; set / by-trigger index to empty before re-indexing the survivors. That reset
; opens a wide window in which an OnChar reader (HSE_FindMatchAtEnd) could observe
; an empty star index and drop every star expansion for the rebuild duration —
; the same cooperative-threading race HSE_Register guards against. Today the live
; menu toggle path uses RebuildHotstringsLive's clear+rebuild, NOT group toggling,
; so this is a latent race on a dead path; but if group toggling is ever re-wired
; to the menu it becomes a live high-severity star-expansion drop.
;
; The fix wraps the splice + reset + re-index region of HSE_DisableGroup in a
; Critical("On")/restore block (mirroring HSE_Register) so the reader never
; preempts mid-rebuild. This test pins that Critical wrap: it extracts the
; HSE_DisableGroup body and asserts Critical("On") appears BEFORE the empty-Map
; reset of the star prefix set, so a future edit that drops the wrap (re-opening
; the race) fails loudly.
;
; Meta-static rather than behavioral: the synchronous headless harness cannot
; reproduce the cooperative-threading preemption, so the STRUCTURAL guarantee is
; what we pin (the behavioral correctness of disable/enable is already covered by
; test_hotstring_engine_main.ahk).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_HDGA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Atomicity assertion ====================
; ===================================================
; ===================================================

_HDGA_DisableGroupRebuildIsAtomic() {
	Src := _HDGA_ReadSource("lib/hotstrings/hotstring_engine_main.ahk")
	Body := _DriverFuncBody("HSE_DisableGroup")
	Assert(Body != "", "HSE_DisableGroup(Group) declaration must exist in hotstring_engine_main.ahk")

	; The wide index rebuild must be Critical-wrapped so a reader thread never
	; observes the star prefix set / by-trigger index mid-reset (an empty index
	; would silently drop every star expansion for the rebuild duration).
	CritPos := InStr(Body, 'Critical("On")')
	Assert(CritPos > 0,
		"HSE_DisableGroup must enter Critical around the index rebuild so an OnChar reader never sees an empty star index")

	; The empty-Map reset of the star prefix set is the start of the wide window;
	; Critical must be entered BEFORE it.
	ResetPos := InStr(Body, "HSE_StarPrefixSetCI := Map()")
	Assert(ResetPos > 0, "HSE_DisableGroup must rebuild the star prefix set from the spliced star specs")
	Assert(CritPos < ResetPos,
		"Critical must be enabled BEFORE the star prefix set is reset to empty in HSE_DisableGroup")

	; The by-trigger index rebuild must also be inside the Critical region.
	RebuildPos := InStr(Body, "_HSE_RebuildStarTriggerIndex()")
	Assert(RebuildPos > 0, "HSE_DisableGroup must rebuild the by-trigger index from the spliced star specs")
	Assert(CritPos < RebuildPos,
		"Critical must cover the by-trigger index rebuild in HSE_DisableGroup")

	; Critical must be restored at the end so it does not leak past the function.
	Assert(InStr(Body, "Critical(_DgCrit)") > 0,
		"HSE_DisableGroup must restore the prior Critical state after the rebuild (no leaked Critical)")
}
Test("hotstring_engine: HSE_DisableGroup rebuild is Critical-wrapped (disable-enable-group-unguarded-but-dead-path)", _HDGA_DisableGroupRebuildIsAtomic)
