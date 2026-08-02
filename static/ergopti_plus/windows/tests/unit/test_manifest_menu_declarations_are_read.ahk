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
;   * ``modifier_combos_group`` listed three feature-section paths, while the
;     same builder read them from a _SHORTCUTS_SUBMAP_V1V2 Map in
;     ui/menu/menu_shortcuts.ahk.
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

Test("manifest_menu: modifier_combos_group carries the three combos", () => (
	AssertEqual(
		"shortcuts.alt_gr_lalt,shortcuts.alt_gr_caps_lock,shortcuts.lalt_caps_lock",
		_MM_RowValues("modifier_combos_group", "path"),
		"the modifier-combos submenu expands the features under exactly these sections"
	)
))

Test("manifest_menu: every modifier-combo row names its section path", () => (
	AssertTrue(
		_MM_EveryRowHasKey("modifier_combos_group", "path"),
		"each row expands the features under its path; a row without one is skipped"
	)
))

Test("manifest_menu: every modifier-combo row names its submenu label", () => (
	; group_label is what the sub-submenu is titled with. It used to be the KEY of
	; the _SHORTCUTS_SUBMAP_V1V2 Map, which is why the manifest section could not
	; drive the render on its own and stayed decorative.
	AssertTrue(
		_MM_EveryRowHasKey("modifier_combos_group", "group_label"),
		"a row without group_label is skipped — the submenu would silently lose a combo"
	)
))





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
