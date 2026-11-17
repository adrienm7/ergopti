; tests/unit/gestures/engine/test_menu_status.ahk

; ==============================================================================
; MODULE: Gesture Menu Boundary and Availability
; DESCRIPTION:
; The gestures menu groups its slots under one declared header per finger
; count, consumes the current declared order and refuses an effect-bearing
; boundary. Each slot row
; is greyed out, with its reason in the label, unless the Windows touchpad
; settings send Ergopti's shortcut for it (assigned / not assigned / key
; missing / unreadable). The retired status submenu stays absent, and the
; « Infos… » row opens the Windows reason in a native message box.
; ==============================================================================

#Requires AutoHotkey v2.0





; A registry reader answering what a fully assigned touchpad holds: every value
; of every slot, taken from the generated table the writer itself uses.
; @return {Func} fn(Name) returning the assigned value or "".
_GSS_FullReader() {
	global GESTURE_REG_ACTIONS, GESTURE_REG_KEY_PARAMS_NAMES, GESTURE_REG_KEY_PARAMS
	global GESTURE_REG_ENABLE_NAMES, GESTURE_REG_CUSTOM_TAP_NAMES, GESTURE_REG_FAMILY_ENABLES
	global GESTURE_REG_CUSTOM_VALUE, GESTURE_REG_CUSTOM_TAP_VALUE
	Values := Map()
	for Slot in GESTURE_REG_ACTIONS {
		Values[GESTURE_REG_FAMILY_ENABLES[Slot]] := GESTURE_REG_CUSTOM_VALUE
		Values[GESTURE_REG_ACTIONS[Slot]] := GESTURE_REG_CUSTOM_VALUE
		Values[GESTURE_REG_KEY_PARAMS_NAMES[Slot]] := GESTURE_REG_KEY_PARAMS[Slot]
		if GESTURE_REG_ENABLE_NAMES.Has(Slot)
			Values[GESTURE_REG_ENABLE_NAMES[Slot]] := GESTURE_REG_CUSTOM_VALUE
		if GESTURE_REG_CUSTOM_TAP_NAMES.Has(Slot)
			Values[GESTURE_REG_CUSTOM_TAP_NAMES[Slot]] := GESTURE_REG_CUSTOM_TAP_VALUE
	}
	return (Name) => Values.Get(Name, "")
}

; The independent three-slot vector mixes the two finger counts out of order.
_GTB_WithSlots(Callback) {
	global GESTURE_SLOTS, GestureAssignments, Features
	PreviousSlots := GESTURE_SLOTS, PreviousAssignments := GestureAssignments, PreviousFeatures := Features
	try {
		GESTURE_SLOTS := ["swipe_3_up", "tap_4", "tap_3"]
		GestureAssignments := Map("swipe_3_up", "none", "tap_4", "none", "tap_3", "none")
		Features := Map("gestures", Map("enabled", true))
		return Callback.Call()
	} finally {
		GESTURE_SLOTS := PreviousSlots, GestureAssignments := PreviousAssignments, Features := PreviousFeatures
	}
}

_GTB_Owner() {
	Owner := _MR_FindItemById("gestures_menu", "gesture_slots_ahk")
	Assert(Owner is Map, "the actual flat Windows provider must be declared")
	return Owner
}

; The finger groups belong to macOS: a Windows handler for one is the drift the
; renderer logs at every boot, for a row this driver can never draw.
_GTB_NoHandlerForFilteredFingerGroups() {
	Build := _DriverFuncBody("BuildGesturesMenu")
	Assert(Build != "", "the gestures menu builder is found")
	for Id in ["gesture_slots_2", "gesture_slots_3", "gesture_slots_4", "gesture_slots_5"]
		AssertEqual(0, InStr(Build, Id), Id . " has no Windows handler")
}
Test("gestures menu: no handler for a row the platform filter drops (gesture-slots-drift)",
	_GTB_NoHandlerForFilteredFingerGroups)

; Each slot row at its position: the slot name leads, its picker is the action.
_GTB_AssertSlotRows(Rows, ExpectedLength, Positions) {
	Assert(Rows is Array)
	AssertEqual(ExpectedLength, Rows.Length)
	for Pair in Positions {
		Row := Rows[Pair[1]]
		AssertTrue(InStr(Row["label"], LabelValue(t("gesture.slots." . Pair[2]), "")) == 1, Pair[2] . " at " . Pair[1])
		Assert(Row["action"] is Func, "the existing slot action remains its native callback")
		AssertFalse(Row["disabled"])
	}
}

; A finger-count header row: the shared section frame around its title, inert.
_GTB_AssertHeader(Row, Fingers) {
	AssertEqual(MenuSectionTitle(t("menu.gestures.header_fingers_" . Fingers)), Row["label"])
	AssertTrue(Row["disabled"])
	AssertFalse(Row.Has("action"), "a section header has no click owner")
}

; The declared templates of the Windows list: a bare boundary and one header
; per finger count the Precision Touchpad reports (three and four).
_GTB_ValidStatus() {
	return Map("finger_group_boundary", [Map("type", "---")],
		"fingers_3", [Map("type", "section_header", "i18n", "menu.gestures.header_fingers_3")],
		"fingers_4", [Map("type", "section_header", "i18n", "menu.gestures.header_fingers_4")])
}

_GTB_DeclaredGroups() {
	_GTB_WithSlots(() => _GTB_DeclaredGroupsInner())
}
_GTB_DeclaredGroupsInner() {
	Owner := _GTB_Owner()
	Status := Owner.Get("status_rows", false)
	Assert(Status is Map)
	for Name, Expected in _GTB_ValidStatus() {
		Assert(Status.Has(Name), "the list declares " . Name)
		AssertEqual(1, Status[Name].Length)
		for Field, Value in Expected[1]
			AssertEqual(Value, Status[Name][1][Field], Name . "." . Field)
		AssertEqual(Expected[1].Count, Status[Name][1].Count, Name . " carries no other field")
	}
	; swipe_3_up, tap_4, tap_3 are grouped: three fingers first, in slot order.
	Rows := _GES_SlotRows(_GSS_FullReader())
	_GTB_AssertSlotRows(Rows, 6, [[2, "swipe_3_up"], [3, "tap_3"], [6, "tap_4"]])
	_GTB_AssertHeader(Rows[1], 3)
	AssertTrue(Rows[4]["separator"])
	AssertFalse(Rows[4].Has("action"), "a fixed separator has no click owner")
	_GTB_AssertHeader(Rows[5], 4)
	Native := Menu()
	try {
		AssertEqual(5, _MR_RenderRows(Native, Rows, "gesture_slots_ahk", 1), "the renderer receipt counts named rows only")
		AssertEqual(6, DllCall("user32\GetMenuItemCount", "Ptr", Native.Handle, "Int"))
		Flags := DllCall("user32\GetMenuState", "Ptr", Native.Handle, "UInt", 3, "UInt", 0x400, "UInt")
		Assert(Flags != 0xFFFFFFFF, "GetMenuState must acknowledge the actual separator position")
		AssertTrue((Flags & 0x800) != 0, "the actual Win32 item between the two groups is a separator")
		AssertEqual(Rows[5]["label"], _CTC_LabelAt(Native, 4), "the four-finger header follows the separator")
		Flags := DllCall("user32\GetMenuState", "Ptr", Native.Handle, "UInt", 0, "UInt", 0x400, "UInt")
		AssertTrue((Flags & 3) != 0, "the three-finger header is actually disabled")
	} finally _CTC_ReleaseMenu(Native)
}
Test("Gestures menu: the provider groups its slots under one header per finger count (gesture-finger-headers)",
	_GTB_DeclaredGroups)

_GTB_PublishedBoundary() {
	_GTB_WithSlots(() => _GTB_PublishedBoundaryInner())
}
_GTB_PublishedBoundaryInner() {
	Owner := _GTB_Owner(), HadStatus := Owner.Has("status_rows"), Previous := Owner.Get("status_rows", false)
	try {
		Status := _GTB_ValidStatus()
		Status["finger_group_boundary"] := [Map("type", "label", "i18n", "common.restore_recommended"), Map("type", "---")]
		Owner["status_rows"] := Status
		Rows := _GES_SlotRows(_GSS_FullReader())
		_GTB_AssertSlotRows(Rows, 7, [[2, "swipe_3_up"], [3, "tap_3"], [7, "tap_4"]])
		AssertEqual(t("common.restore_recommended"), Rows[4]["label"])
		AssertTrue(Rows[4]["disabled"])
		AssertFalse(Rows[4].Has("action"))
		AssertTrue(Rows[5]["separator"])
		AssertFalse(Rows[5].Has("action"))
		Owner["status_rows"]["finger_group_boundary"][1]["i18n"] := "common.clear_to_system"
		AssertEqual(t("common.restore_recommended"), Rows[4]["label"], "held materialized data is detached from later source mutation")
		AssertEqual(t("common.clear_to_system"), _GES_SlotRows(_GSS_FullReader())[4]["label"], "a fresh native provider consumes current shared source")
		Owner.Delete("status_rows")
		AssertEqual(0, _GES_SlotRows(_GSS_FullReader()).Length, "a missing required boundary refuses a rebuilt provider")
		Native := Menu()
		try {
			AssertEqual(6, _MR_RenderRows(Native, Rows, "gesture_slots_ahk", 1), "the renderer receipt counts the headers, the inert label and slots")
			AssertEqual(7, DllCall("user32\GetMenuItemCount", "Ptr", Native.Handle, "Int"))
			AssertEqual(t("common.restore_recommended"), _CTC_LabelAt(Native, 3))
			Flags := DllCall("user32\GetMenuState", "Ptr", Native.Handle, "UInt", 3, "UInt", 0x400, "UInt")
			Assert(Flags != 0xFFFFFFFF, "GetMenuState must acknowledge the actual held-label position")
			AssertTrue((Flags & 3) != 0, "the held inert label remains actually disabled")
		} finally _CTC_ReleaseMenu(Native)
	} finally {
		if HadStatus
			Owner["status_rows"] := Previous
		else if Owner.Has("status_rows")
			Owner.Delete("status_rows")
	}
}
Test("Gestures menu: current declared boundary order is consumed and held inert data is detached", _GTB_PublishedBoundary)

_GTB_RefusedBoundary() {
	_GTB_WithSlots(() => _GTB_RefusedBoundaryInner())
}
_GTB_RefusedBoundaryInner() {
	global GESTURE_SLOTS, GestureAssignments, Features
	Owner := _GTB_Owner(), HadStatus := Owner.Has("status_rows"), Previous := Owner.Get("status_rows", false)
	Assignments := GestureAssignments, FeatureOwner := Features
	Invalids := [false, Map()]
	for Name, Bad in Map("finger_group_boundary", [], "fingers_4", false) {
		Status := _GTB_ValidStatus()
		if Bad is Array
			Status[Name] := Bad
		else
			Status.Delete(Name)
		Invalids.Push(Status)
	}
	for Bad in [[Map("type", "command", "id", "foreign_action")], [Map("type", "---", "action", (*) => true)],
		[Map("type", "label", "i18n", "common.restore_recommended", "checked_when", ["foreign_state"])]] {
		Status := _GTB_ValidStatus()
		Status["finger_group_boundary"] := Bad
		Invalids.Push(Status)
	}
	try {
		for Invalid in Invalids {
			Owner["status_rows"] := Invalid
			AssertEqual(0, _GES_SlotRows(_GSS_FullReader()).Length, "missing, empty or effect-bearing status cannot publish a partial slot list")
			AssertTrue(GestureAssignments == Assignments)
			AssertEqual("none", GestureAssignments["tap_4"])
			AssertTrue(Features == FeatureOwner)
			AssertTrue(Features["gestures"]["enabled"])
		}
		Owner["status_rows"] := _GTB_ValidStatus()
		GESTURE_SLOTS := ["swipe_3_up", "tap_3"]
		Rows := _GES_SlotRows(_GSS_FullReader())
		AssertEqual(3, Rows.Length, "one group needs its header and no boundary or invented separator")
		_GTB_AssertHeader(Rows[1], 3)
		for Row in Rows
			AssertFalse(Row.Get("separator", false))
	} finally {
		if HadStatus
			Owner["status_rows"] := Previous
		else if Owner.Has("status_rows")
			Owner.Delete("status_rows")
	}
}
Test("Gestures menu: missing or effect-bearing boundary refuses atomically without changing native assignment owners", _GTB_RefusedBoundary)





; =============================================
; =============================================
; ======= 1/ Availability of the Slots ========
; =============================================
; =============================================

; Runs a callback with the cached availability state restored afterwards.
_GSS_WithState(Callback) {
	State := GestureSystemState()
	PreviousSlots := State["slots"], PreviousReady := State["ready"], PreviousMenu := State["menu"]
	try return Callback.Call(State)
	finally {
		State["slots"] := PreviousSlots, State["ready"] := PreviousReady, State["menu"] := PreviousMenu
	}
}

; Three outcomes of the one predicate: every value assigned, a registry key that
; does not exist at all, and one slot's value missing (the others stay assigned).
_GSS_PredicateOutcomes() {
	global GESTURE_SLOTS, GESTURE_REG_ACTIONS
	Full := _GSS_FullReader()
	for Slot in GESTURE_SLOTS
		AssertTrue(GestureSystemSlotConfigured(Slot, Full), Slot . " is available when every value is assigned")
	; The key is missing: RegRead falls back to "" and nothing is assigned.
	Missing := GestureSystemRegistryReader("HKEY_CURRENT_USER\Software\ErgoptiPlusTests\NoSuchPrecisionTouchPad")
	Snapshot := GestureSystemReadSnapshot(Missing)
	AssertEqual(GESTURE_SLOTS.Length, Snapshot.Count, "a missing key still yields a complete snapshot")
	for Slot, Available in Snapshot
		AssertFalse(Available, Slot . " is unavailable when the registry key does not exist")
	; One slot loses its own action value: only that slot becomes unavailable.
	Lost := GESTURE_REG_ACTIONS["tap_3"]
	Partial := (Name) => Name == Lost ? "" : Full.Call(Name)
	Mixed := GestureSystemReadSnapshot(Partial)
	AssertFalse(Mixed["tap_3"], "tap_3 is unavailable without its action value")
	for Slot, Available in Mixed {
		if (Slot != "tap_3")
			AssertTrue(Available, Slot . " stays available")
	}
}
Test("Gestures availability: assigned, not assigned and registry key missing", _GSS_PredicateOutcomes)

; A refused read is never "available": the state is unverified and says so.
_GSS_UnreadableIsNotAvailable() {
	_GSS_WithState(_GSS_UnreadableIsNotAvailableInner)
}
_GSS_UnreadableIsNotAvailableInner(State) {
	AssertTrue(GestureSystemRefresh(_GSS_FullReader()))
	AssertTrue(GestureSystemSlotAvailable("tap_3"))
	AssertEqual("", GestureSystemUnavailableReason("tap_3"), "an available slot has no reason")
	AssertFalse(GestureSystemRefresh(TestGestures_RefuseSystemRead))
	AssertFalse(GestureSystemSlotAvailable("tap_3"), "a stale good value cannot survive a refused read")
	AssertEqual(t("gestures.system.slot_unverified"), GestureSystemUnavailableReason("tap_3"))
	AssertTrue(GestureSystemRefresh((Name) => ""))
	AssertEqual(t("gestures.system.slot_unavailable"), GestureSystemUnavailableReason("tap_3"))
}
Test("Gestures availability: an unreadable registry leaves every slot unavailable with its own reason", _GSS_UnreadableIsNotAvailable)

; The menu rows: available stays clickable, the others are disabled with the reason.
_GSS_RowsFollowAvailability() {
	_GTB_WithSlots(() => _GSS_RowsFollowAvailabilityInner())
}
_GSS_RowsFollowAvailabilityInner() {
	global GESTURE_REG_ACTIONS
	Full := _GSS_FullReader()
	Lost := GESTURE_REG_ACTIONS["tap_4"]
	Rows := _GES_SlotRows((Name) => Name == Lost ? "" : Full.Call(Name))
	Reason := t("gestures.system.slot_unavailable")
	; Three-finger header, swipe_3_up, tap_3, separator, four-finger header, tap_4.
	AssertEqual(6, Rows.Length)
	AssertFalse(Rows[2]["disabled"], "swipe_3_up is assigned")
	AssertFalse(InStr(Rows[2]["label"], Reason), "an available row carries no reason")
	AssertTrue(Rows[6]["disabled"], "tap_4 is not assigned")
	AssertTrue(SubStr(Rows[6]["label"], -StrLen(Reason)) == Reason, "the reason ends the greyed label")
	AssertTrue(InStr(Rows[6]["label"], LabelValue(t("gesture.slots.tap_4"), "")) == 1, "the slot name still leads")
	AssertFalse(Rows[3]["disabled"], "tap_3 is assigned")
	; Nothing assigned and an unreadable registry grey every row.
	for Reader in [(Name) => "", TestGestures_RefuseSystemRead] {
		Greyed := _GES_SlotRows(Reader)
		for Row in Greyed {
			if !Row.Get("separator", false)
				AssertTrue(Row["disabled"], "no slot is usable without an assignment: " . Row["label"])
		}
	}
	AssertTrue(InStr(_GES_SlotRows(TestGestures_RefuseSystemRead)[2]["label"], t("gestures.system.slot_unverified")),
		"an unreadable registry says so in the row")
}
Test("Gestures availability: slot rows are greyed with their reason and re-read at every build", _GSS_RowsFollowAvailability)

; Snapshots are compared as a whole, an unverified state differs from a verified one.
_GSS_SnapshotComparison() {
	A := Map("tap_3", true, "tap_4", false)
	AssertTrue(_GestureSystemSameSnapshot(A, Map("tap_4", false, "tap_3", true)))
	AssertFalse(_GestureSystemSameSnapshot(A, Map("tap_3", true, "tap_4", true)), "one slot changed")
	AssertFalse(_GestureSystemSameSnapshot(A, Map("tap_3", true)), "a slot is missing")
	AssertFalse(_GestureSystemSameSnapshot(A, 0), "unverified differs from verified")
	AssertTrue(_GestureSystemSameSnapshot(0, 0), "two unverified states agree")
}
Test("Gestures availability: snapshot comparison decides whether the menu is stale", _GSS_SnapshotComparison)

; The open-time check only acts for the published Gestures submenu.
_GSS_OpenOnlyForTheGesturesMenu() {
	_GSS_WithState(_GSS_OpenOnlyForTheGesturesMenuInner)
}
_GSS_OpenOnlyForTheGesturesMenuInner(State) {
	State["menu"] := 0
	; With no published menu, or another menu, nothing is read or rebuilt.
	GestureSystemOnInitPopup(12345)
	State["menu"] := 777
	GestureSystemOnInitPopup(12345)
	AssertEqual(777, State["menu"], "a foreign popup leaves the watched handle alone")
}
Test("Gestures availability: the open-time check ignores every other menu", _GSS_OpenOnlyForTheGesturesMenu)

_GSS_RefusedPopupAndRecovery() {
	_GSS_WithState(_GSS_RefusedPopupAndRecoveryInner)
}
_GSS_RefusedPopupAndRecoveryInner(State) {
	State["menu"] := 777
	AssertTrue(GestureSystemRefresh(_GSS_FullReader()))
	Calls := Map("cancel", 0, "schedule", 0, "rebuild", 0)
	_GestureSystemCheckPopup(777, TestGestures_RefuseSystemRead,
		() => Calls["cancel"] += 1, () => Calls["schedule"] += 1)
	AssertFalse(GestureSystemSlotAvailable("tap_3"), "a refused popup read invalidates the old snapshot")
	AssertEqual(1, Calls["cancel"], "the stale menu closes")
	AssertEqual(1, Calls["schedule"], "the unverified menu is scheduled")
	_GestureSystemRefreshAndRebuild(_GSS_FullReader(), () => Calls["rebuild"] += 1)
	AssertTrue(GestureSystemSlotAvailable("tap_3"), "a later successful read restores availability")
	AssertEqual(1, Calls["rebuild"], "recovery rebuilds the published unverified menu")
}
Test("Gestures availability: refused popup and recovery (gesture-popup-read-failure)", _GSS_RefusedPopupAndRecovery)






; =============================================
; =============================================
; ======= 2/ The Status Submenu Is Gone =======
; =============================================
; =============================================

; Windows has no verification submenu: no declaration, no provider, no functions.
_GSS_StatusSubmenuAbsent() {
	Root := _MR_GetManifestRoot()
	for Section in ["gesture_system_status_windows_frame", "gesture_system_windows_children",
		"gesture_system_slot_windows_frame", "gesture_system_slot_configured", "gesture_system_slot_not_configured"]
		AssertFalse(Root.Has(Section), "retired Windows status declaration: " . Section)
	Status := false
	for Item in Root["gestures_menu"] {
		if Item.Get("id", "") == "system_gesture_status" {
			AssertFalse(Status is Map, "the shared declaration has exactly one status row")
			Status := Item
		}
	}
	Assert(Status is Map, "macOS and Linux keep the row, so the raw declaration exists")
	AssertFalse(_MR_FindItemById("gestures_menu", "system_gesture_status"),
		"the actual Windows declaration lookup must hide the foreign status row")
	for Platform in Status["platforms"]
		AssertTrue(Platform != "ahk", "the status row is not declared for the Windows driver")
	for Name in ["GestureSystemRows", "GestureSystemNotice", "GestureSystemFinishNotice",
		"GestureSystemAfterAssignment", "GestureSystemAssignmentNeedsWarning", "GestureSystemGroup"]
		AssertEqual("", _DriverFuncBodyOrEmpty(Name), Name . " is retired with the status submenu")
	Builder := _DriverFuncBody("BuildGesturesMenu")
	AssertFalse(InStr(Builder, "system_gesture_status"), "the Windows menu registers no status provider")
	Info := _MR_FindItemById("gestures_menu", "gesture_recommended_info")
	Assert(Info is Map, "the Infos row explains the greying")
	AssertEqual("command", Info["type"])
}
Test("Gestures availability: the status submenu is absent from the Windows menu", _GSS_StatusSubmenuAbsent)

; The explanation was a menu row: a paragraph in the tray, and a French row
; AutoHotkey dropped (Menu.Add refuses more than 260 UTF-16 units). The menu now
; shows « Infos… » and the native message box carries the Windows reason.
_GSS_InfoOpensTheWindowsReason() {
	for Item in _MR_GetMenuDef("gestures_menu")
		if _MR_IsForAhk(Item)
			AssertTrue(Item.Get("type", "") != "label", "the Gestures menu shows no explanation row")
	AssertContains(_DriverFuncBody("BuildGesturesMenu"), "_GES_MenuCommands(",
		"the Gestures menu registers its commands from one table")
	AssertContains(_DriverFuncBody("_GES_MenuCommands"),
		"MenuStartupUiCommand((*) => GestureShowRecommendedInfo(), MenuStartupDiagnosticsReady)",
		"the Infos row opens the explanation dialog")
	InfoShown := []
	try {
		TestMsgBoxResponder((Text, Title, Options) => (InfoShown.Push(Map("text", Text, "title", Title, "options", Options)), "OK"))
		GestureShowRecommendedInfo()
	} finally {
		TestMsgBoxResponder("")
	}
	AssertEqual(1, InfoShown.Length, "one native message box opens")
	AssertEqual(t("menu.gestures.recommended_reason_windows"), InfoShown[1]["text"])
	AssertTrue(InStr(InfoShown[1]["title"], t("menu.gestures.notify_title")), "the dialog is titled Gestures")
	AssertTrue(InStr(InfoShown[1]["options"], "Iconi"), "it is an information dialog")
	AssertFalse(InStr(InfoShown[1]["text"], t("menu.gestures.recommended_note")),
		"Windows takes the system assignment over itself: no remove-it-first advice")
}
Test("Gestures menu: Infos opens the Windows reason in a message box", _GSS_InfoOpensTheWindowsReason)

; « Infos… » took about five seconds after a reload: the click was retained
; like a state-changing command until input initialization completed
; ("Retained startup selection runs after 5265 ms" in the maintainer's log).
; It is now a startup UI command, so it opens while input is still pending,
; and its handler reads no registry and rebuilds nothing.
_GSS_InfoOpensAtOnce(Owner, State) {
	global _DriverUiCleanupReady, _DriverMenuReady
	SavedCleanup := IsSet(_DriverUiCleanupReady) ? _DriverUiCleanupReady : unset
	SavedMenu := IsSet(_DriverMenuReady) ? _DriverMenuReady : unset
	Shown := []
	try {
		; The configured tray is published, input registration is not done yet.
		_DriverUiCleanupReady := true, _DriverMenuReady := true
		Command := _GES_MenuCommands(Map())["gesture_recommended_info"]
		AssertTrue(Command is MenuStartupUiCommand, "Infos is a startup UI command")
		TestMsgBoxResponder((Text, *) => (Shown.Push(Text), "OK"))
		MenuCommandRun(Command, [])
		AssertEqual(1, Shown.Length, "the dialog opens before input initialization completes")
		AssertEqual(0, Owner.Pending.Length, "the click is not retained")
		AssertEqual(t("menu.gestures.recommended_reason_windows"), Shown[1])
	} finally {
		TestMsgBoxResponder("")
		_DriverUiCleanupReady := IsSet(SavedCleanup) ? SavedCleanup : unset
		_DriverMenuReady := IsSet(SavedMenu) ? SavedMenu : unset
	}
	Body := _DriverFuncBody("GestureShowRecommendedInfo")
	Assert(Body != "", "the Infos handler must exist")
	for _, Slow in ["GestureSystemRefresh", "GestureSystemReadSnapshot", "RegRead", "RebuildTrayMenu",
			"GestureSystemRequestRefresh", "MenuRenderer_Build"]
		AssertEqual(0, InStr(Body, Slow), "Infos does no slow work before its dialog: " . Slow)
}
Test("Gestures menu: Infos opens at once, even right after a reload (gesture-info-instant)",
	(*) => _MSC_WithOwner(_GSS_InfoOpensAtOnce))

; Whoever rewrites the registry asks for a re-read, so the greying follows it.
; The touchpad restore is part of the Gestures and global clears, which reload
; the driver: the successor's first build reads the registry again, and a
; refused clear is caught by the open-time check below.
_GSS_RegistryWritersRequestRefresh() {
	for Name in ["GestureAutoConfigureRegistry"]
		AssertContains(_DriverFuncBody(Name), "GestureSystemRequestRefresh(",
			Name . " must refresh the availability after changing the registry")
	for Name in ["_GES_ApplyScope", "ConfigGlobalScopeApply"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist")
		ClearAt := InStr(Body, "TouchpadRegistryClearFromScope(")
		AssertTrue(ClearAt > 0 && ClearAt < InStr(Body, "Receipt :="),
			Name . " restores the touchpad before the commit that reloads the driver")
	}
	AssertContains(_DriverFuncBody("GestureSystemWatchMenu"), "OnMessage(0x117",
		"the Gestures submenu is re-checked when it opens")
	AssertContains(_DriverFuncBody("BuildGesturesMenu"), "GestureSystemWatchMenu(",
		"the built Gestures submenu is the one watched")
}
Test("Gestures availability: registry rewrites and the menu open both re-evaluate it", _GSS_RegistryWritersRequestRefresh)

; The notice is gone: boot removes what it stored and nothing else in the store.
_GSS_RetiresTheDismissedEntries() {
	Records := []
	for Name in ["gesture_conflict_dismissed.swipe_3", "theme", "gesture_conflict_dismissed.tap_2",
			"gesture_conflict_dismissed"]
		Records.Push({ name: Name })
	Deleted := []
	Removed := GestureSystemRetireDismissals((*) => Records, (Key) => (Deleted.Push(Key), true))
	AssertEqual(2, Removed)
	AssertEqual(2, Deleted.Length)
	AssertEqual("gesture_conflict_dismissed.swipe_3", Deleted[1])
	AssertEqual("gesture_conflict_dismissed.tap_2", Deleted[2])
	AssertEqual(0, GestureSystemRetireDismissals((*) => Records, (*) => false),
		"a refused deletion is not counted and raises nothing")
	Assert(InStr(FSReadUtf8Exact(A_ScriptDir . "\..\ErgoptiPlus.ahk"), "`nGestureSystemRetireDismissals()`n"),
		"the boot runs the sweep")
}
Test("Gestures availability: boot removes the retired notice entries and nothing else", _GSS_RetiresTheDismissedEntries)
