; tests/unit/modules/gestures/test_gesture_menu_status.ahk

; ==============================================================================
; MODULE: Gesture Menu Boundary and Status
; DESCRIPTION:
; The gestures menu materializes its shared tap boundary, consumes the
; current declared order and refuses an effect-bearing boundary, and the
; cached status frames keep their localized captions and strict
; predicates.
; ==============================================================================

#Requires AutoHotkey v2.0





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
	Rows := _GES_SlotRows()
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
		Rows := _GES_SlotRows()
		_GTB_AssertSlotRows(Rows, 5, 4)
		AssertEqual(t("common.restore_recommended"), Rows[2]["label"])
		AssertTrue(Rows[2]["disabled"])
		AssertFalse(Rows[2].Has("action"))
		AssertTrue(Rows[3]["separator"])
		AssertFalse(Rows[3].Has("action"))
		Owner["status_rows"]["tap_group_boundary"][1]["i18n"] := "common.clear_to_system"
		AssertEqual(t("common.restore_recommended"), Rows[2]["label"], "held materialized data is detached from later source mutation")
		AssertEqual(t("common.clear_to_system"), _GES_SlotRows()[2]["label"], "a fresh native provider consumes current shared source")
		Owner.Delete("status_rows")
		AssertEqual(0, _GES_SlotRows().Length, "a missing required boundary refuses a rebuilt provider")
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
			AssertEqual(0, _GES_SlotRows().Length, "missing, empty or effect-bearing status cannot publish a partial slot list")
			AssertTrue(GestureAssignments == Assignments)
			AssertEqual("none", GestureAssignments["tap_4"])
			AssertTrue(Features == FeatureOwner)
			AssertTrue(Features["gestures"]["enabled"])
		}
		Owner.Delete("status_rows")
		GESTURE_SLOTS := ["swipe_3_up", "tap_3"]
		Rows := _GES_SlotRows()
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

; Keeps complete cached-system status assertions on the actual native provider.
_GSS_WithSnapshot(Callback) {
	global GESTURE_SLOTS, GestureAssignments, Features, _I18nCache, _I18nCacheLoaded
	State := GestureSystemState()
	PreviousSlots := GESTURE_SLOTS, PreviousAssignments := GestureAssignments, PreviousFeatures := Features
	PreviousReady := State["ready"], PreviousCached := State["slots"]
	PreviousCache := _I18nCache, PreviousLoaded := _I18nCacheLoaded
	try {
		GESTURE_SLOTS := ["swipe_3_up", "tap_4", "tap_3"]
		GestureAssignments := Map("swipe_3_up", "lookup", "tap_4", "lookup", "tap_3", "lookup")
		Features := Map("gestures", Map("enabled", true))
		State["slots"] := Map("swipe_3_up", true, "tap_4", false, "tap_3", false)
		State["ready"] := false
		return Callback.Call(State)
	} finally {
		GESTURE_SLOTS := PreviousSlots, GestureAssignments := PreviousAssignments, Features := PreviousFeatures
		State["ready"] := PreviousReady, State["slots"] := PreviousCached
		_I18nCache := PreviousCache, _I18nCacheLoaded := PreviousLoaded
	}
}

_GSS_PriorCaptions() {
	_GSS_WithSnapshot(_GSS_PriorCaptionsInner)
}
_GSS_PriorCaptionsInner(State) {
	global _SharedDir, GESTURE_SLOTS, GestureAssignments, _I18nCache, _I18nCacheLoaded
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\gesture_system_status_captions.json", "UTF-8"))
	Locales := JsonParse(FileRead(_SharedDir . "\data\locale_order.json", "UTF-8"))["order"]
	AssertEqual(21, Locales.Length)
	for Locale in Locales {
		Prior := Corpus["captions"][Locale]
		_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Locale . ".json", "UTF-8"))
		_I18nCacheLoaded := true
		for Slot in GESTURE_SLOTS
			_I18nCache["gesture.slots." . Slot] := "Independent Slot"
		State["ready"] := false
		Rows := GestureSystemRows()
		AssertEqual(1, Rows.Length)
		AssertEqual(Prior["unknown"], Rows[1]["label"], Locale . ": cached unknown parent")
		AssertFalse(State["ready"], "building never starts a registry probe")
		AssertEqual(4, Rows[1]["items"].Length)
		for Index in [1, 2, 3] {
			AssertEqual(Prior["slot_unknown"], Rows[1]["items"][Index]["label"])
			Assert(Rows[1]["items"][Index]["action"] is Func, "real cached Settings callback retained")
		}
		State["ready"] := true
		Rows := GestureSystemRows()
		AssertEqual(Prior["conflicts_two"], Rows[1]["label"])
		AssertEqual(Prior["slot_configured"], Rows[1]["items"][1]["label"])
		AssertEqual(Prior["slot_not_configured"], Rows[1]["items"][2]["label"])
		AssertEqual(Prior["slot_not_configured"], Rows[1]["items"][3]["label"])
		AssertEqual(t("ui_apps.btn_refresh"), Rows[1]["items"][4]["label"])
		for Slot in GESTURE_SLOTS
			GestureAssignments[Slot] := "none"
		AssertEqual(Prior["clear"], GestureSystemRows()[1]["label"])
		for Slot in GESTURE_SLOTS
			GestureAssignments[Slot] := "lookup"
		for Slot in GESTURE_SLOTS
			_I18nCache["gesture.slots." . Slot] := "Independent " . Slot
		State["ready"] := false
		Rows := GestureSystemRows()
		for Index, Slot in GESTURE_SLOTS
			AssertEqual(StrReplace(Prior["slot_unknown"], "Independent Slot", "Independent " . Slot),
				Rows[1]["items"][Index]["label"], "each real native slot retains its own independently chosen caption")

	}
}
Test("Gestures status: actual cached slot and parent frames preserve all prior localized captions", _GSS_PriorCaptions)

_GSS_WithdrawnFrames() {
	_GSS_WithSnapshot(_GSS_WithdrawnFramesInner)
}
_GSS_WithdrawnFramesInner(State) {
	Root := _MR_GetManifestRoot()
	for Section in ["gesture_system_status_windows_frame", "gesture_system_status_unknown", "gesture_system_windows_children",
		"gesture_system_slot_windows_frame", "gesture_system_slot_unknown"] {
		Original := Root[Section]
		try {
			Root[Section] := []
			AssertEqual(0, GestureSystemRows().Length, "withdrawn complete declaration refuses publication: " . Section)
			AssertFalse(State["ready"], "refusal cannot start a registry probe")
		} finally Root[Section] := Original
	}
}
Test("Gestures status: actual cached provider refuses every withdrawn active frame", _GSS_WithdrawnFrames)

_GSS_StrictPredicates() {
	_GSS_WithSnapshot(_GSS_StrictPredicatesInner)
}
_GSS_StrictPredicatesInner(State) {
	Root := _MR_GetManifestRoot()
	Section := "gesture_system_status_windows_frame"
	Original := Root[Section]
	try {
		for Getter in ["missing_native_status_predicate", "gesture_system_conflict_count"] {
			Changed := Original[1].Clone()
			Changed["present_when"] := Getter
			Root[Section] := [Changed, Original[2], Original[3]]
			AssertEqual(0, GestureSystemRows().Length, "missing and non-boolean actual source getters refuse status")
			AssertFalse(State["ready"])
		}
	} finally Root[Section] := Original
}
Test("Gestures status: actual cached status frame refuses missing and non-boolean predicates", _GSS_StrictPredicates)
