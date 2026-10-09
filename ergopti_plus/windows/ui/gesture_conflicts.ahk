; ui/gesture_conflicts.ahk

; ==============================================================================
; MODULE: System Gesture Status (Windows)
; DESCRIPTION:
; Checks the exact Precision Touchpad registry contract written by automatic
; configuration. Menus consume the cached result; registry reads and notices
; run on a deferred callback, never while building a menu.
; ==============================================================================

; Session owner. Kept behind an accessor so include order cannot reset it.
GestureSystemState() {
	static State := Map("slots", Map(), "shown", Map(), "windows", Map(), "callbacks", Map(), "ready", false)
	return State
}

; Uses the native configuration family as the durable warning group.
GestureSystemGroup(Slot) {
	return RegExReplace(Slot, "^(tap|swipe)_([34]).*$", "$1_$2")
}

; Checks all fields needed for one slot, including its family and modifier mask.
; Read is injectable and returns an empty string for absent registry values.
GestureSystemSlotConfigured(Slot, Read) {
	global GESTURE_REG_ACTIONS, GESTURE_REG_KEY_PARAMS_NAMES, GESTURE_REG_KEY_PARAMS
	global GESTURE_REG_ENABLE_NAMES, GESTURE_REG_CUSTOM_TAP_NAMES, GESTURE_REG_FAMILY_ENABLES
	global GESTURE_REG_CUSTOM_VALUE, GESTURE_REG_CUSTOM_TAP_VALUE
	if !GESTURE_REG_ACTIONS.Has(Slot)
		return false
	Expected := Map(GESTURE_REG_FAMILY_ENABLES[Slot], GESTURE_REG_CUSTOM_VALUE,
		GESTURE_REG_ACTIONS[Slot], GESTURE_REG_CUSTOM_VALUE,
		GESTURE_REG_KEY_PARAMS_NAMES[Slot], GESTURE_REG_KEY_PARAMS[Slot])
	if GESTURE_REG_ENABLE_NAMES.Has(Slot)
		Expected[GESTURE_REG_ENABLE_NAMES[Slot]] := GESTURE_REG_CUSTOM_VALUE
	if GESTURE_REG_CUSTOM_TAP_NAMES.Has(Slot)
		Expected[GESTURE_REG_CUSTOM_TAP_NAMES[Slot]] := GESTURE_REG_CUSTOM_TAP_VALUE
	for Name, Value in Expected {
		Actual := Read.Call(Name)
		if !(Actual is Integer) || Actual != Value
			return false
	}
	return true
}

; Refreshes outside menu construction. Existing maps are published only as a whole.
GestureSystemRefresh(Notify := false, Read := 0) {
	global GESTURE_REG_PATH, GESTURE_SLOTS, GestureAssignments, Features
	if !IsObject(Read)
		Read := (Name) => RegRead(GESTURE_REG_PATH, Name, "")
	LoggerStart("gestures.status", "Reading system gesture settings…")
	Candidate := Map()
	try {
		for _, Slot in GESTURE_SLOTS
			Candidate[Slot] := GestureSystemSlotConfigured(Slot, Read)
	} catch as Err {
		GestureSystemState()["ready"] := false
		LoggerError("gestures.status", "System gesture settings could not be read: {1}.", Err.Message)
		return false
	}
	State := GestureSystemState()
	State["slots"] := Candidate
	State["ready"] := true
	LoggerSuccess("gestures.status", "System gesture settings cached.")
	Enabled := Features.Has("gestures") && Features["gestures"].Get("enabled", false)
	if Notify && Enabled {
		for Slot, Configured in Candidate {
			Group := GestureSystemGroup(Slot)
			if !Configured && GestureAssignments.Get(Slot, "none") != "none" && !State["shown"].Has(Group) {
				State["shown"][Group] := true
				GestureSystemNotice(Slot)
			}
		}
	}
	return true
}

; Defers registry reads; no work is performed by a menu provider.
GestureSystemRequestRefresh(*) {
	SetTimer(GestureSystemRefresh, -1)
}

; Builds shared-renderer data from the last complete registry snapshot.
; Captures one native slot before creating getters; AHK loop cells are not closure owners.
_GestureSystemSlotRows(State, Slot, Configured) {
	return MenuRenderer_TemplateRows("gesture_system_slot_windows_frame", Map(
		"gesture_system_open_unknown_slot", (*) => GestureOpenTouchpadSettings(),
		"gesture_system_open_configured_slot", (*) => GestureOpenTouchpadSettings(),
		"gesture_system_open_not_configured_slot", (*) => GestureOpenTouchpadSettings()), Map(
		"gesture_system_slot_unverified", () => !State["ready"],
		"gesture_system_slot_configured", () => State["ready"] && Configured,
		"gesture_system_slot_not_configured", () => State["ready"] && !Configured,
		"gesture_system_slot_caption", () => t("gesture.slots." . Slot)), Map())
}

GestureSystemRows() {
	global GestureAssignments, GESTURE_SLOTS, Features
	State := GestureSystemState()
	SlotRows := []
	Conflicts := 0
	Enabled := Features.Has("gestures") && Features["gestures"].Get("enabled", false)
	for _, Slot in GESTURE_SLOTS {
		Configured := State["slots"].Get(Slot, false)
		if Enabled && GestureAssignments.Get(Slot, "none") != "none" && !Configured
			Conflicts += 1
		Rows := _GestureSystemSlotRows(State, Slot, Configured)
		if !(Rows is Array) || Rows.Length != 1
			return []
		SlotRows.Push(Rows[1])
	}
	Children := MenuRenderer_TemplateRows("gesture_system_windows_children",
		Map("gesture_system_refresh", GestureSystemRequestRefresh), Map(),
		Map("gesture_system_cached_slots", () => SlotRows))
	if !(Children is Array)
		return []
	Rows := MenuRenderer_TemplateRows("gesture_system_status_windows_frame", Map(), Map(
		"gesture_system_is_unverified", () => !State["ready"],
		"gesture_system_is_clear", () => State["ready"] && Conflicts == 0,
		"gesture_system_has_conflicts", () => State["ready"] && Conflicts > 0,
		"gesture_system_conflict_count", () => String(Conflicts)), Map(
		"gesture_system_unknown_children", () => Children,
		"gesture_system_clear_children", () => Children,
		"gesture_system_conflict_children", () => Children))
	return Rows is Array && Rows.Length == 1 ? Rows : []
}

; Keeps one notice per group alive, with explicit dismissal separate from closing.
GestureSystemNotice(Slot, OnDone := 0) {
	State := GestureSystemState()
	Group := GestureSystemGroup(Slot)
	if ST_Get("gesture_conflict_dismissed." . Group, false) == true {
		if IsObject(OnDone)
			return OnDone.Call()
		return true
	}
	if !State["callbacks"].Has(Group)
		State["callbacks"][Group] := []
	if IsObject(OnDone)
		State["callbacks"][Group].Push(OnDone)
	if State["windows"].Has(Group) {
		; Requested again: bring the open notice back in front. A reload the
		; user asked for waits on it, and an ordinary window can be covered.
		WMPresentWindow(State["windows"][Group])
		return true
	}
	G := Gui_Create("", t("menu.gestures.conflict_title"))
	G.AddText("w440", t("gesture.slots." . Slot) . "`n" . t("gestures.system.not_configured"))
	G.AddButton("xm", t("menu.gestures.open_settings")).OnEvent("Click",
		(*) => GestureSystemFinishNotice(Group, G, "settings"))
	G.AddButton("x+8", t("gestures.system.dismiss")).OnEvent("Click",
		(*) => GestureSystemFinishNotice(Group, G, "dismiss"))
	G.OnEvent("Close", (*) => GestureSystemFinishNotice(Group, G, "close"))
	G.OnEvent("Escape", (*) => GestureSystemFinishNotice(Group, G, "close"))
	State["windows"][Group] := G
	; Shown and focused: an ErgoptiPlus window is never kept on top, so a
	; notice left inactive was covered by the next click in another app.
	G.Show()
	return true
}

; Retires the owned notice before running the chosen external action or reload.
GestureSystemFinishNotice(Slot, G, Choice) {
	State := GestureSystemState()
	if !State["windows"].Has(Slot) || State["windows"][Slot] != G
		return false
	if Choice == "dismiss" {
		if ST_Set("gesture_conflict_dismissed." . Slot, true) != true {
			LoggerError("gestures.status", "Conflict dismissal could not be saved.")
			return false
		}
	}
	State["windows"].Delete(Slot)
	Callbacks := State["callbacks"].Delete(Slot)
	G.Destroy()
	if Choice == "settings"
		GestureOpenTouchpadSettings()
	for Callback in Callbacks
		Callback.Call()
	return true
}

; The assignment was committed; defer its notice before the required reload.
GestureSystemAfterAssignment(Slot) {
	if !GestureSystemAssignmentNeedsWarning(Slot)
		return ReloadPreservingSuspend()
	SetTimer((*) => GestureSystemNotice(Slot, ReloadPreservingSuspend), -1)
	return true
}

; Reports whether the cached native contract can rule out an assignment conflict.
GestureSystemAssignmentNeedsWarning(Slot) {
	State := GestureSystemState()
	return !State["ready"] || !State["slots"].Get(Slot, false)
}
