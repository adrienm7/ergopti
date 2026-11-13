; static/ergopti_plus/windows/tests/unit/menu/test_category_off_rule.ahk

; ==============================================================================
; MODULE: The Category-Off Rule on Built Windows Menus
; DESCRIPTION:
; While a category is off, its submenu keeps only the row that turns it on and
; the rows the manifest flags `readable_when_off`; every other row is greyed
; with the shared reason. With the category on, the menu is as built. Every
; gated menu of the manifest is rendered through the real renderer, its driver
; rows replaced by clickable probes at the same position (the method of
; test_manifest_menu_no_double_separator.ahk), and the two builders the harness
; can run are rendered for real.
; ==============================================================================

_MCO_REASON_KEY() => "menu.category_off_reason"

; The native rows of a built menu: { label, greyed }, separators left out.
_MCO_Rows(TargetMenu) {
	Rows := []
	Handle := TargetMenu.Handle
	loop TrayMenuItemCount(TargetMenu) {
		Label := TrayMenuHandleItemText(Handle, A_Index - 1)
		if Label == ""
			continue
		Rows.Push(Map("label", Label, "greyed", (TrayMenuHandleItemState(Handle, A_Index - 1) & 1) != 0))
	}
	return Rows
}

; Every menu holding an enable row, with that row.
_MCO_GatedMenus() {
	Gated := Map()
	for Key, Value in _MR_GetManifestRoot() {
		if !(Value is Array)
			continue
		for Item in Value {
			if (Item is Map) && Item.Has("submenu_off_reason_key")
				Gated[Key] := Item
		}
	}
	return Gated
}

; Renders one gated menu with its enable row reading off or on.
; @returns {Menu} The built menu.
_MCO_BuildProbe(Key, Enable, Off) {
	static PROBE_KEY := "_test_category_off_probe"
	Root := _MR_GetManifestRoot()
	Counter := 0
	Probe := _MMNDS_ProbeDeclaration(Root[Key], &Counter)
	Providers := Map(), Commands := Map(), Getters := Map()
	for Item in Probe {
		Id := _MR_Get(Item, "id")
		if Id != "" {
			Providers[Id] := ((L) => () => [Map("label", L, "action", (*) => 0)])("Probe " . Id)
			Commands[_MR_Get(Item, "command") != "" ? _MR_Get(Item, "command") : Id] := (*) => 0
		}
		for Field in ["checked_when", "disabled_when"] {
			for StateKey in _MR_Get(Item, Field, [])
				Getters[StateKey] := () => true
		}
		if _MR_Get(Item, "type") == "choice"
			Getters[Item["path"]] := () => ""
	}
	if _MR_Get(Enable, "type") == "toggle" {
		for StateKey in Enable["checked_when"]
			Getters[StateKey] := ((Value) => () => Value)(!Off)
	} else {
		Getters[Enable["path"]] := ((Value) => () => Value)(Off ? Enable["submenu_off_value"] : "auto")
	}
	Root[PROBE_KEY] := Probe
	try return MenuRenderer_Build(PROBE_KEY, "Layout", Map(), "", Providers, Commands, Getters)
	finally Root.Delete(PROBE_KEY)
}

; The label each live row of a gated menu starts with.
_MCO_LivePrefixes(Key, Enable) {
	Live := [t(Enable["i18n"])]
	if _MR_Get(Enable, "show_current_choice", false)
		Live := [StrSplit(t(Enable["i18n"]), "{")[1]]
	for Item in _MR_GetManifestRoot()[Key] {
		if _MR_Get(Item, "readable_when_off", false)
			Live.Push(t(Item["i18n"]))
	}
	return Live
}

_MCO_StartsWithAny(Label, Prefixes) {
	for Prefix in Prefixes {
		if InStr(Label, Prefix) == 1
			return true
	}
	return false
}

_MCO_ProbesFollowTheRule() {
	Gated := _MCO_GatedMenus()
	Assert(Gated.Count == 8, "the eight top-level categories are gated, got " . Gated.Count)
	Head := _MR_ReasonHead(t(_MCO_REASON_KEY()))
	for Key, Enable in Gated {
		Live := _MCO_LivePrefixes(Key, Enable)
		Built := _MCO_BuildProbe(Key, Enable, true)
		Clickable := 0
		for Row in _MCO_Rows(Built) {
			if _MCO_StartsWithAny(Row["label"], Live) {
				Assert(!Row["greyed"], Key . ": a live row stays clickable while off: " . Row["label"])
				Clickable++
			} else {
				Assert(Row["greyed"], Key . ": greyed while off: " . Row["label"])
			}
		}
		AssertEqual(Live.Length, Clickable, Key . ": the enable row and the reader rows stay live")
		ReasonRows := 0
		for Row in _MCO_Rows(_MCO_BuildProbe(Key, Enable, false)) {
			Assert(!InStr(Row["label"], Head), Key . ": no reason with the category on: " . Row["label"])
			ReasonRows += !Row["greyed"]
		}
		Assert(ReasonRows > Live.Length, Key . ": the rows come back with the category on")
	}
}
Test("menu: a category off greys its submenu but the enable and reader rows (category-off-rule)",
	_MCO_ProbesFollowTheRule)

_MCO_ProbeRowsNameTheReason() {
	Gated := _MCO_GatedMenus()
	Head := _MR_ReasonHead(t(_MCO_REASON_KEY()))
	Rows := _MCO_Rows(_MCO_BuildProbe("hotstrings_menu", Gated["hotstrings_menu"], true))
	Found := false
	for Row in Rows {
		if Row["label"] == t("common.restore_recommended") . " — " . Head
			Found := true
	}
	Assert(Found, "a greyed row names the reason, like every greyed row")
}
Test("menu: a greyed row of an off category names the reason (category-off-rule)",
	_MCO_ProbeRowsNameTheReason)

; The real Metrics builder: the maintainer's reported rows, and the two readers.
_MCO_RealMetricsMenu() {
	global MetricsShortcuts
	Saved := MetricsShortcuts.enabled
	Live := [t("menu.metrics.enable"), t("menu.metrics.show_typing"), t("menu.metrics.show_apps")]
	try {
		MetricsShortcuts.enabled := false
		Clickable := 0
		for Row in _MCO_Rows(BuildMetricsMenu()) {
			if _MCO_StartsWithAny(Row["label"], Live) {
				Assert(!Row["greyed"], "live with metrics off: " . Row["label"])
				Clickable++
			} else {
				Assert(Row["greyed"], "greyed with metrics off: " . Row["label"])
			}
		}
		AssertEqual(Live.Length, Clickable, "the switch and the two readers")
		MetricsShortcuts.enabled := true
		Found := false
		for Row in _MCO_Rows(BuildMetricsMenu()) {
			if Row["label"] == t("menu.metrics.reset_session")
				Found := !Row["greyed"]
		}
		Assert(Found, "the session reset is back with metrics on")
	} finally {
		MetricsShortcuts.enabled := Saved
	}
}
Test("menu: the real Metrics menu follows the category-off rule (category-off-rule)", _MCO_RealMetricsMenu)

; The real Gestures builder: no row but the switch is live while off.
_MCO_RealGesturesMenu() {
	global Features
	Saved := Features["gestures"]["enabled"]
	Label := t("menu.gestures.enable")
	try {
		Features["gestures"]["enabled"] := false
		for Row in _MCO_Rows(BuildGesturesMenu())
			AssertEqual(Row["label"] != Label, Row["greyed"], "with gestures off: " . Row["label"])
	} finally {
		Features["gestures"]["enabled"] := Saved
	}
}
Test("menu: the real Gestures menu follows the category-off rule (category-off-rule)", _MCO_RealGesturesMenu)
