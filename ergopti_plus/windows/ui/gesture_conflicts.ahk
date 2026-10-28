; ui/gesture_conflicts.ahk

; ==============================================================================
; MODULE: System Gesture Availability (Windows)
; DESCRIPTION:
; Decides which gesture slots are usable. A slot is available when the Windows
; Precision Touchpad settings send the shortcut Ergopti listens for (Ctrl + Win
; + Shift + F1..F10, the generated touchpad table). The menu greys out every
; other slot with the reason, so no separate verification submenu exists.
;
; FEATURES & RATIONALE:
; 1. Read-only: a registry read of at most a few values per slot, cheap enough
;    to run whenever the gestures menu is built or opened.
; 2. One predicate, GestureSystemSlotConfigured, shared by the menu build and
;    the open-time check; a missing key or value means "not assigned".
; 3. Re-evaluated at three moments: every menu build, the open of the Gestures
;    submenu (a stale tray is rebuilt once), and after Ergopti rewrites or
;    restores the registry.
; 4. A registry read that fails is an ERROR and leaves the slots greyed with
;    their own reason; it is never treated as "available".
; ==============================================================================

; Session owner. Kept behind an accessor so include order cannot reset it.
; "menu" is the HMENU of the published Gestures submenu (0 before its build).
GestureSystemState() {
	static State := Map("slots", Map(), "ready", false, "menu", 0)
	return State
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

; The real registry reader: a value or a whole key that does not exist reads as
; an empty string, which the predicate counts as "not assigned".
; @param Path {String} Registry key path (the generated GESTURE_REG_PATH).
; @return {Func} fn(Name) returning the value or "".
GestureSystemRegistryReader(Path) {
	return (Name) => RegRead(Path, Name, "")
}

; Reads every slot once. Nothing is published, so a caller can compare the
; result with the cached state before deciding to rebuild.
; @param Read {Func|0} Injectable reader; the real registry when omitted.
; @return {Map} slot => Boolean availability; throws when the read is refused.
GestureSystemReadSnapshot(Read := 0) {
	global GESTURE_REG_PATH, GESTURE_SLOTS
	if !IsObject(Read)
		Read := GestureSystemRegistryReader(GESTURE_REG_PATH)
	Snapshot := Map()
	for _, Slot in GESTURE_SLOTS
		Snapshot[Slot] := GestureSystemSlotConfigured(Slot, Read)
	return Snapshot
}

; Reads the registry and publishes the snapshot as a whole, or marks the state
; unverified when the read fails.
; @param Read {Func|0} Injectable reader; the real registry when omitted.
; @return {Boolean} True when a complete snapshot was published.
GestureSystemRefresh(Read := 0) {
	LoggerStart("gestures.status", "Reading system gesture settings…")
	try {
		Candidate := GestureSystemReadSnapshot(Read)
	} catch as Err {
		GestureSystemState()["ready"] := false
		LoggerError("gestures.status", "System gesture settings could not be read: {1}.", Err.Message)
		return false
	}
	State := GestureSystemState()
	State["slots"] := Candidate
	State["ready"] := true
	LoggerSuccess("gestures.status", "System gesture settings cached.")
	return true
}

; Whether the cached snapshot says the system sends Ergopti's shortcut for a slot.
; An unverified state is never "available".
; @param Slot {String} Gesture slot id.
; @return {Boolean}
GestureSystemSlotAvailable(Slot) {
	State := GestureSystemState()
	return State["ready"] && State["slots"].Get(Slot, false)
}

; The reason shown in a greyed slot's row; empty for an available slot.
; @param Slot {String} Gesture slot id.
; @return {String} Localized reason.
GestureSystemUnavailableReason(Slot) {
	if GestureSystemSlotAvailable(Slot)
		return ""
	return GestureSystemState()["ready"]
		? t("gestures.system.slot_unavailable")
		: t("gestures.system.slot_unverified")
}

; Re-reads the registry after Ergopti rewrote it and rebuilds the tray when the
; availability changed. Deferred so the caller never waits on a rebuild.
GestureSystemRequestRefresh(*) {
	SetTimer(_GestureSystemRefreshAndRebuild, -1)
}

_GestureSystemRefreshAndRebuild() {
	State := GestureSystemState()
	Before := State["ready"] ? State["slots"] : 0
	GestureSystemRefresh()
	; Without a prior snapshot no menu was built from one: the first build reads
	; the registry itself.
	if IsObject(Before) && !_GestureSystemSameSnapshot(Before, State["ready"] ? State["slots"] : 0)
		RebuildTrayMenu()
}

; True when two availability snapshots (or two "unverified" states) agree.
_GestureSystemSameSnapshot(A, B) {
	if !IsObject(A) || !IsObject(B)
		return !IsObject(A) && !IsObject(B)
	if A.Count != B.Count
		return false
	for Slot, Available in A {
		if !B.Has(Slot) || B[Slot] != Available
			return false
	}
	return true
}

; WM_INITMENUPOPUP: the Gestures submenu is about to open. A change made behind
; Ergopti's back (Windows Settings, another tool) shows in the next build, so a
; stale tray is closed and rebuilt once instead of showing a wrong row.
GestureSystemOnInitPopup(Handle, *) {
	State := GestureSystemState()
	if !State["menu"] || Handle != State["menu"]
		return
	try {
		Fresh := GestureSystemReadSnapshot()
	} catch as Err {
		LoggerError("gestures.status", "System gesture settings could not be read on menu open: {1}.", Err.Message)
		return
	}
	if _GestureSystemSameSnapshot(State["ready"] ? State["slots"] : 0, Fresh)
		return
	LoggerInfo("gestures.status", "The system gesture settings changed since the menu was built; rebuilding it.")
	TrayMenuCancelNavigation()
	SetTimer(RebuildTrayMenu, -1)
}

; Registers the open-time check once and remembers which HMENU it guards.
; @param MenuObj {Menu} The Gestures submenu just built.
GestureSystemWatchMenu(MenuObj) {
	static Registered := false
	GestureSystemState()["menu"] := MenuObj.Handle
	if !Registered {
		OnMessage(0x117, GestureSystemOnInitPopup)
		Registered := true
	}
}
