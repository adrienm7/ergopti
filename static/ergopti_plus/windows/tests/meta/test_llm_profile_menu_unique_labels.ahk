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

; The rows became provider DATA on 2026-08-07, so the subject is the function
; that builds them - the renderer's Add collapses two identical labels exactly
; as a hand-written one did, which is why the guard follows the rows rather than
; the Menu calls.
_LPUL_ProfileRowsUseUniqueLabels() {
	Frame := _DriverFuncBody("_LLM_Menu_ProfileRows")
	Assert(Frame != "", "_LLM_Menu_ProfileRows must be defined in menu_profiles.ahk")
	Builtin := _DriverFuncBody("_LLM_Menu_ProfileBuiltinRows")
	Custom := _DriverFuncBody("_LLM_Menu_ProfileCustomRows")
	Assert(Builtin != "" && Custom != "", "both actual frame providers must exist")
	AssertTrue(_LPUL_FrameSharesLabelCounter(Frame), "both declared native providers bind the same per-menu counter")
	Body := Builtin . "`n" . Custom

	Second := InStr(Body, "_LLM_Menu_UniqueMenuLabel(", , 1, 2)
	Assert(Second > 0,
		"BOTH actual frame provider row loops - built-ins and user profiles - must take their "
		. "label from the disambiguator. The counter is shared across the whole menu, so a user "
		. "profile whose label matches a built-in row is covered too")

	; The user-profile row is the reachable case: its label is free user text.
	; The disambiguated string must be what the row CARRIES, so the checkmark and
	; the click handler cannot end up on a different label than the one drawn.
	HandlerPos := InStr(Body, "_LLM_Menu_MakeUserProfileClickHandler(")
	Assert(HandlerPos > Second,
		"the user-profile label must be made unique inside the same row as its handler - an identical "
		. "label silently overwrites the earlier profile's row, orphaning it and painting the checkmark "
		. "on the wrong profile (duplicate-user-profile-label-menu-collapse)")
	Assert(!RegExMatch(Body, 'i)"label"\s*,\s*plabel\b'),
		"the raw user label must never reach the row - it has to go through the disambiguator first "
		. "(duplicate-user-profile-label-menu-collapse)")
}
Test("menu_profiles: two profiles sharing a label render as two rows (duplicate-user-profile-label-menu-collapse)",
	_LPUL_ProfileRowsUseUniqueLabels)


_LPUL_FrameSharesLabelCounter(Frame) {
	Patterns := [
		'm)^[ \t]*seen_labels := Map\(\)',
		'm)^[ \t]*return MenuRenderer_TemplateRows\("llm_profile_windows_frame", Map\(',
		'm)^[ \t]*"llm_profile_builtin_rows", _LLM_Menu_ProfileBuiltinRows\.Bind\(seen_labels\),',
		'm)^[ \t]*"llm_profile_custom_rows", _LLM_Menu_ProfileCustomRows\.Bind\(seen_labels, FrameState\),'
	]
	Tokens := ["seen_labels", "return", "_LLM_Menu_ProfileBuiltinRows.Bind", "_LLM_Menu_ProfileCustomRows.Bind"]
	Code := _DriverMaskNonCode(&Frame)
	Cursor := 1
	for Index, Pattern in Patterns {
		Position := RegExMatch(Frame, Pattern, &Matched, Cursor)
		if !Position
			return false
		; Slot keys are literal Map data. Authenticate the exact provider/Bind
		; token at its matched offset, not the quoted slot key at line start.
		Offset := InStr(Matched[0], Tokens[Index], true)
		if !Offset || SubStr(Code, Position + Offset - 1, StrLen(Tokens[Index])) != Tokens[Index]
			return false
		Cursor := Position + 1
	}
	return true
}
_LPUL_FrameCounterRejectsDetachedProviders() {
	Frame := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_ProfileRows"))
	AssertTrue(_LPUL_FrameSharesLabelCounter(Frame), "the genuine frame shares one counter")
	for Mutation in [
		['seen_labels := Map()', 'Unrelatedseen_labels := Map()'],
		['_LLM_Menu_ProfileBuiltinRows.Bind(seen_labels)', '_LLM_Menu_ProfileBuiltinRows.Bind(Map())'],
		['_LLM_Menu_ProfileCustomRows.Bind(seen_labels, FrameState)', '_LLM_Menu_ProfileCustomRows.Bind(Map(), FrameState)'],
		['"llm_profile_custom_rows", _LLM_Menu_ProfileCustomRows', '"unrelated_rows", _LLM_Menu_ProfileCustomRows']] {
		Changed := StrReplace(Frame, Mutation[1], Mutation[2], true)
		AssertFalse(Changed == Frame, "the decoy must mutate the actual registered provider binding")
		AssertFalse(_LPUL_FrameSharesLabelCounter(Changed), "separate counters and foreign provider slots must refuse")
	}
}
Test("menu_profiles: declared frame binds one counter to both real profile providers",
	_LPUL_FrameCounterRejectsDetachedProviders)

; Exercise actual provider data and Win32 row addition beyond the hotkey range.
_LPUL_ActualFrameKeepsDuplicateBuiltinAndUserRows() {
	global _LLM_Menu, LLM_PROFILE_BUILTIN_ORDER, LLM_PROFILE_HOTKEY_LIMIT
	global LLM_TONE_LADDER, LLM_PROFILE_LIVE_TRANSLATIONS
	Previous := _LLM_Menu
	SavedContext := Map("had_order", IsSet(LLM_PROFILE_BUILTIN_ORDER),
		"had_limit", IsSet(LLM_PROFILE_HOTKEY_LIMIT),
		"had_tone", IsSet(LLM_TONE_LADDER),
		"had_live", IsSet(LLM_PROFILE_LIVE_TRANSLATIONS))
	if IsSet(LLM_PROFILE_BUILTIN_ORDER)
		SavedContext["order"] := LLM_PROFILE_BUILTIN_ORDER
	if IsSet(LLM_PROFILE_HOTKEY_LIMIT)
		SavedContext["limit"] := LLM_PROFILE_HOTKEY_LIMIT
	if IsSet(LLM_TONE_LADDER)
		SavedContext["tone"] := LLM_TONE_LADDER
	if IsSet(LLM_PROFILE_LIVE_TRANSLATIONS)
		SavedContext["live"] := LLM_PROFILE_LIVE_TRANSLATIONS
	Built := false
	try {
		; The direct native fixture may start without its number-row context.
		; Use the actual declarations, then restore exact absent/value identities.
		LLM_PROFILE_BUILTIN_ORDER := _LPUL_NativeProfileArray("LLM_PROFILE_BUILTIN_ORDER")
		LLM_TONE_LADDER := _LPUL_NativeProfileArray("LLM_TONE_LADDER")
		LLM_PROFILE_LIVE_TRANSLATIONS := _LPUL_NativeProfileArray("LLM_PROFILE_LIVE_TRANSLATIONS")
		LLM_PROFILE_HOTKEY_LIMIT := _LPUL_NativeProfileHotkeyLimit()
		_LLM_Menu := _HSDeepCloneMap(Previous)
		_LLM_Menu["user_profiles"] := []
		BuiltinId := ""
		for Id in LLM_PROFILE_BUILTIN_ORDER {
			if LLM_Menu_GetProfileHotkeyHint(Id) == "" {
				BuiltinId := Id
				break
			}
		}
		AssertFalse(BuiltinId == "", "the genuine catalogue contains an unhinted builtin")
		SharedLabel := LLM_Menu_GetProfileLabel(BuiltinId)
		loop LLM_PROFILE_HOTKEY_LIMIT
			_LLM_Menu["user_profiles"].Push(Map("id", "lpul_filler_" . A_Index, "label", "LPUL filler " . A_Index))
		for Index in [1, 2, 3]
			_LLM_Menu["user_profiles"].Push(Map("id", "lpul_duplicate_" . Index, "label", SharedLabel))
		_LLM_Menu["profile_id"] := "lpul_duplicate_3"
		for Index in [1, 2, 3]
			AssertEqual("", LLM_Menu_GetProfileHotkeyHint("lpul_duplicate_" . Index),
				"the duplicate cases must really be beyond all native hotkey hints")
		Rows := _LLM_Menu_ProfileRows()
		Seen := Map(), Matches := []
		for Row in Rows {
			if !Row.Has("label")
				continue
			AssertFalse(Seen.Has(Row["label"]), "every actual frame label remains unique")
			Seen[Row["label"]] := true
			for Expected in [SharedLabel, SharedLabel . " #2", SharedLabel . " #3", SharedLabel . " #4"] {
				if Row["label"] == Expected {
					AssertTrue(HasMethod(Row["action"], "Call"), "each colliding profile retains its native callback")
					Matches.Push(Row)
				}
			}
		}
		AssertEqual(4, Matches.Length, "one builtin and three free-text duplicates remain four rows")
		AssertFalse(Matches[1]["checked"])
		AssertFalse(Matches[2]["checked"])
		AssertFalse(Matches[3]["checked"])
		AssertTrue(Matches[4]["checked"], "the active third user profile owns its own checkmark")
		AssertFalse(Matches[2]["action"] == Matches[3]["action"], "distinct profile callbacks cannot collapse")
		Built := LLM_Menu_BuildProfileMenu()
		AssertEqual(Rows.Length, DllCall("GetMenuItemCount", "ptr", Built.Handle, "int"),
			"the actual Win32 menu appends every frame row rather than replacing duplicate text")
		for Expected in [SharedLabel, SharedLabel . " #2", SharedLabel . " #3", SharedLabel . " #4"] {
			Found := 0
			loop DllCall("GetMenuItemCount", "ptr", Built.Handle, "int")
				if _CTC_LabelAt(Built, A_Index - 1) == Expected
					Found += 1
			AssertEqual(1, Found, "each independently expected duplicate label exists exactly once in Win32")
		}
	} finally {
		try {
			if Built is Menu
				_CTC_ReleaseMenu(Built)
		} finally {
			_LLM_Menu := Previous
			LLM_PROFILE_BUILTIN_ORDER := SavedContext["had_order"] ? SavedContext["order"] : unset
			LLM_PROFILE_HOTKEY_LIMIT := SavedContext["had_limit"] ? SavedContext["limit"] : unset
			LLM_TONE_LADDER := SavedContext["had_tone"] ? SavedContext["tone"] : unset
			LLM_PROFILE_LIVE_TRANSLATIONS := SavedContext["had_live"] ? SavedContext["live"] : unset
		}
	}
}
Test("menu_profiles: actual Win32 frame preserves builtin and repeated user labels beyond hotkey hints",
	_LPUL_ActualFrameKeepsDuplicateBuiltinAndUserRows)


_LPUL_FrameRejectsQuotedProviderAuthority() {
	Frame := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_ProfileRows"))
	AssertTrue(_LPUL_FrameSharesLabelCounter(Frame), "the actual executable frame remains the positive control")
	Start := InStr(Frame, "seen_labels := Map()", true)
	Assert(Start > 0, "the counterfeit must move the actual current counter and provider bindings")
	Block := SubStr(Frame, Start, StrLen(Frame) - Start)
	Quoted := "AuditText := " . Chr(39) . "`n(`n" . Block . "`n)" . Chr(39) . "`nreturn []`n"
	Changed := SubStr(Frame, 1, Start - 1) . Quoted . "}"
	AssertFalse(_LPUL_FrameSharesLabelCounter(Changed),
		"quoted continuation data cannot certify an empty unbound profile frame")
	Commented := SubStr(Frame, 1, Start - 1) . "/*`n" . Block . "`n*/`nreturn []`n}"
	AssertFalse(_LPUL_FrameSharesLabelCounter(Commented),
		"commented native bindings cannot supply the frame's executable label counter")
}
Test("menu_profiles: copied quoted and commented bindings cannot certify the native frame",
	_LPUL_FrameRejectsQuotedProviderAuthority)


; Read only the genuine executable module constants through the canonical
; production census. This fixture never copies the native profile policies.
_LPUL_NativeProfileConstant(Name, ArrayValue) {
	Source := _DriverSourceNoComments()
	Code := _DriverMaskNonCode(&Source)
	Pattern := "m)^[ \t]*global[ \t]+" . Name . "[ \t]*:=[ \t]*"
		. (ArrayValue ? "(\[[\s\S]*?\])" : "([0-9]+)[ \t]*$")
	Position := RegExMatch(Source, Pattern, &Found)
	AssertTrue(Position > 0, "the actual native profile constant must exist: " . Name)
	AssertFalse(RegExMatch(Source, Pattern, , Position + StrLen(Found[0])) > 0,
		"the native profile constant must have one genuine declaration: " . Name)
	Offset := InStr(Found[0], Name, true)
	AssertEqual(Name, SubStr(Code, Position + Offset - 1, StrLen(Name)),
		"quoted or commented data cannot initialize a native constant")
	return Found[1]
}
_LPUL_NativeProfileArray(Name) {
	AssertTrue(Name == "LLM_PROFILE_BUILTIN_ORDER" || Name == "LLM_TONE_LADDER"
		|| Name == "LLM_PROFILE_LIVE_TRANSLATIONS", "only actual native profile arrays are fixture dependencies")
	Value := JsonParse(_LPUL_NativeProfileConstant(Name, true))
	AssertTrue(Value is Array && Value.Length > 0, "the genuine native profile dependency is a nonempty array")
	for Id in Value
		AssertTrue(Id is String && Id != "", "the genuine native profile dependency contains actual ids")
	return Value
}
_LPUL_NativeProfileHotkeyLimit() {
	Value := Integer(_LPUL_NativeProfileConstant("LLM_PROFILE_HOTKEY_LIMIT", false))
	AssertEqual(9, Value, "the actual native number-row protocol still owns nine hints")
	return Value
}
