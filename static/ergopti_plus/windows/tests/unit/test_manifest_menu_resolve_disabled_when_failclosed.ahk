; static/ergopti_plus/windows/tests/unit/test_manifest_menu_resolve_disabled_when_failclosed.ahk

; ==============================================================================
; MODULE: Regression — MenuRenderer_ResolveDisabledWhen failed OPEN on a lookup miss
; DESCRIPTION:
; AHK twin of the macOS guard
; tests/unit/lib/test_manifest_menu_resolve_disabled_when_failclosed.lua.
;
; MenuRenderer_ResolveDisabledWhen(MenuKey, ItemId, Getters) returned false
; (= enabled) whenever _MR_FindItemById could not locate ItemId in MenuKey's
; array, with no log. That contradicted the function's own docstring ("treated as
; disabled so the mismatch fails loud") and the sibling getter-mismatch branch a
; few lines below, which correctly fails CLOSED.
;
; The macOS side was fixed and guarded; the AHK sibling was never touched. This is
; the classic missed-sibling shape, and it lands on a security-sensitive surface:
; the Windows metrics menu gates its privacy toggles through this resolver, so a
; typo'd or drifted manifest id rendered a keylogger-gated item as
; always-enabled.
;
; The tests below pass an id that exists in no manifest array and assert the item
; renders DISABLED. They fail before the fix (returned false) and pass after.
; ==============================================================================




; ============================================
; ============================================
; ======= 1/ Lookup miss fails closed ========
; ============================================
; ============================================

Test("manifest_menu: unknown item id in a real menu key fails CLOSED", () => (
	; metrics_menu exists in the manifest; this id does not. The resolver must
	; treat the drift as disabled rather than silently un-gating the item.
	AssertTrue(
		MenuRenderer_ResolveDisabledWhen("metrics_menu", "_no_such_item_xyz_", Map()),
		"an unknown item id must resolve to disabled (fail closed)"
	)
))

Test("manifest_menu: unknown menu key also fails CLOSED", () => (
	AssertTrue(
		MenuRenderer_ResolveDisabledWhen("_no_such_menu_key_", "_no_such_item_xyz_", Map()),
		"an unknown menu key must resolve to disabled (fail closed)"
	)
))




; ==================================================
; ==================================================
; ======= 2/ The happy paths still behave ==========
; ==================================================
; ==================================================

Test("manifest_menu: a real item with no disabled_when stays enabled", () => (
	; Guards against over-correcting: fail-closed must apply to the lookup miss
	; only, never to a legitimately ungated item.
	AssertFalse(
		MenuRenderer_ResolveDisabledWhen(_MMRDW_UngatedPair()[1], _MMRDW_UngatedPair()[2], Map()),
		"an existing item without disabled_when must stay enabled"
	)
))




; ==========================================
; ==========================================
; ======= 3/ Helpers =======================
; ==========================================
; ==========================================

; Returns [MenuKey, ItemId] for the first manifest item that declares no
; disabled_when. Derived from the manifest rather than hardcoded, for two reasons:
; renaming an item cannot turn this test into a vacuous pass on a missing id
; (which the fail-closed behaviour under test would then mask), and the search is
; not pinned to one menu — every id-bearing row of metrics_menu happens to be
; gated, which is what made the first version of this helper throw.
_MMRDW_UngatedPair() {
	static Cached := false
	if (Cached != false)
		return Cached

	Root := _MR_GetManifestRoot()
	if !(Root is Map)
		throw Error("menu manifest unavailable — cannot derive an ungated item")

	for Key, Arr in Root {
		if !(Arr is Array)
			continue
		for Item in Arr {
			if !(Item is Map)
				continue
			Id := _MR_Get(Item, "id", "")
			if (Id == "")
				continue
			Keys := _MR_Get(Item, "disabled_when", 0)
			if !(Keys is Array) or Keys.Length == 0 {
				Cached := [Key, Id]
				return Cached
			}
		}
	}
	throw Error("no manifest item lacks disabled_when — this test's premise is stale, fix the test")
}
