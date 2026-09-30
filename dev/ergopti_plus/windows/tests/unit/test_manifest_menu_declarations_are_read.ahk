; static/ergopti_plus/windows/tests/unit/test_manifest_menu_declarations_are_read.ahk

; ==============================================================================
; MODULE: Regression — manifest declarations that nothing read
; DESCRIPTION:
; Three keys in menu_manifest.json were declared and then ignored, each with a
; copy of the same data living in AutoHotkey source. The manifest is meant to be
; the description of what the user sees, so a key nobody reads is a config that
; lies: editing it moves nothing, and the code copy is the real source.
;
;   * ``i18n_dynamic`` on metrics_menu's shortcut_typing and shortcut_apps rows
;     named the locale key for the label prefix. Zero readers existed anywhere in
;     the repo; _MET_ShortcutTyping and _MET_ShortcutApps each carried their own
;     literal t("menu.metrics.shortcut_prefix").
;   * ``accented_letters_group`` listed four letter_picker ids, while
;     _MR_BuildBuiltinGroup built the submenu from a hardcoded array of the same
;     four paths.
;   * ``modifier_combos_group`` (now key_combinations_group) listed three
;     feature-section paths, while the same builder read them from a
;     _SHORTCUTS_SUBMAP_V1V2 Map in ui/menu/menu_shortcuts.ahk.
;
; None of this was visible as a bug: the menus rendered correctly, because the
; code copy was in sync. The failure mode is the next edit — adding a fourth
; accented letter to the manifest, or a fourth modifier combo, changes nothing
; at all and there is no error to read.
;
; These tests pin the reader side. They fail if a builder goes back to owning
; the data, because the manifest section is then no longer what drives the row.
; ==============================================================================




; =====================================================
; =====================================================
; ======= 1/ i18n_dynamic reaches the handler =========
; =====================================================
; =====================================================

Test("manifest_menu: i18n_dynamic is read from the manifest, not the handler", () => (
	; The exact key the two metrics handlers now prefix their runtime label with.
	; A handler holding its own literal would leave this accessor unused and the
	; manifest declaration inert — which is the state this replaced.
	AssertEqual(
		"menu.metrics.shortcut_prefix",
		MenuRenderer_I18nDynamic("metrics_menu", "shortcut_typing"),
		"shortcut_typing must take its label prefix key from the manifest"
	)
))

Test("manifest_menu: the second i18n_dynamic row resolves too", () => (
	AssertEqual(
		"menu.metrics.shortcut_prefix",
		MenuRenderer_I18nDynamic("metrics_menu", "shortcut_apps"),
		"shortcut_apps must take its label prefix key from the manifest"
	)
))

Test("manifest_menu: an unknown item yields no i18n_dynamic key", () => (
	; Fails visibly rather than inventing a key: the caller is about to build a
	; user-visible label out of it.
	AssertEqual(
		"",
		MenuRenderer_I18nDynamic("metrics_menu", "_no_such_item_xyz_"),
		"an unknown item id must not resolve an i18n_dynamic key"
	)
))

Test("manifest_menu: a row with no i18n_dynamic declaration yields empty", () => (
	; show_apps is a static-label row: it declares i18n, not i18n_dynamic.
	AssertEqual(
		"",
		MenuRenderer_I18nDynamic("metrics_menu", "show_apps"),
		"a statically-labelled row declares no i18n_dynamic key"
	)
))




; ==========================================================
; ==========================================================
; ======= 2/ The built-in groups read their section ========
; ==========================================================
; ==========================================================

; _MR_BuildBuiltinGroup now resolves ``<id>_group`` and has no fallback data of
; its own, so an empty or renamed section renders an EMPTY submenu rather than
; the wrong one. That is the failure these two pin.

Test("manifest_menu: accented_letters_group carries the letter rows", () => (
	; The ids, not just the count — the builder turns each into a
	; "shortcuts.<id>" picker, so a renamed id points at a letter that does not
	; exist and the row goes missing while the count still looks right. A first
	; version of this test asserted only Length == 4 and a probe that renamed a
	; row passed it.
	AssertEqual(
		"e_grave,e_circ,e_acute,a_grave",
		_MM_RowValues("accented_letters_group", "id"),
		"the accented-letters submenu is built from these ids, in this order"
	)
))

Test("manifest_menu: every accented-letter row names a picker id", () => (
	AssertTrue(
		_MM_EveryRowHasKey("accented_letters_group", "id"),
		"each letter_picker row needs an id; the builder skips rows without one"
	)
))

Test("manifest_menu: key_combinations_group carries the three Windows combination families", () => (
	; The families moved from the retired modifier_combos_group into the
	; « Combinaisons de touches » group, after its own first-row switch; the
	; renderer expands each feature row naming a section and a group_label.
	AssertEqual(
		"shortcuts.alt_gr_lalt,shortcuts.alt_gr_caps_lock,shortcuts.lalt_caps_lock",
		_MM_AhkFeatureRowValues("key_combinations_group", "path"),
		"the key-combinations submenu expands the features under exactly these sections"
	)
))

Test("manifest_menu: every key-combination family names its submenu label", () => (
	; group_label is what the sub-submenu is titled with. It used to be the KEY of
	; the _SHORTCUTS_SUBMAP_V1V2 Map, which is why the manifest section could not
	; drive the render on its own and stayed decorative.
	AssertEqual(
		"AltGrLAlt,AltGrCapsLock,LAltCapsLock",
		_MM_AhkFeatureRowValues("key_combinations_group", "group_label"),
		"a row without group_label would render no family submenu"
	)
))

Test("manifest_menu: the key-combinations group opens with its own switch", () => (
	AssertEqual(
		"key_combinations_toggle",
		_MR_Get(_MR_GetMenuDef("key_combinations_group")[1], "id"),
		"the first row of the group is its KeyCombinations switch"
	)
))

; Joins one field of the Windows ``feature`` rows of a manifest section, in order.
_MM_AhkFeatureRowValues(SectionKey, Key) {
	Joined := ""
	for Row in _MR_GetMenuDef(SectionKey) {
		if (_MR_Get(Row, "type") != "feature" or !_MR_IsForAhk(Row))
			continue
		Joined .= (Joined == "" ? "" : ",") . _MR_Get(Row, Key)
	}
	return Joined
}





; ===============================================
; ===============================================
; ======= 3/ Shared row-inspection helper =======
; ===============================================
; ===============================================

; Returns true when every row of the named manifest section carries a non-empty
; value under ``Key``. Declared after use — AHK hoists function definitions, so
; the order here is presentation, not dependency.
_MM_EveryRowHasKey(SectionKey, Key) {
	Rows := _MR_GetMenuDef(SectionKey)
	if (Rows.Length == 0) {
		return false
	}
	for Row in Rows {
		if (_MR_Get(Row, Key) == "") {
			return false
		}
	}
	return true
}

; Joins one field of every row in a manifest section, in order. Comparing the
; joined string pins the values AND their order in a single AssertEqual, which a
; length check does not.
_MM_RowValues(SectionKey, Key) {
	Out := []
	for Row in _MR_GetMenuDef(SectionKey) {
		Out.Push(_MR_Get(Row, Key))
	}
	Joined := ""
	for Value in Out {
		Joined .= (Joined == "" ? "" : ",") . Value
	}
	return Joined
}





; ================================================
; ================================================
; ======= Rows declared greyed or hidden =========
; ================================================
; ================================================

; The text of a native menu row at a zero-based position.
_MUR_LabelAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
	Assert(Length >= 0, "GetMenuStringW must read row " . Position)
	Buffer_ := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Buffer_, "int", Length + 1, "uint", MF_BYPOSITION, "int")
	return StrGet(Buffer_, "UTF-16")
}

; The maintainer's rule of 2026-09-30: a row declared `unavailable = "grey"`
; that this platform lacks is drawn disabled, labelled with its label and the
; short head of its reason; one declared "hide" is not drawn.
_MUR_GreyedAndHiddenRows() {
	static KEY := "_test_unavailable_menu", MF_BYPOSITION := 0x400, GREYED := 0x3
	Root := _MR_GetManifestRoot()
	Assert(Root is Map, "the shared menu manifest must load")
	Reason := "platform_reason.shortcuts_restore_is_composed_on_macos"
	Root[KEY] := [
		Map("type", "command", "id", "ported", "i18n", "common.restore_recommended"),
		Map("type", "command", "id", "not_yet", "i18n", "common.clear_to_system",
			"platforms", ["hs", "linux"], "unavailable", "grey", "reason_key", Reason),
		Map("type", "command", "id", "not_here", "i18n", "menu.gestures.enable",
			"platforms", ["hs"], "unavailable", "hide")]
	try {
		Rendered := MenuRenderer_Build(KEY, "Test", "", "", "",
			Map("ported", (*) => 0, "not_yet", (*) => 0, "not_here", (*) => 0))
	} finally Root.Delete(KEY)
	try {
		AssertEqual(2, TrayMenuItemCount(Rendered), "the ported row and the greyed stand-in, nothing hidden")
		AssertEqual(t("common.restore_recommended"), _MUR_LabelAt(Rendered, 0))
		Head := _MR_ReasonHead(t(Reason))
		Assert(Head != "" && !InStr(Head, ":"), "the stand-in carries the short head of its reason")
		AssertEqual(t("common.clear_to_system") . " — " . Head, _MUR_LabelAt(Rendered, 1))
		State := DllCall("GetMenuState", "ptr", Rendered.Handle, "uint", 1, "uint", MF_BYPOSITION, "uint")
		Assert((State & GREYED) != 0, "the stand-in is disabled")
	} finally {
		Rendered.Delete()
		MenuDispatcher_PruneMenu(Rendered)
	}
	AssertEqual("Not on macOS yet", _MR_ReasonHead("Not on macOS yet: its key combinations"))
	AssertEqual("暂不适用于 macOS", _MR_ReasonHead("暂不适用于 macOS：在"))
	AssertEqual("Catalogue reload — Linux only", _MR_ReasonHead("Catalogue reload — Linux only"))
}
Test("menu: a greyed row is drawn disabled with its reason, a hidden one is not (menu-unavailable-rows)",
	_MUR_GreyedAndHiddenRows)
