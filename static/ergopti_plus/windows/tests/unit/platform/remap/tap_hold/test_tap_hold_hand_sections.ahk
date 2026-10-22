; tests/unit/platform/remap/tap_hold/test_tap_hold_hand_sections.ahk

; ==============================================================================
; MODULE: Tap-Hold Keys Listed By Hand
; DESCRIPTION:
; The Tap-Hold submenu lists its keys under « Main gauche (tap/hold) » and
; « Main droite (tap/hold) », with a separator between the two hands. Which
; key goes under which hand is the shared key catalogue's ([tap_hold.catalog]
; in _shared/tap_hold/defaults.toml), read by TapHoldKeyDefs().
;
; ROOT CAUSE ENCODED: _TH_KeyDefs was a hardcoded array claiming to mirror a
; menu-manifest `tap_hold_keys_catalog` that never existed, and this menu had
; one undivided key list with no hand at all. The real manifest is rendered
; here with rows named by key id, so the headers, the separator and the order
; are the ones the tray draws.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Native menu readers =======
; ======================================
; ======================================

; The text of the row at a zero-based position.
_THHS_LabelAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
	Assert(Length >= 0, "GetMenuStringW must read row " . Position)
	Buffer_ := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Buffer_, "int", Length + 1, "uint", MF_BYPOSITION, "int")
	return StrGet(Buffer_, "UTF-16")
}

; Zero-based position of the first row labelled exactly Label, or -1.
_THHS_PositionOf(TargetMenu, Label) {
	loop TrayMenuItemCount(TargetMenu) {
		if !TrayMenuIsSeparatorAt(TargetMenu, A_Index - 1)
				&& _THHS_LabelAt(TargetMenu, A_Index - 1) == Label
			return A_Index - 1
	}
	return -1
}

; Renders the real tap_holds_menu declaration with one inert row per key,
; labelled by the key's id, under the provider of its hand.
_THHS_Render() {
	Inert := (*) => ""
	Providers := Map(
		"tap_hold_keys_left", (*) => _THHS_KeyIdRows("left", Inert),
		"tap_hold_keys_right", (*) => _THHS_KeyIdRows("right", Inert))
	Commands := Map("tapholds_toggle", Inert, "scope_restore", Inert,
		"scope_clear", Inert, "edit_nav_layer", Inert)
	return MenuRenderer_Build("tap_holds_menu", "TapHolds", "", "", Providers, Commands,
		Map("tapholds_enabled", () => false))
}

; One row per key of a hand, labelled by its id.
_THHS_KeyIdRows(Hand, Action) {
	Out := []
	for _, KeyDef in TapHoldKeyDefsOfHand(Hand)
		Out.Push(Map("label", KeyDef["id"], "action", Action))
	return Out
}





; ===========================================
; ===========================================
; ======= 2/ The catalogue's hands ==========
; ===========================================
; ===========================================

_THHS_CatalogueSplitsTheHands() {
	LeftKeys := TapHoldKeyDefsOfHand("left")
	RightKeys := TapHoldKeyDefsOfHand("right")
	AssertEqual(14, TapHoldKeyDefs().Length, "the Windows column of [tap_hold.catalog]")
	AssertEqual(TapHoldKeyDefs().Length, LeftKeys.Length + RightKeys.Length, "every key has a hand")
	AssertEqual("space", LeftKeys[LeftKeys.Length]["id"], "Space ends the left hand")
	AssertEqual("alt_gr", RightKeys[1]["id"], "AltGr opens the right hand")
	for _, KeyDef in TapHoldKeyDefs()
		Assert(InStr(KeyDef["i18n"], "tap_hold.group.") == 1, "key '" . KeyDef["id"] . "' is labelled from the catalogue")
}
Test("tap-holds: the shared key catalogue gives every Windows key a hand (tap-hold-hand-sections)",
	_THHS_CatalogueSplitsTheHands)

_THHS_MenuSeparatesTheHands() {
	Rendered := _THHS_Render()
	try {
		LeftHeader := _THHS_PositionOf(Rendered, MenuSectionTitle(t("menu.tapholds.left_hand_tap_hold")))
		RightHeader := _THHS_PositionOf(Rendered, MenuSectionTitle(t("menu.tapholds.right_hand_tap_hold")))
		Assert(LeftHeader >= 0, "the « Main gauche (tap/hold) » header is drawn")
		Assert(RightHeader > LeftHeader, "the « Main droite (tap/hold) » header follows it")
		SpaceRow := _THHS_PositionOf(Rendered, "space")
		Assert(SpaceRow > LeftHeader && SpaceRow < RightHeader, "Space is listed under the left hand")
		Assert(TrayMenuIsSeparatorAt(Rendered, SpaceRow + 1),
			"the row after the last left-hand key (Space) is a separator")
		AssertEqual(RightHeader, SpaceRow + 2, "the right-hand header follows that separator")
		AssertEqual("alt_gr", _THHS_LabelAt(Rendered, RightHeader + 1),
			"the first right-hand key row is AltGr")
		Assert(_THHS_PositionOf(Rendered, MenuSectionTitle("Tap / Hold")) < 0,
			"no « — Tap / Hold — » header of its own")
	} finally {
		_CTC_ReleaseMenu(Rendered)
	}
}
Test("tap-holds: the submenu separates the left-hand keys from the right-hand keys (tap-hold-hand-sections)",
	_THHS_MenuSeparatesTheHands)

; Actual provider rows must read their caption from the shared declaration.
_THHS_WithNativeFixture(TestFn) {
	Owner := MasterGateState()
	PreviousInitialized := Owner["initialized"]
	Owner["initialized"] := false
	try return _THGT_WithFixture(TestFn)
	finally Owner["initialized"] := PreviousInitialized
}

_THHS_NativeCommandRow(KeyId) {
	for Row in _TH_KeyRows("left") {
		if InStr(Row["label"], t("tap_hold.group." . KeyId) . "  :") == 1
			return Row["items"][1]
	}
	throw Error("Missing actual key provider: " . KeyId)
}

_THHS_NativeCommandStates(TargetPath) {
	global TapHold
	TapHold := Map("keys", Map("caps_lock", Map("tap_action", "copy", "hold_modifier", "ctrl")),
		"inherit_defaults", false)
	Active := _THHS_NativeCommandRow("caps_lock")
	AssertEqual(t("tap_hold.action.disable"), Active["label"], "established Windows caption")
	Assert(!_MR_Get(Active, "disabled", false), "configured key can be made native")
	TapHold := Map("keys", Map(), "inherit_defaults", false)
	Native := _THHS_NativeCommandRow("caps_lock")
	Assert(Native["disabled"], "native key remains disabled")
	AssertEqual(false, Native["action"].Call(), "disabled retained callback cannot write")
	AssertEqual(0, TapHold["keys"].Count, "disabled command does not mutate the owner")
}
Test("tap-holds: the actual native command retains both availability states (tap-hold-key-native)",
	() => _THHS_WithNativeFixture(_THHS_NativeCommandStates))

_THHS_NativeCommandCaption(TargetPath) {
	Definition := _MR_GetMenuDef("tap_hold_key_native_commands")[1]
	Previous := Definition["i18n"]
	try {
		Definition["i18n"] := "menu.shortcuts.title"
		Row := _THHS_NativeCommandRow("caps_lock")
		AssertEqual(t("menu.shortcuts.title"), Row["label"], "actual provider consumes shared caption")
		Assert(!_MR_Get(Row, "disabled", false), "caption mutation retains configured availability")
	} finally Definition["i18n"] := Previous
}
Test("tap-holds: the actual native command consumes its shared caption (tap-hold-key-native)",
	() => _THHS_WithNativeFixture(_THHS_NativeCommandCaption))

_THHS_NativeCommandLeaseRefusal(TargetPath) {
	global TapHold
	Row := _THHS_NativeCommandRow("caps_lock")
	BeforeTap := TapHold["keys"]["caps_lock"]["tap_action"]
	BeforeHold := TapHold["keys"]["caps_lock"]["hold_modifier"]
	Lease := _ConfigWriteLeaseTryAcquire(TargetPath, "tap-hold-key-native-test")
	Assert(Lease is Object, "fixture owns the actual native writer lease")
	try {
		AssertEqual(false, Row["action"].Call(), "actual native writer refuses a competing lease")
		AssertEqual(BeforeTap, TapHold["keys"]["caps_lock"]["tap_action"], "refusal preserves tap")
		AssertEqual(BeforeHold, TapHold["keys"]["caps_lock"]["hold_modifier"], "refusal preserves hold")
		Assert(!FileExist(TargetPath), "refusal cannot publish an absent private file")
	} finally _ConfigWriteLeaseRelease(Lease)
}
Test("tap-holds: the actual native command preserves writer lease refusal (tap-hold-key-native)",
	() => _THHS_WithNativeFixture(_THHS_NativeCommandLeaseRefusal))

; The complete child template owns row order, captions and platform projection.
_THHS_KeyChildren(KeyId) {
	for Row in _TH_KeyRows("left") {
		if InStr(Row["label"], t("tap_hold.group." . KeyId) . "  :") == 1
			return Row["items"]
	}
	throw Error("Missing actual key template: " . KeyId)
}

_THHS_KeyHeadRows(KeyId) {
	Rows := _THHS_KeyChildren(KeyId)
	Assert(Rows.Length > 1 && !Rows[Rows.Length].Has("items")
		&& HasMethod(Rows[Rows.Length].Get("action", 0), "Call"),
		"the existing head must be followed by the genuine Windows delay command row")
	Head := []
	for Index, Row in Rows {
		if Index < Rows.Length
			Head.Push(Row)
	}
	return Head
}

_THHS_KeyHeadOrder(TargetPath) {
	Rows := _THHS_KeyHeadRows("caps_lock")
	AssertEqual(4, Rows.Length, "the original four-row shared head retains its complete order")
	AssertEqual(t("tap_hold.action.disable"), Rows[1]["label"], "original clearing command remains first")
	Assert(Rows[2]["separator"], "declared separator is second")
	AssertEqual(StrReplace(t("tap_hold.picker.tap"), "%s", TapHoldCurrentTapLabel("caps_lock")),
		Rows[3]["label"], "shared tap caption uses the selected native label")
	AssertEqual(StrReplace(t("tap_hold.picker.hold"), "%s", TapHoldCurrentHoldLabel("caps_lock")),
		Rows[4]["label"], "shared hold caption uses the selected native label")
	Assert(Rows[3].Has("action") && !Rows[3].Has("items"), "tap remains the native picker command")
	; The hold opens the shared action picker, never a submenu (2026-10-22).
	Assert(HasMethod(Rows[4].Get("action", 0), "Call") && !Rows[4].Has("items"),
		"hold is the shared picker command")
	Rendered := Menu()
	try {
		; The renderer receipt counts labelled rows; separators still occupy native positions.
		AssertEqual(3, _MR_RenderRows(Rendered, Rows, "tap_hold_key_head_test", 1), "renderer reports all three labelled head rows")
		AssertEqual(4, DllCall("GetMenuItemCount", "ptr", Rendered.Handle, "int"),
			"real native renderer draws the complete four-row declared head")
		AssertEqual(Rows[1]["label"], _THHS_LabelAt(Rendered, 0), "native first caption")
		Assert(TrayMenuIsSeparatorAt(Rendered, 1), "real native separator follows the included command")
		AssertEqual(Rows[3]["label"], _THHS_LabelAt(Rendered, 2), "native tap caption")
		AssertEqual(Rows[4]["label"], _THHS_LabelAt(Rendered, 3), "native hold caption")
	} finally {
		_CTC_ReleaseMenu(Rendered)
	}
}
Test("tap-holds: actual key provider follows complete declared head (tap-hold-key-head)",
	() => _THHS_WithNativeFixture(_THHS_KeyHeadOrder))

_THHS_KeyHeadMutation(TargetPath) {
	Definition := _MR_GetMenuDef("tap_hold_key_head")
	Tap := Definition[3]
	Hold := Definition[4]
	PreviousCaption := Tap["i18n"]
	PreviousGetter := Tap["caption_getter"]
	try {
		Tap["i18n"] := "tap_hold.picker.hold"
		Tap["caption_getter"] := "tap_hold_key_hold_caption"
		Rows := _THHS_KeyChildren("caps_lock")
		AssertEqual(StrReplace(t("tap_hold.picker.hold"), "%s", TapHoldCurrentHoldLabel("caps_lock")),
			Rows[3]["label"], "actual provider reads both shared caption and getter metadata")
		Assert(Rows[3].Has("action") && !Rows[3].Has("items"), "caption changes retain the picker owner")
		Definition[3] := Hold
		Definition[4] := Tap
		Rows := _THHS_KeyChildren("caps_lock")
		AssertEqual(StrReplace(t("tap_hold.picker.hold"), "%s", TapHoldCurrentHoldLabel("caps_lock")),
			Rows[3]["label"], "declaration determines hold-before-tap order")
		Assert(Rows[3].Has("action") && Rows[4].Has("action"), "both rows remain picker commands")
	} finally {
		Tap["i18n"] := PreviousCaption
		Tap["caption_getter"] := PreviousGetter
		Definition[3] := Tap
		Definition[4] := Hold
	}
}
Test("tap-holds: actual key provider reads shared order and caption getter mutations (tap-hold-key-head)",
	() => _THHS_WithNativeFixture(_THHS_KeyHeadMutation))

_THHS_KeyHeadPlatform(TargetPath) {
	Tap := _MR_GetMenuDef("tap_hold_key_head")[3]
	Previous := Tap["platforms"]
	try {
		Tap["platforms"] := ["linux"]
		Rows := _THHS_KeyHeadRows("caps_lock")
		AssertEqual(3, Rows.Length, "only the unavailable tap row is hidden")
		Assert(Rows[2]["separator"], "the shared separator retains its declared position")
		Assert(HasMethod(Rows[3].Get("action", 0), "Call"), "the hold command remains present")
	} finally Tap["platforms"] := Previous
}
Test("tap-holds: actual key provider honors declared platform hiding (tap-hold-key-head)",
	() => _THHS_WithNativeFixture(_THHS_KeyHeadPlatform))

; The maintainer's decision of 2026-10-22: a key's hold opens the shared action
; picker on the hold options, as its tap does, never a submenu of them.
_THHS_HoldOpensSharedPicker(TargetPath) {
	Hold := _THHS_KeyChildren("caps_lock")[4]
	Assert(!Hold.Has("items") && !Hold.Has("submenu"), "the hold row opens no submenu")
	Assert(HasMethod(Hold.Get("action", 0), "Call"), "the hold row is a command")
	Opened := [], Writes := [], Reloads := []
	Capture(Title, Current, OnConfirm, ShowNative, BindingId, Slot) {
		Opened.Push({ Title: Title, Current: Current, OnConfirm: OnConfirm, ShowNative: ShowNative, Slot: Slot })
		return true
	}
	Accept(KeyId, HoldOpt, Dir) {
		Writes.Push(KeyId . ":" . HoldOpt["kind"] . ":" . HoldOpt["id"])
		return 1
	}
	Refuse(KeyId, HoldOpt, Dir) => false
	Reload(Reason, KeyId) {
		Reloads.Push(Reason . ":" . KeyId)
		return 1
	}
	KeyLabel := t("tap_hold.group.caps_lock")
	_TH_OpenHoldPicker("caps_lock", KeyLabel, Capture, Accept, Reload)
	AssertEqual(1, Opened.Length, "the hold opens the shared picker once")
	Picker := Opened[1]
	AssertEqual(t("tap_hold.picker.hold_title_prefix") . KeyLabel, Picker.Title, "titled by the hold and the key")
	AssertEqual(TapHoldCurrentHoldPickId("caps_lock"), Picker.Current, "the current hold is marked")
	AssertFalse(Picker.ShowNative, "the picker's own none row clears the hold")
	Items := Picker.Slot["items"]
	AssertEqual(TapHoldHoldOptions().Length - 1, Items.Length, "every hold option but the none row the picker draws")
	Labels := Map()
	for Item in Items {
		AssertEqual("action", Item.Type)
		Labels[Item.Id] := Item.Label
	}
	AssertEqual(t("tap_hold.hold.nav_layer"), Labels.Get("nav", ""), "the navigation layer is a holdable entry")
	AssertEqual(t("tap_hold.hold.ctrl") . " + " . t("tap_hold.hold.shift"), Labels.Get("ctrl+shift", ""),
		"a modifier combination is a holdable entry")
	AssertFalse(Labels.Has("copy"), "no tap action is offered for a hold")
	AssertFalse(Picker.OnConfirm.Call("copy"), "an action the hold does not offer is refused")
	AssertFalse(_ActionPickerSlotCommitted(Picker.OnConfirm, "copy"), "so the picker stays open")
	AssertEqual(0, Writes.Length, "a refused pick writes nothing")
	AssertEqual(1, Picker.OnConfirm.Call("nav"), "an offered hold is written")
	AssertEqual("caps_lock:layer:nav", Writes[1], "through the hold owner")
	AssertEqual(0, Reloads.Length, "the script reloads only once the picker has closed")
	Picker.Slot["after_close"].Call("nav")
	AssertEqual("hold_set:caps_lock", Reloads[1])
	AssertEqual(1, Picker.OnConfirm.Call("none"), "the none row clears the hold")
	AssertEqual("caps_lock:none:", Writes[2])
	_TH_OpenHoldPicker("caps_lock", KeyLabel, Capture, Refuse, Reload)
	AssertFalse(Opened[2].OnConfirm.Call("shift"), "a refused write keeps the picker open")
	Raised := false
	try ShowActionPicker("t", "none", (*) => 1, false, "", Map("items", []))
	catch ValueError
		Raised := true
	AssertTrue(Raised, "a slot without its after_close step is refused before any window opens")
}
Test("tap-holds: a key's hold opens the shared action picker on the hold options (tap-hold-hold-action-picker)",
	() => _THHS_WithNativeFixture(_THHS_HoldOpensSharedPicker))

_THHS_KeyHeadRefusesBrokenData() {
	Definition := _MR_GetMenuDef("tap_hold_key_head")
	PreviousInclude := Definition[1]["section"]
	PreviousGetter := Definition[3]["caption_getter"]
	Commands := Map("tap_hold_key_native", () => true, "tap_hold_key_tap", () => true,
		"tap_hold_key_hold_action", () => true)
	Getters := Map("tap_hold_key_configured", () => true,
		"tap_hold_key_tap_caption", () => "copy 100%", "tap_hold_key_hold_caption", () => "Ctrl / {}")
	Children := Map()
	try {
		Definition[1]["section"] := "missing_child_template"
		AssertEqual(false, MenuRenderer_TemplateRows("tap_hold_key_head", Commands, Getters, Children),
			"missing include cannot return a partial key head")
		Definition[1]["section"] := "tap_hold_key_head"
		AssertEqual(false, MenuRenderer_TemplateRows("tap_hold_key_head", Commands, Getters, Children),
			"cyclic include cannot recurse forever")
		Definition[1]["section"] := PreviousInclude
		Definition[3]["caption_getter"] := "missing_getter"
		AssertEqual(false, MenuRenderer_TemplateRows("tap_hold_key_head", Commands, Getters, Children),
			"missing caption getter cannot return a partial key head")
		Definition[3]["caption_getter"] := PreviousGetter
		Getters["tap_hold_key_tap_caption"] := 42
		AssertEqual(false, MenuRenderer_TemplateRows("tap_hold_key_head", Commands, Getters, Children),
			"non-callable caption getter cannot return a partial key head")
		Getters["tap_hold_key_tap_caption"] := () => 42
		AssertEqual(false, MenuRenderer_TemplateRows("tap_hold_key_head", Commands, Getters, Children),
			"non-string caption cannot return a partial key head")
		Getters["tap_hold_key_tap_caption"] := () => "copy 100%"
		Assert(MenuRenderer_TemplateRows("tap_hold_key_head", Commands, Getters, Children) is Array,
			"the repaired declaration renders the complete key head")
		Commands.Delete("tap_hold_key_hold_action")
		AssertEqual(false, MenuRenderer_TemplateRows("tap_hold_key_head", Commands, Getters, Children),
			"a missing hold picker command cannot return a partial key head")
	} finally {
		Definition[1]["section"] := PreviousInclude
		Definition[3]["caption_getter"] := PreviousGetter
	}
}
Test("tap-holds: declared key head refuses missing or cyclic data (tap-hold-key-head)",
	_THHS_KeyHeadRefusesBrokenData)

_THHS_KeyDelayVisible(TargetPath) {
	global TapHold
	TapHold["keys"]["caps_lock"]["time_activation_seconds"] := 0.35
	Rows := _THHS_KeyChildren("caps_lock")
	AssertEqual(5, Rows.Length, "Windows exposes the complete head and genuine per-key delay")
	AssertEqual(StrReplace(t("menu.tapholds.key_tap_delay"), "%s", "350 ms"),
		Rows[5]["label"], "caption reads the authoritative inherited/effective per-key duration")
	; The delay row opens the prompt itself: the one-row submenu is retired (2026-10-22).
	Assert(!Rows[5].Has("items") && !Rows[5].Has("submenu"), "the delay row is a command, not a submenu")
	Assert(HasMethod(Rows[5]["action"], "Call"), "clicking the delay row runs the native prompt owner")
	Rendered := Menu()
	try {
		AssertEqual(4, _MR_RenderRows(Rendered, Rows, "tap_hold_key_delay_test", 1),
			"the complete receipt counts four labelled rows and excludes its separator")
		AssertEqual(5, DllCall("GetMenuItemCount", "ptr", Rendered.Handle, "int"),
			"the actual native menu retains all five physical positions")
		AssertEqual(Rows[5]["label"], _THHS_LabelAt(Rendered, 4), "the genuine delay is last")
		Assert(TrayMenuIsSeparatorAt(Rendered, 1), "the original separator remains second")
	} finally {
		_CTC_ReleaseMenu(Rendered)
	}
}
Test("tap-holds: Windows exposes real per-key delay after the original head (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THHS_KeyDelayVisible))

; Exercise the real per-key provider and retained command, not a synthetic wrapper call.
_THHS_KeyDelayProviderContract(TargetPath) {
	Definition := _MR_FindItemById("tap_hold_key_delay_tail", "tap_hold_key_delay")
	Assert(Definition is Map && Definition["type"] == "command", "the declared delay row is a command")
	PreviousCaption := Definition["i18n"]
	PreviousCommand := Definition["id"]
	try {
		for Hand in ["left", "right"]
			AssertEqual(TapHoldKeyDefsOfHand(Hand).Length, _TH_KeyRows(Hand).Length,
				"the actual provider renders every declared physical key without a construction exception")
		Definition["i18n"] := "menu.tapholds.simultaneous_title"
		Rows := _THHS_KeyChildren("caps_lock")
		Prefix := StrSplit(t("menu.tapholds.simultaneous_title"), "%s")[1]
		AssertEqual(Prefix, SubStr(Rows[5]["label"], 1, StrLen(Prefix)),
			"the real delay row consumes its shared command caption")
		Assert(HasMethod(Rows[5]["action"], "Call"),
			"caption mutation retains the actual native delay owner")
		Definition["id"] := "unowned_delay_command"
		AssertEqual(0, _TH_KeyRows("left").Length,
			"a missing native command owner refuses physical key rows rather than publishing a partial child")
	} finally {
		Definition["i18n"] := PreviousCaption
		Definition["id"] := PreviousCommand
	}
	Assert(!FileExist(TargetPath), "building and refusing native rows cannot publish preferences")
}
Test("tap-holds: actual delay provider constructs both hands and refuses unowned commands (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THHS_KeyDelayProviderContract))

_THHS_KeyDelayRetainedOwnerRefusal(TargetPath) {
	global TapHold
	Rows := _THHS_KeyChildren("caps_lock")
	DelayCommand := Rows[5]
	Previous := TapHold
	try {
		TapHold := 0
		AssertEqual(false, DelayCommand["action"].Call(),
			"the retained actual delay callback refuses withdrawn native state before opening its prompt")
		AssertEqual(0, TapHold, "callback refusal cannot rebuild an uninitialized owner")
		Assert(!FileExist(TargetPath), "callback refusal cannot write the private target")
	} finally TapHold := Previous
}
Test("tap-holds: retained actual delay command refuses native owner withdrawal (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THHS_KeyDelayRetainedOwnerRefusal))
