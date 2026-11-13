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
; flags accompany the replay. The one-shot timeout ends the wait (0: none).
; @param {String} ActionId A sticky_* action id other than sticky_shift.
; @returns {Boolean} True when a key was pressed with them.
StickyModifier(ActionId) {
	if A_IsSuspended
		return false
	Held := StickyModifierNames(ActionId)
	; 0 is no time limit: the hook then waits until a key spends it.
	Hook := InputHook("L0" . TapHoldOneShotHookTimeoutOption())
	StickyModifierConfigureHook(Hook)
	Custom := 0
	KeyName := KS_AltGrKeyName(), SendKey := KS_AltGrSendKey()
	if KeyName != "RAlt" {
		Custom := _SIHO_CustomModifierCapture(Hook, KeyName, SendKey)
		if !IsObject(Custom)
			return false
	}
	try {
		OwnerToken := SIHO_StartOwned(Hook, "sticky-modifier", true)
		if !OwnerToken
			return false
		try {
			Hook.Wait()
			if IsObject(Custom) && Hook.EndReason == "EndKey"
				if !_SIHO_CustomModifierSettle(Custom, Hook, OwnerToken)
					return false
		} finally CaptureSettled := SIHO_StopOwned(OwnerToken, Hook)
	} finally {
		if IsObject(Custom)
			_SIHO_CustomModifierRelease(Custom, Hook)
	}
	if !CaptureSettled || A_IsSuspended || Hook.EndReason != "EndKey"
		return false
	; Native input can release a modifier before Wait unwinds. EndMods owns the
	; flags of the captured key; current keyboard state or Blind would lose them.
	CapturedMods := Hook.EndMods
	if IsObject(Custom) {
		; The receipt may never borrow a different layout's native key identity.
		if !_SIHO_CustomModifierReplay(Custom, KS_AltGrKeyName(), KS_AltGrSendKey(), &Restore)
			return false
		; Preserve an original hold still down; only restore an endpoint modifier
		; that was released before replay. TextPressKey retains its normal ABI.
		if Restore
			Held.Push("AltGr")
	}
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
