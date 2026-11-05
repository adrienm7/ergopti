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

; Configures the next non-modifier key as the capture endpoint. Kana AltGr
; has both a scan-code identity and a distinct virtual key; InputHook combines
; both option tables, so either residual EndKey flag would consume the modifier.
; @param {InputHook} Hook The private capture before it is started.
StickyModifierConfigureHook(Hook) {
	Hook.VisibleNonText := false
	Hook.KeyOpt("{All}", "E")
	Hook.KeyOpt("{LCtrl}{RCtrl}{LAlt}{RAlt}{LShift}{RShift}{LWin}{RWin}", "-E+V")
	for Key in [KS_AltGrKeyName(), KS_AltGrSendKey()] {
		if Key != "" && Key != "RAlt"
			Hook.KeyOpt("{" . Key . "}", "-E+V")
	}
}

; Presses the next key with the sticky action's modifiers, once. The key itself is
; withheld until then; intervening modifiers pass through and their captured
; flags accompany the replay. The one-shot Shift timeout ends the wait.
; @param {String} ActionId A sticky_* action id other than sticky_shift.
; @returns {Boolean} True when a key was pressed with them.
StickyModifier(ActionId) {
	if A_IsSuspended
		return false
	Held := StickyModifierNames(ActionId)
	TimeoutSec := (IsSet(ONE_SHOT_SHIFT_TIMEOUT_SEC) and ONE_SHOT_SHIFT_TIMEOUT_SEC > 0) ? ONE_SHOT_SHIFT_TIMEOUT_SEC : 2
	Hook := InputHook("L0 T" . TimeoutSec)
	StickyModifierConfigureHook(Hook)
	OwnerToken := SIHO_StartOwned(Hook, "sticky-modifier", true)
	if !OwnerToken
		return false
	try Hook.Wait()
	finally CaptureSettled := SIHO_StopOwned(OwnerToken, Hook)
	if !CaptureSettled || A_IsSuspended || Hook.EndReason != "EndKey"
		return false
	; Native input can release a modifier before Wait unwinds. EndMods owns the
	; flags of the captured key; current keyboard state or Blind would lose them.
	CapturedMods := Hook.EndMods
	Seen := Map()
	for Name in Held
		Seen[Name] := true
	for Symbol, Name in Map("^", "Ctrl", "!", "Alt", "+", "Shift", "#", "Win") {
		if InStr(CapturedMods, Symbol) && !Seen.Has(Name) {
			Held.Push(Name)
			Seen[Name] := true
		}
	}
	return TextPressKey(Hook.EndKey, Held) ? true : false
}
