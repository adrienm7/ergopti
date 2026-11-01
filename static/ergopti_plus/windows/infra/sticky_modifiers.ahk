; infra/sticky_modifiers.ahk

; ==============================================================================
; MODULE: Sticky Modifiers
; DESCRIPTION:
; The sticky_* actions of the catalogue on Windows: the next key is pressed with
; the action's modifiers, once, as the one-shot Shift does for Shift alone.
; ==============================================================================

#Requires AutoHotkey v2.0

; The modifiers a sticky action holds for one key, from its id. The catalogue
; spells them as macOS does: Cmd is the Windows key and Option is Alt.
; @param {String} ActionId A sticky_* action id other than sticky_shift.
; @returns {Array} TextPressKey's modifier names.
StickyModifierNames(ActionId) {
	static Names := Map("cmd", "Win", "option", "Alt", "ctrl", "Ctrl", "shift", "Shift")
	if (ActionId == "sticky_hyper")
		return ["Ctrl", "Alt", "Shift", "Win"]
	Held := []
	for Token in StrSplit(RegExReplace(ActionId, "^sticky_"), "_") {
		if !Names.Has(Token)
			throw ValueError("Unknown sticky modifier.", -1, ActionId)
		Held.Push(Names[Token])
	}
	return Held
}

; Presses the next key with the sticky action's modifiers, once. The key itself is
; withheld until then; a modifier pressed in between is left alone, and the timeout
; of the one-shot Shift ends the wait.
; @param {String} ActionId A sticky_* action id other than sticky_shift.
; @returns {Boolean} True when a key was pressed with them.
StickyModifier(ActionId) {
	if A_IsSuspended
		return false
	Held := StickyModifierNames(ActionId)
	TimeoutSec := (IsSet(ONE_SHOT_SHIFT_TIMEOUT_SEC) and ONE_SHOT_SHIFT_TIMEOUT_SEC > 0) ? ONE_SHOT_SHIFT_TIMEOUT_SEC : 2
	Hook := InputHook("L0 T" . TimeoutSec)
	Hook.KeyOpt("{All}", "E")
	Hook.KeyOpt("{LCtrl}{RCtrl}{LAlt}{RAlt}{LShift}{RShift}{LWin}{RWin}", "-E")
	OwnerToken := SIHO_StartOwned(Hook, "sticky-modifier", true)
	if !OwnerToken
		return false
	try Hook.Wait()
	finally CaptureSettled := SIHO_StopOwned(OwnerToken, Hook)
	if !CaptureSettled || A_IsSuspended || Hook.EndReason != "EndKey"
		return false
	return TextPressKey(Hook.EndKey, Held) ? true : false
}
