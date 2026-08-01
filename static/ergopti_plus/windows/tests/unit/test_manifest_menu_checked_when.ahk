; static/ergopti_plus/windows/tests/unit/test_manifest_menu_checked_when.ahk

; ==============================================================================
; MODULE: Declarative checked_when resolver
; DESCRIPTION:
; The first of the manifest capabilities Lot 5 needs: a row's checkmark is
; declared beside the row instead of restated in its handler.
;
; Before this, the three metrics filter handlers each carried their own
; `if MetricsFilters.<field>` line. The manifest described when the row was
; DISABLED but said nothing about when it was CHECKED, so half of each row's
; state lived in the description and half in the code — and only the half in the
; code actually decided anything.
;
; WHY THIS FAILS OPEN WHERE disabled_when FAILS CLOSED:
; A checkmark is an assertion to the user that something is currently on.
; Inventing one when the state cannot be read tells them a privacy filter is
; active when it is not: they stop looking for the setting, and the data they
; believed excluded keeps being recorded. Its sibling fails CLOSED for the same
; underlying reason — in both directions the safe answer is the one that does
; not overstate what is enabled. These tests pin that asymmetry, because
; "make it consistent with disabled_when" is the obvious-looking change that
; would break it.
; ==============================================================================





; ==================================================
; ==================================================
; ======= 1/ The predicate decides the check =======
; ==================================================
; ==================================================

Test("checked_when: all getters truthy checks the row", () => (
	AssertTrue(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "filter_private", Map(
			"metrics_filter_private", () => true
		)),
		"a row whose checked_when getter returns true must be checked"
	)
))

Test("checked_when: a falsy getter leaves the row unchecked", () => (
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "filter_private", Map(
			"metrics_filter_private", () => false
		)),
		"a row whose checked_when getter returns false must not be checked"
	)
))

Test("checked_when: a row that declares none is never checked", () => (
	; keylogger_enabled has disabled_when but no checked_when. It must not
	; inherit a checkmark from the sibling predicate.
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "show_apps", Map()),
		"a row with no checked_when array must resolve to unchecked"
	)
))




; ==========================================================
; ==========================================================
; ======= 2/ Failing OPEN, unlike disabled_when ============
; ==========================================================
; ==========================================================

Test("checked_when: an unknown item id resolves UNCHECKED", () => (
	; The mirror case of test_manifest_menu_resolve_disabled_when_failclosed,
	; and deliberately the opposite answer.
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "_no_such_item_xyz_", Map()),
		"an unknown id must not produce a checkmark asserting state nobody read"
	)
))

Test("checked_when: a missing getter resolves UNCHECKED", () => (
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("metrics_menu", "filter_private", Map()),
		"a declared key with no getter must not produce a checkmark"
	)
))

Test("checked_when: an unknown menu key resolves UNCHECKED", () => (
	AssertFalse(
		MenuRenderer_ResolveCheckedWhen("_no_such_menu_key_", "filter_private", Map()),
		"an unknown menu key must not produce a checkmark"
	)
))




; ================================================
; ================================================
; ======= 3/ The three rows are declared ==========
; ================================================
; ================================================

; The capability is only real if a row uses it. These pin the migration itself:
; each filter row must carry the predicate its handler used to hardcode.

Test("checked_when: the three metrics filters declare their predicate", () => (
	AssertTrue(
		_MMC_DeclaresCheckedWhen("filter_private")
			and _MMC_DeclaresCheckedWhen("filter_secure")
			and _MMC_DeclaresCheckedWhen("filter_sysauth"),
		"each metrics filter row must declare checked_when — without it the handler "
			. "silently stops checking the box and the filter looks off while being on"
	)
))

; Returns true when the named metrics_menu row carries a non-empty checked_when.
_MMC_DeclaresCheckedWhen(ItemId) {
	for Row in _MR_GetMenuDef("metrics_menu") {
		if (_MR_Get(Row, "id") == ItemId) {
			Keys := _MR_Get(Row, "checked_when", 0)
			return (Keys is Array) and Keys.Length > 0
		}
	}
	return false
}
