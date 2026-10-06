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


; A template group consumes the established predicate owner and leaves native
; children intact. GetMenuState/GetMenuString observe the actual Win32 row.
_MMRDW_TemplateGroupPolicy() {
	Root := _MR_GetManifestRoot()
	Section := "__group_policy_probe"
	Assert(!Root.Has(Section), "independent temporary group section owns its identity")
	Item := Map("type", "group", "id", "owned_group", "i18n", "tap_hold.picker.hold")
	Root[Section] := [Item]
	Children := [Map("label", "Existing native child", "action", (*) => false)]
	Payload := Map("owned_group", Children)
	Native := Menu()
	try {
		Rows := MenuRenderer_TemplateRows(Section, Map(), Map(), Payload)
		Assert(Rows is Array && Rows.Length == 1, "one actual group row")
		AssertEqual(2, Rows[1].Count, "absent policy retains exact legacy two-field group shape")
		Assert(Rows[1]["items"] == Children, "native child array identity is retained")
		AssertEqual(false, Rows[1]["items"][1]["action"].Call(), "native child refusal is preserved")
		Item["disabled_when"] := ["ready"]
		Item["caption_getter"] := "caption"
		Item["disabled_reason_key"] := "menu.gestures.sensitivity_hint"
		Getters := Map("ready", () => true, "caption", () => "35% $ literal")
		Rows := MenuRenderer_TemplateRows(Section, Map(), Getters, Payload)
		Expected := StrReplace(t("tap_hold.picker.hold"), "%s", "35% $ literal")
		AssertEqual(Expected, Rows[1]["label"], "literal caption passes through existing interpolation owner")
		AssertEqual(2, Rows[1].Count, "enabled group does not invent disabled or reason fields")
		AssertEqual(1, _MR_RenderRows(Native, Rows, Section, 1), "actual renderer consumes enabled native group")
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && !(Flags & 0x3), "actual native group is enabled")
		Native.Delete()
		MenuDispatcher_PruneMenu(Native)
		Getters["ready"] := () => false
		Rows := MenuRenderer_TemplateRows(Section, Map(), Getters, Payload)
		Assert(Rows[1]["disabled"], "false native group getter disables provider data")
		AssertEqual("menu.gestures.sensitivity_hint", Rows[1]["disabled_reason_key"], "declared exact reason receipt reaches existing native owner")
		Assert(Rows[1]["items"] == Children, "disabled group retains actual native child identity")
		Assert(!Rows[1].Has("action"), "no dummy callback is added to a group")
		AssertEqual(1, _MR_RenderRows(Native, Rows, Section, 1), "actual renderer consumes disabled native group")
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x3), "actual Win32 group is disabled")
		Text := Buffer(4096, 0)
		Length := DllCall("GetMenuStringW", "ptr", Native.Handle, "uint", 0,
			"ptr", Text, "int", 2048, "uint", 0x400, "int")
		Assert(Length > 0, "actual native group text is observable")
		AssertEqual(StrReplace(Expected . " — " . _MR_ReasonHead(t("menu.gestures.sensitivity_hint")), "&", "&&"),
			StrGet(Text, Length, "UTF-16"), "native reason decoration is applied exactly once")
	} finally {
		Native.Delete()
		MenuDispatcher_PruneMenu(Native)
		Root.Delete(Section)
	}
}
Test("manifest_menu: real template group preserves native readiness reason and child ownership", _MMRDW_TemplateGroupPolicy)

_MMRDW_TemplateGroupRefusals() {
	Root := _MR_GetManifestRoot()
	Section := "__group_refusal_probe"
	Assert(!Root.Has(Section), "independent refusal section owns its identity")
	Item := Map("type", "group", "id", "owned_group", "i18n", "menu.gestures.mode_single", "disabled_when", ["ready"])
	Root[Section] := [Item]
	Payload := Map("owned_group", [Map("label", "Existing native child")])
	try {
		Missing := MenuRenderer_TemplateRows(Section, Map(), Map(), Payload)
		Assert(Missing[1]["disabled"], "missing declared native group getter fails closed")
		Assert(!Missing[1].Has("disabled_reason_key"), "an undeclared reason is not invented")
		Threw := false
		try MenuRenderer_TemplateRows(Section, Map(), Map("ready", _MMRDW_TemplateGroupThrow), Payload)
		catch as Err {
			Threw := InStr(Err.Message, "group-native-read-refused") > 0
		}
		Assert(Threw, "actual native getter error propagates rather than manufacturing an enabled group")
		Item["platforms"] := ["hs"]
		Item["unavailable"] := "hide"
		Hidden := MenuRenderer_TemplateRows(Section, Map(), Map("ready", _MMRDW_TemplateGroupThrow), Payload)
		Assert(Hidden is Array && Hidden.Length == 0, "hidden group cannot invoke its native getter")
		Item["platforms"] := ["ahk"]
		AssertEqual(false, MenuRenderer_TemplateRows(Section, Map(), Map("ready", () => true), Map()),
			"missing actual group child payload refuses the whole template")
	} finally Root.Delete(Section)
}
_MMRDW_TemplateGroupThrow(*) {
	throw Error("group-native-read-refused")
}
Test("manifest_menu: template group retains getter refusal platform hide and child admission", _MMRDW_TemplateGroupRefusals)
