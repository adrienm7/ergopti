; tests/meta/test_llm_profile_menu_unique_labels.ahk

; ==============================================================================
; MODULE: LLM Profile Menu Label-Uniqueness Guard Meta Test
; DESCRIPTION:
; Static source guard for duplicate-user-profile-label-menu-collapse.
;
; AHK v2's Menu.Add with an already-present label MODIFIES that item in place
; instead of appending: two Adds of the same text leave GetMenuItemCount at 1 and
; the second callback owns the row. RegisterMenuItem then sees the count did not
; grow, falls through to _FindUniqueMenuItemIdByName, gets the single surviving
; id and rebinds it - with a fresh token - to the newcomer. The earlier row's
; TrackedObj is orphaned for good.
;
; LLM_Menu_BuildProfileMenu builds its user rows straight from p["label"], which
; is free text the user typed in "Creer un profil" (that dialog performs no
; uniqueness check). The "  (Ctrl+n)" hint appended next to each row hides the
; collision for the first few profiles only: LLM_Menu_GetProfileHotkeyHint
; returns "" past LLM_PROFILE_HOTKEY_LIMIT, so from the sixth user profile
; onward two profiles named the same collapse into one row. The older one can
; never be selected, edited or deleted from the menu, and if it is the active
; one the checkmark is painted on the other profile's row.
;
; Nothing reports this. Menu.Add's in-place update is not an error, and
; RegisterMenuItem's "Ambiguous or unresolvable menu label" warning fires only
; when TWO items carry the text - here there is only ever one.
;
; THE FIX (the contract this test pins): every row label in the profile menu goes
; through a per-menu disambiguator that suffixes " #2", " #3"... to repeats,
; exactly like _HS_BuildDisambiguatedSectionLabels already does for personal
; hotstring sections.
;
; Source-level: ui/menu/menu_llm/menu_profiles.ahk registers Ctrl+<n> hotkeys and
; pulls in the whole LLM tray module graph, so the headless runner cannot
; #Include it.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================================
; ========================================================
; ======= 1/ The disambiguator does what it claims =======
; ========================================================
; ========================================================

_LPUL_DisambiguatorSuffixesRepeats() {
	Body := _DriverFuncBody("_LLM_Menu_UniqueMenuLabel")
	Assert(Body != "", "_LLM_Menu_UniqueMenuLabel must be defined next to the profile menu builder")
	Assert(InStr(Body, "Seen.Has(Label)") > 0,
		"_LLM_Menu_UniqueMenuLabel must count occurrences per menu - without the counter it cannot "
		. "tell a first use from a repeat")
	Assert(InStr(Body, '" #"') > 0,
		"_LLM_Menu_UniqueMenuLabel must suffix repeats with a bare ' #N' - a digit needs no i18n "
		. "string and leaves the common unique case rendering exactly as before")
}
Test("menu_profiles: the row-label disambiguator suffixes repeats (duplicate-user-profile-label-menu-collapse)",
	_LPUL_DisambiguatorSuffixesRepeats)





; ==========================================================
; ==========================================================
; ======= 2/ Every profile row label goes through it =======
; ==========================================================
; ==========================================================

_LPUL_ProfileRowsUseUniqueLabels() {
	Body := _DriverFuncBody("LLM_Menu_BuildProfileMenu")
	Assert(Body != "", "LLM_Menu_BuildProfileMenu must be defined in menu_profiles.ahk")

	Second := InStr(Body, "_LLM_Menu_UniqueMenuLabel(", , 1, 2)
	Assert(Second > 0,
		"BOTH row loops in LLM_Menu_BuildProfileMenu - built-ins and user profiles - must take their "
		. "label from the disambiguator. The counter is shared across the whole menu, so a user "
		. "profile whose label matches a built-in row is covered too")

	; The user-profile row is the reachable case: its label is free user text.
	; The disambiguation must land on the variable, so the checkmark and the
	; registration both see the same unique string.
	AssignPos := InStr(Body, "plabel := _LLM_Menu_UniqueMenuLabel(")
	HandlerPos := InStr(Body, "_LLM_Menu_MakeUserProfileClickHandler(")
	Assert(AssignPos > 0 and HandlerPos > AssignPos,
		"the user-profile label must be made unique BEFORE it is registered - an identical label "
		. "silently overwrites the earlier profile's row, orphaning it and painting the checkmark on "
		. "the wrong profile (duplicate-user-profile-label-menu-collapse)")
}
Test("menu_profiles: two profiles sharing a label render as two rows (duplicate-user-profile-label-menu-collapse)",
	_LPUL_ProfileRowsUseUniqueLabels)
