; _shared/keyboard/engine/layers/script_chord_hint.ahk

; ==============================================================================
; MODULE: Script Chord Tray Hint (shared rule)
; DESCRIPTION:
; The AutoHotkey twin of hint_slot in _shared/keyboard/engine/layers/script_chords.lua:
; the slot whose chord the tray shows beside « Suspendre », « Recharger » and
; « Quitter » is the first slot, in catalogue order (the Shortcuts submenu's
; order), that holds the row's action while its chord runs. Two slots holding
; the same action show the first; none shows no hint. Both replay
; _shared/tests/corpus/shortcuts/script_chord_hint_vectors.json. Pure: the
; caller hands the slots and the live chords over.
; ==============================================================================

#Requires AutoHotkey v2.0

; The slot whose chord the tray shows beside an action's row.
; @param Slots {Array} The slot ids, in catalogue order.
; @param Assignments {Map} Slot id -> action id, the chords a press runs now;
;   a slot it lacks holds "none".
; @param ChordsOn {Boolean} The submenu's switch.
; @param Action {String} The tray row's action id.
; @return {String} The slot id, "" when no chord runs the action.
ScriptChordHintSlot(Slots, Assignments, ChordsOn, Action) {
	if !(Slots is Array) || !(Assignments is Map)
		throw TypeError("script chord hint: the slots and their assignments are required", -1)
	if Type(Action) != "String" || Action == "" || Action == "none"
		throw ValueError("script chord hint: the hint needs an action id", -1, Action)
	if !ChordsOn
		return ""
	for Slot in Slots {
		if Assignments.Get(Slot, "none") == Action
			return Slot
	}
	return ""
}
