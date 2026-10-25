; tests/unit/modules/gestures/test_gesture_menu_status.ahk

; ==============================================================================
; MODULE: Gesture Menu Boundary and Availability
; DESCRIPTION:
; The gestures menu materializes its shared tap boundary, consumes the
; current declared order and refuses an effect-bearing boundary. Each slot row
; is greyed out, with its reason in the label, unless the Windows touchpad
; settings send Ergopti's shortcut for it (assigned / not assigned / key
; missing / unreadable). The retired status submenu stays absent.
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

; The independent three-slot vector crosses the original tap_4 boundary once.
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

_GTB_AssertSlotRows(Rows, ExpectedLength, TapPosition) {
	Assert(Rows is Array)
	AssertEqual(ExpectedLength, Rows.Length)
	for Pair in [[1, "swipe_3_up"], [TapPosition, "tap_4"], [TapPosition + 1, "tap_3"]] {
		Row := Rows[Pair[1]]
		AssertTrue(InStr(Row["label"], t("gesture.slots." . Pair[2]) . " : ") == 1)
		Assert(Row["action"] is Func, "the existing slot action remains its native callback")
		AssertFalse(Row["disabled"])
	}
}

_GTB_DeclaredBoundary() {
	_GTB_WithSlots(() => _GTB_DeclaredBoundaryInner())
}
_GTB_DeclaredBoundaryInner() {
	Owner := _GTB_Owner()
	Assert(Owner.Get("status_rows", false) is Map)
	Boundary := Owner["status_rows"]["tap_group_boundary"]
	Assert(Boundary is Array)
	AssertEqual(1, Boundary.Length)
	AssertEqual(1, Boundary[1].Count)
	AssertEqual("---", Boundary[1]["type"])
	Rows := _GES_SlotRows(_GSS_FullReader())
	_GTB_AssertSlotRows(Rows, 4, 3)
	AssertTrue(Rows[2]["separator"])
	AssertFalse(Rows[2].Has("action"), "a fixed separator has no click owner")
	Native := Menu()
	try {
		AssertEqual(3, _MR_RenderRows(Native, Rows, "gesture_slots_ahk", 1), "the renderer receipt counts named rows only")
		AssertEqual(4, DllCall("user32\GetMenuItemCount", "Ptr", Native.Handle, "Int"))
		Flags := DllCall("user32\GetMenuState", "Ptr", Native.Handle, "UInt", 1, "UInt", 0x400, "UInt")
		Assert(Flags != 0xFFFFFFFF, "GetMenuState must acknowledge the actual separator position")
		AssertTrue((Flags & 0x800) != 0, "the actual Win32 item between swipe and tap is a separator")
		AssertEqual(Rows[3]["label"], _CTC_LabelAt(Native, 2), "tap_4 follows the actual separator")
	} finally _CTC_ReleaseMenu(Native)
}
Test("Gestures menu: the actual flat provider materializes its shared tap boundary", _GTB_DeclaredBoundary)

_GTB_PublishedBoundary() {
	_GTB_WithSlots(() => _GTB_PublishedBoundaryInner())
}
_GTB_PublishedBoundaryInner() {
	Owner := _GTB_Owner(), HadStatus := Owner.Has("status_rows"), Previous := Owner.Get("status_rows", false)
	try {
		Owner["status_rows"] := Map("tap_group_boundary", [
			Map("type", "label", "i18n", "common.restore_recommended"), Map("type", "---")])
		Rows := _GES_SlotRows(_GSS_FullReader())
		_GTB_AssertSlotRows(Rows, 5, 4)
		AssertEqual(t("common.restore_recommended"), Rows[2]["label"])
		AssertTrue(Rows[2]["disabled"])
		AssertFalse(Rows[2].Has("action"))
		AssertTrue(Rows[3]["separator"])
		AssertFalse(Rows[3].Has("action"))
		Owner["status_rows"]["tap_group_boundary"][1]["i18n"] := "common.clear_to_system"
		AssertEqual(t("common.restore_recommended"), Rows[2]["label"], "held materialized data is detached from later source mutation")
		AssertEqual(t("common.clear_to_system"), _GES_SlotRows(_GSS_FullReader())[2]["label"], "a fresh native provider consumes current shared source")
		Owner.Delete("status_rows")
		AssertEqual(0, _GES_SlotRows(_GSS_FullReader()).Length, "a missing required boundary refuses a rebuilt provider")
		Native := Menu()
		try {
			AssertEqual(4, _MR_RenderRows(Native, Rows, "gesture_slots_ahk", 1), "the renderer receipt counts the inert label and slots")
			AssertEqual(5, DllCall("user32\GetMenuItemCount", "Ptr", Native.Handle, "Int"))
			AssertEqual(t("common.restore_recommended"), _CTC_LabelAt(Native, 1))
			Flags := DllCall("user32\GetMenuState", "Ptr", Native.Handle, "UInt", 1, "UInt", 0x400, "UInt")
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
	try {
		for Invalid in [false, Map(), Map("tap_group_boundary", []),
			Map("tap_group_boundary", [Map("type", "command", "id", "foreign_action")]),
			Map("tap_group_boundary", [Map("type", "---", "action", (*) => true)]),
			Map("tap_group_boundary", [Map("type", "label", "i18n", "common.restore_recommended", "checked_when", ["foreign_state"])])] {
			Owner["status_rows"] := Invalid
			AssertEqual(0, _GES_SlotRows(_GSS_FullReader()).Length, "missing, empty or effect-bearing status cannot publish a partial slot list")
			AssertTrue(GestureAssignments == Assignments)
			AssertEqual("none", GestureAssignments["tap_4"])
			AssertTrue(Features == FeatureOwner)
			AssertTrue(Features["gestures"]["enabled"])
		}
		Owner.Delete("status_rows")
		GESTURE_SLOTS := ["swipe_3_up", "tap_3"]
		Rows := _GES_SlotRows(_GSS_FullReader())
		AssertEqual(2, Rows.Length, "an absent tap_4 needs no boundary or invented separator")
		AssertFalse(Rows[1].Get("separator", false))
		AssertFalse(Rows[2].Get("separator", false))
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
	AssertEqual(4, Rows.Length)
	AssertFalse(Rows[1]["disabled"], "swipe_3_up is assigned")
	AssertFalse(InStr(Rows[1]["label"], Reason), "an available row carries no reason")
	AssertTrue(Rows[3]["disabled"], "tap_4 is not assigned")
	AssertTrue(SubStr(Rows[3]["label"], -StrLen(Reason)) == Reason, "the reason ends the greyed label")
	AssertTrue(InStr(Rows[3]["label"], t("gesture.slots.tap_4") . " : ") == 1, "the slot name still leads")
	AssertFalse(Rows[4]["disabled"], "tap_3 is assigned")
	; Nothing assigned and an unreadable registry grey every row.
	for Reader in [(Name) => "", TestGestures_RefuseSystemRead] {
		Greyed := _GES_SlotRows(Reader)
		for Row in Greyed {
			if !Row.Get("separator", false)
				AssertTrue(Row["disabled"], "no slot is usable without an assignment: " . Row["label"])
		}
	}
	AssertTrue(InStr(_GES_SlotRows(TestGestures_RefuseSystemRead)[1]["label"], t("gestures.system.slot_unverified")),
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
	Status := _MR_FindItemById("gestures_menu", "system_gesture_status")
	Assert(Status is Map, "macOS and Linux keep the row, so the declaration exists")
	for Platform in Status["platforms"]
		AssertTrue(Platform != "ahk", "the status row is not declared for the Windows driver")
	for Name in ["GestureSystemRows", "GestureSystemNotice", "GestureSystemFinishNotice",
		"GestureSystemAfterAssignment", "GestureSystemAssignmentNeedsWarning", "GestureSystemGroup"]
		AssertEqual("", _DriverFuncBodyOrEmpty(Name), Name . " is retired with the status submenu")
	Builder := _DriverFuncBody("BuildGesturesMenu")
	AssertFalse(InStr(Builder, "system_gesture_status"), "the Windows menu registers no status provider")
	Notes := _MR_FindItemById("gesture_recommended_notes", "gesture_recommended_reason_windows")
	Assert(Notes is Map, "the Windows note explains the greying")
	AssertEqual("ahk", Notes["platforms"][1])
}
Test("Gestures availability: the status submenu is absent from the Windows menu", _GSS_StatusSubmenuAbsent)

; Whoever rewrites the registry asks for a re-read, so the greying follows it.
_GSS_RegistryWritersRequestRefresh() {
	for Name in ["GestureAutoConfigureRegistry", "TouchpadRegistryRestoreFromMenu"]
		AssertContains(_DriverFuncBody(Name), "GestureSystemRequestRefresh(",
			Name . " must refresh the availability after changing the registry")
	AssertContains(_DriverFuncBody("GestureSystemWatchMenu"), "OnMessage(0x117",
		"the Gestures submenu is re-checked when it opens")
	AssertContains(_DriverFuncBody("BuildGesturesMenu"), "GestureSystemWatchMenu(",
		"the built Gestures submenu is the one watched")
}
Test("Gestures availability: registry rewrites and the menu open both re-evaluate it", _GSS_RegistryWritersRequestRefresh)
