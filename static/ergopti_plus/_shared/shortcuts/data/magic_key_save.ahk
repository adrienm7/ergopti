; _shared/shortcuts/data/magic_key_save.ahk

; ==============================================================================
; MODULE: Shared Modifiers + Magic Key Save Rule
; DESCRIPTION:
; Portable AHK twin of _shared/shortcuts/engine/magic_key_save_core.lua: a
; shortcut chord on the layout's own magic key sends the same modifiers with S,
; ★ alone stays the magic key, and the chord selecting the layout's AltGr level
; (Ctrl+Alt without Win on Windows, Option on macOS, AltGr on Linux) keeps its
; character. Both implementations replay the common corpus
; (_shared/tests/corpus/shortcuts/magic_key_save_vectors.json); the Windows
; hotkeys are enumerated from this rule.
; ==============================================================================





; =====================================
; =====================================
; ======= 1/ The modifiers rule =======
; =====================================
; =====================================

/** Returns the letter the chord sends and the canonical modifier order. */
MagicKeySaveSpec() {
	static Spec := Map("save_key", "s", "order", ["ctrl", "alt", "shift", "meta"],
		"known", Map("windows", Map("ctrl", 1, "alt", 1, "shift", 1, "meta", 1),
			"macos", Map("ctrl", 1, "alt", 1, "shift", 1, "meta", 1),
			"linux", Map("ctrl", 1, "alt", 1, "shift", 1, "meta", 1, "altgr", 1)))
	return Spec
}

/** Whether the held modifiers select the layout's AltGr level on one OS. */
_MagicKeySaveAltGr(Os, Held) {
	switch Os {
		case "windows": return Held.Has("ctrl") && Held.Has("alt") && !Held.Has("meta")
		case "macos": return Held.Has("alt") && !Held.Has("ctrl") && !Held.Has("meta")
		case "linux": return Held.Has("altgr")
	}
	throw ValueError("Magic key save: unknown OS " . Os . ".")
}

/**
 * The modifiers a chord of the magic key sends with S.
 * @param {String} Os "windows", "macos" or "linux".
 * @param {Array} Held The held modifier names.
 * @returns {Map} "sends" (Array in canonical order, or 0) and "reason" ("" when it saves).
 */
MagicKeySaveDecide(Os, Held) {
	Spec := MagicKeySaveSpec()
	if !Spec["known"].Has(Os)
		throw ValueError("Magic key save: unknown OS " . Os . ".")
	if !(Held is Array)
		throw TypeError("Magic key save: the held modifiers are missing.")
	Set := Map()
	for Name in Held {
		if !Spec["known"][Os].Has(Name)
			throw ValueError("Magic key save: " . Os . " reports no modifier " . Name . ".")
		Set[Name] := true
	}
	Shortcut := Set.Has("ctrl") || Set.Has("alt") || Set.Has("meta")
	if !Shortcut && !Set.Has("altgr")
		return Map("sends", 0, "reason", "no_shortcut_modifier")
	if _MagicKeySaveAltGr(Os, Set)
		return Map("sends", 0, "reason", "altgr_level")
	if !Shortcut
		return Map("sends", 0, "reason", "no_shortcut_modifier")
	Sends := []
	for Name in Spec["order"] {
		if Set.Has(Name)
			Sends.Push(Name)
	}
	return Map("sends", Sends, "reason", "")
}

/**
 * Decides one press of a key with modifiers held.
 * @param {Map} Input "os", "held" and the boolean gates "paused", "replace_on",
 *   "chosen_source", "is_magic_key" and "shortcut_owns".
 * @returns {Map} "action" ("save" or "pass"), "sends" (Array or 0) and "reason".
 */
MagicKeySaveResolve(Input) {
	for Gate in ["paused", "replace_on", "chosen_source", "is_magic_key", "shortcut_owns"] {
		Value := Input.Get(Gate, "")
		if !(Value is Integer) || (Value != 0 && Value != 1)
			throw TypeError("Magic key save: the gate " . Gate . " is not a boolean.")
	}
	if Input["paused"]
		return Map("action", "pass", "sends", 0, "reason", "paused")
	if !Input["replace_on"]
		return Map("action", "pass", "sends", 0, "reason", "magic_key_not_replaced")
	if Input["chosen_source"]
		return Map("action", "pass", "sends", 0, "reason", "chosen_source")
	if !Input["is_magic_key"]
		return Map("action", "pass", "sends", 0, "reason", "not_magic_key")
	Decision := MagicKeySaveDecide(Input["os"], Input["held"])
	if !(Decision["sends"] is Array)
		return Map("action", "pass", "sends", 0, "reason", Decision["reason"])
	if Input["shortcut_owns"]
		return Map("action", "pass", "sends", 0, "reason", "shortcut_owns_chord")
	return Map("action", "save", "sends", Decision["sends"], "reason", "")
}





; ======================================
; ======================================
; ======= 2/ The Windows hotkeys =======
; ======================================
; ======================================

/**
 * Every Windows hotkey of the magic key the rule turns into its modifiers + S:
 * each exact combination of ^ ! + # holding a shortcut modifier, Ctrl+Alt
 * without Win (AltGr) excepted.
 * @param {String} Scan "SCnnn" of the layout's own magic key.
 * @returns {Array} Maps of "hotkey" ("^+SC02E"), "send" ("^+s") and "win_only"
 *   (true for "#SC02E", the Win variant the physical Win broker owns).
 */
MagicKeySaveWindowsHotkeys(Scan) {
	static Prefix := Map("ctrl", "^", "alt", "!", "shift", "+", "meta", "#")
	Names := MagicKeySaveSpec()["order"]
	Hotkeys := []
	loop 1 << Names.Length {
		Mask := A_Index - 1, Held := [], Combo := ""
		for Index, Name in Names {
			if Mask & (1 << (Index - 1)) {
				Held.Push(Name)
				Combo .= Prefix[Name]
			}
		}
		Decision := MagicKeySaveDecide("windows", Held)
		if !(Decision["sends"] is Array)
			continue
		Hotkeys.Push(Map("hotkey", Combo . Scan, "send", Combo . MagicKeySaveSpec()["save_key"],
			"win_only", Combo == "#"))
	}
	return Hotkeys
}
