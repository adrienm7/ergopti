; infra/tap_keys.ahk

; ==============================================================================
; MODULE: Number-Row Tap Keys
; DESCRIPTION:
; The three keys at the edges of the number row, the key left of 1 (SC029) and
; the two right of 0 (SC00C, SC00D), each assignable to any catalogue action:
; their assignments, the predicate and the handler of their hotkeys
; (modules/shortcuts/tap_keys.ahk), and the live label the menu shows for each.
; A plain tap runs the action and the key is swallowed. With a modifier held, on
; the AltGr layer, or while the key is unassigned, the key keeps its normal
; behaviour: the layout emulation's character when that emulation remaps it,
; the OS layout's otherwise.
;
; FEATURES & RATIONALE:
; 1. Logic here, hotkeys apart: the unit suite includes this file without
;    registering a hotkey, as it does for every module whose hotkeys it tests.
; 2. A held key fires once. The hotkey thread waits for the release, and
;    AutoHotkey ignores (and still swallows) presses of a hotkey whose thread is
;    running, so auto-repeat cannot fire the action thirty times a second.
; 3. The menu names each key by the character a tap on it produces right now,
;    read from the emulation table in use or from the OS layout through
;    ToUnicodeEx without touching its dead-key state, never a fixed AZERTY or
;    Ergopti legend. _TapKeyOsProbe is the seam the unit suite replaces.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ Keys and assignments =======
; =======================================
; =======================================

; The tap keys in menu order, with their scancodes. Pinned to
; _shared/modules/actions/tap_keys.json by tools/test/test-tap-keys-single-source.cjs,
; which also checks the hotkeys name the same scancodes.
global TAP_KEY_ORDER := ["number_row_left", "number_row_right_1", "number_row_right_2"]
global TAP_KEY_SCANCODES := Map(
	"number_row_left", 0x29,
	"number_row_right_1", 0x0C,
	"number_row_right_2", 0x0D,
)

; Tap key id -> action id ("none" leaves the key alone). Read from
; [shortcuts.tap_keys] rather than from Features, which the Shortcuts master
; gate zeroes: the menu must still show and edit the assignments while the
; category is off, as every other row under an OFF category does.
global TapKeyAssignments := Map()

; The binding a tap key's action runs under and stores its parameter under.
; @param {String} Id A tap key id.
; @returns {String}
TapKeyBindingId(Id) {
	return GestureBindingId("tap_key", Id)
}

; Reads every tap key's assignment: the config value when present, the
; manifest default otherwise. An action the catalogue does not know leaves the
; key unassigned rather than falling back to the default, so a hand-edited typo
; cannot rebind a key to something the user never chose.
; @param {Map} Cache The parsed config (IniCacheGet's source).
TapKeysReadConfig(Cache) {
	global TapKeyAssignments, TAP_KEY_ORDER, GESTURE_ACTIONS
	Assignments := Map()
	for _, Id in TAP_KEY_ORDER {
		Value := IniCacheGet(Cache, "shortcuts.tap_keys", Id)
		if (Value == "_") {
			Entry := ManifestFindEntryByPath("shortcuts.tap_keys." . Id)
			if !(Entry is Map)
				throw Error("The manifest declares no shortcuts.tap_keys." . Id . ".")
			Value := Entry["default"]
		}
		if (Value == "none" || GESTURE_ACTIONS.Has(Value)) {
			Assignments[Id] := Value
		} else {
			LoggerWarn("TapKeys", "Tap key '{1}' holds unknown action '{2}' — left unassigned.", Id, Value)
			Assignments[Id] := "none"
		}
	}
	TapKeyAssignments := Assignments
	Described := ""
	for _, Id in TAP_KEY_ORDER
		Described .= (Described = "" ? "" : ", ") . Id . "=" . Assignments[Id]
	LoggerInfo("TapKeys", "Tap keys read: {1}.", Described)
}

; Assigns an action to a tap key, asking for its parameter first when it takes
; one, and persists both in one config batch, then reloads, as every other
; keyboard binding does, so the menu and the full save start from the new file.
; @param {String} Id A tap key id.
; @param {String} ActionName A catalogue action id, or "none".
; @returns {Boolean} False when nothing was committed.
SetTapKeyAction(Id, ActionName) {
	global TapKeyAssignments, TAP_KEY_SCANCODES
	if !TAP_KEY_SCANCODES.Has(Id)
		throw ValueError("Unknown tap key '" . Id . "'.")
	if !GestureAssignConfiguredAction(&TapKeyAssignments, "tap_key", "shortcuts.tap_keys", Id, ActionName)
		return false
	LoggerInfo("TapKeys", "Tap key '{1}' → '{2}'.", Id, ActionName)
	return ReloadPreservingSuspend()
}

; The configured tap owner of a scan code, independent of temporary gates.
; @param {Integer} Scan Native physical scan code.
; @returns {String} Assigned tap id, or empty when no assignment owns it.
TapKeyAssignedToScan(Scan) {
	global TapKeyAssignments, TAP_KEY_ORDER, TAP_KEY_SCANCODES, GESTURE_ACTIONS
	for Id in TAP_KEY_ORDER {
		Action := TapKeyAssignments.Get(Id, "none")
		if TAP_KEY_SCANCODES[Id] == Scan && Action != "none" && GESTURE_ACTIONS.Has(Action)
			return Id
	}
	return ""
}

; Whether the Shortcuts category lets the tap keys fire.
_TapKeysCategoryEnabled() {
	global CategoryEnabled
	return !IsSet(CategoryEnabled) || !(CategoryEnabled is Map) || CategoryEnabled.Get("Shortcuts", true)
}

; The #HotIf predicate of one tap key: assigned to a known action, and the
; Shortcuts category on. Evaluated by the keyboard hook on every press, so it
; only reads memory.
; @param {String} Id A tap key id.
; @returns {Boolean}
TapKeyShouldFire(Id) {
	global TapKeyAssignments, GESTURE_ACTIONS
	if !IsSet(TapKeyAssignments) || !IsSet(GESTURE_ACTIONS)
		return false
	Action := TapKeyAssignments.Get(Id, "none")
	return Action != "none" && GESTURE_ACTIONS.Has(Action) && _TapKeysCategoryEnabled()
}

; Runs a tap key's action, then holds the hotkey thread until the key is up so
; auto-repeat presses are swallowed instead of firing again.
; @param {String} Id A tap key id.
; @param {Func} WaitFn Waits for a key's release; KeyWait unless the unit suite
;   passes a recorder.
TapKeyFire(Id, WaitFn := "") {
	global TapKeyAssignments, TAP_KEY_SCANCODES
	if !HasMethod(WaitFn, "Call")
		WaitFn := KeyWait
	Action := TapKeyAssignments.Get(Id, "none")
	LoggerDebug("TapKeys", "Tap key '{1}' fired → '{2}'.", Id, Action)
	GestureInvokeAction(Action, TapKeyBindingId(Id))
	WaitFn.Call(Format("SC{:03X}", TAP_KEY_SCANCODES[Id]))
}





; ======================================
; ======================================
; ======= 2/ Live key labels ===========
; ======================================
; ======================================

; The OS calls a label needs, all in adapters/key_state.ahk; reading a dead key
; there leaves the keyboard state alone, so a label cannot arm it for the user's
; next keystroke. The unit suite passes a fake layout instead.
global _TapKeyOsProbe := {
	Hkl: () => GetForegroundKeyboardLayout(),
	ScToVk: KS_ScancodeToVk,
	ToUnicode: KS_KeyTextNoStateChange,
}

; The character the Ergopti emulation gives this scancode on its base layer
; while it remaps the digit row, or "" when the key is the OS layout's.
; @param {Integer} Scancode
; @returns {String}
_TapKeyEmulatedCharacter(Scancode) {
	global Features
	if !IsSet(Features) || !(Features is Map) || !Features.Has("layout")
		return ""
	if NumberRowEffectiveMode() != "digits"
		return ""
	Table := ErgoptiNumberRowEdgeMapping()
	return Table.Has(Scancode) ? Table[Scancode] : ""
}

; The character a plain tap on the key produces right now.
; @param {String} Id A tap key id.
; @param {Object} Probe The OS calls; defaults to the real ones.
; @returns {Map} Map("text", ..., "dead", Boolean); "text" is "" when the key
;   produces nothing printable.
TapKeyCharacter(Id, Probe := "") {
	global _TapKeyOsProbe, TAP_KEY_SCANCODES
	if !IsObject(Probe)
		Probe := _TapKeyOsProbe
	Scancode := TAP_KEY_SCANCODES[Id]
	Emulated := _TapKeyEmulatedCharacter(Scancode)
	if (Emulated != "")
		return Map("text", Emulated, "dead", false)
	Nothing := Map("text", "", "dead", false)
	Hkl := Probe.Hkl.Call()
	if (Hkl = 0)
		return Nothing
	Vk := Probe.ScToVk.Call(Scancode, Hkl)
	if (Vk = 0)
		return Nothing
	Result := Probe.ToUnicode.Call(Vk, Scancode, Hkl)
	Text := Result.Text
	; A control character (some layouts put one on an unused key) or a blank is
	; not something a label can show.
	if (Text = "" || Trim(Text) = "" || Ord(Text) < 0x20 || (Ord(Text) >= 0x7F && Ord(Text) <= 0x9F))
		return Nothing
	return Map("text", Text, "dead", Result.Count < 0)
}

; The key's name in a menu row: its character, a dead key's symbol with a hint,
; or a localized description of its position when it produces nothing printable.
; @param {String} Id A tap key id.
; @param {Object} Probe The OS calls; defaults to the real ones.
; @returns {String}
TapKeyDisplayName(Id, Probe := "") {
	Info := TapKeyCharacter(Id, Probe)
	if (Info["text"] = "")
		return t("menu.shortcuts.tap_keys." . Id)
	if Info["dead"]
		return StrReplace(t("menu.shortcuts.tap_keys.dead_key"), "{1}", Info["text"])
	return Info["text"]
}

; The list provider for the manifest's "tap_keys" entry: one row per key,
; "<key> : <action>", each opening the shared action picker. The labels are
; computed on every menu build, so a rebuild after a layout switch (which
; reloads the driver) or an emulation toggle shows the new characters.
; @param {Object} Probe The OS calls; defaults to the real ones.
; @returns {Array} Rows of Map("label", ..., "action", ...).
TapKeyRows(Probe := "") {
	global TapKeyAssignments, TAP_KEY_ORDER, GESTURE_ACTIONS
	Rows := []
	for _, Id in TAP_KEY_ORDER {
		Action := TapKeyAssignments.Get(Id, "none")
		ActionLabel := (Action != "none" && GESTURE_ACTIONS.Has(Action))
			? GestureActionDisplayLabel(Action, TapKeyBindingId(Id))
			: t("menu.shortcuts.tap_keys.unassigned")
		Name := TapKeyDisplayName(Id, Probe)
		Rows.Push(Map("label", Name . " : " . ActionLabel, "action", _TapKeyPickerOpener(Id, Name)))
	}
	return Rows
}

_TapKeyPickerOpener(Id, Name) {
	return (*) => ShowActionPicker(Name, TapKeyAssignments.Get(Id, "none"),
		(ActionName) => SetTapKeyAction(Id, ActionName), false, TapKeyBindingId(Id))
}
