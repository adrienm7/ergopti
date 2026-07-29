; tests/meta/test_llm_model_menu_no_model_row_actionable.ahk

; ==============================================================================
; MODULE: LLM Model Menu "no model" Row Guard Meta Test
; DESCRIPTION:
; Static source guard for llm-no-model-row-clobbered.
;
; LLM_Menu_BuildModelMenu registers an actionable "Aucun modele (Desactive)"
; selector as the first row of the model submenu - it is how a user clears a
; configured model. Its catalogue fallback then built a DISABLED placeholder
; from the SAME i18n key, t("menu.llm.no_model"), with a raw Menu.Add followed by
; Menu.Disable.
;
; AHK v2's Menu.Add with an already-present label modifies that item in place
; rather than appending, so the placeholder did not add a row: it overwrote the
; selector's callback with a no-op, and the Disable that followed greyed out the
; one row the user needed. Reproduced with AutoHotkey64.exe: re-adding an
; existing label leaves GetMenuItemCount unchanged and GetMenuItemInfoW then
; reports MFS_DISABLED|MFS_GRAYED on the ORIGINAL row.
;
; The branch is reachable, not theoretical: it needs the curated catalogue to
; produce nothing (models.json missing, unreadable, or advertising no Ollama
; url) AND Ollama not ready, which is exactly the state of a fresh install with
; the feature off.
;
; Nothing reports it. The in-place update is not an error, RegisterMenuItem had
; already returned success for the real row, and a degradation path's output is
; never compared against the nominal one.
;
; THE FIX (the contract this test pins): no i18n key may label two different rows
; of this menu. The redundant placeholder is gone - the selector above it already
; says "no model" and, unlike the placeholder, stays clickable.
;
; Source-level: ui/menu/menu_llm/menu_models.ahk needs the whole LLM tray module
; graph, so run_all cannot #Include it.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================================
; ======= 1/ One i18n key labels at most one row =======
; ======================================================
; ======================================================

; Class-level: any repeated key in this builder is the same defect, whichever
; two rows collide. Pinning only "menu.llm.no_model" would let the next pair
; through.
_LMNM_NoI18nKeyLabelsTwoRows() {
	Body := _DriverFuncBody("LLM_Menu_BuildModelMenu")
	Assert(Body != "", "LLM_Menu_BuildModelMenu must be defined in menu_models.ahk")

	Counts := Map()
	Pos := 1
	while (Found := RegExMatch(Body, 't\("([^"]+)"\)', &M, Pos)) {
		Key := M[1]
		Counts[Key] := (Counts.Has(Key) ? Counts[Key] : 0) + 1
		Pos := Found + StrLen(M[0])
	}
	Assert(Counts.Count > 0,
		"LLM_Menu_BuildModelMenu must build its row labels from i18n keys - finding none means this "
		. "scan is looking at the wrong body and asserts nothing")
	for Key, N in Counts {
		Assert(N == 1,
			"i18n key '" . Key . "' labels " . N . " rows of the model menu. AHK v2's Menu.Add with an "
			. "existing label modifies that item IN PLACE, so the later row silently steals the "
			. "earlier one's callback - and when the later one is a disabled placeholder it greys out "
			. "the actionable row the user needs (llm-no-model-row-clobbered)")
	}
}
Test("menu_models: no i18n key labels two rows of the model menu (llm-no-model-row-clobbered)",
	_LMNM_NoI18nKeyLabelsTwoRows)





; ======================================================
; ======================================================
; ======= 2/ Both rows that mattered still exist =======
; ======================================================
; ======================================================

; Guards the lazy way out: deleting the actionable selector, or the whole
; installed-tags fallback, would also satisfy section 1.
_LMNM_SelectorAndFallbackSurvive() {
	Body := _DriverFuncBody("LLM_Menu_BuildModelMenu")
	Assert(Body != "", "LLM_Menu_BuildModelMenu must be defined in menu_models.ahk")

	Assert(InStr(Body, '_LLM_Menu_MakeSetModelHandler("")') > 0,
		"the actionable 'no model' selector must stay registered - it is the only way to clear a "
		. "configured model from the tray")
	Assert(InStr(Body, "_LLM_GetInstalledTagsCached(") > 0,
		"the installed-Ollama-tags fallback must stay - it is what gives the user a picker when the "
		. "curated catalogue produces nothing")
}
Test("menu_models: the 'no model' selector and the tag fallback both survive (llm-no-model-row-clobbered)",
	_LMNM_SelectorAndFallbackSurvive)
