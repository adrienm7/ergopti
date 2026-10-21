; modules/keymap/layout/number_row_send.ahk

; ==============================================================================
; MODULE: Number Row Send Handlers
; DESCRIPTION:
; What the number-row hotkeys of modules/keymap/layout.ahk run: « symbols
; first », the Shift level of « digits first », the reordered edge keys and the
; shifted-symbol emit they share. The hotkeys and their criteria stay in
; layout.ahk; these handlers hold no hotkey, so the headless E2E harness
; (tests/e2e) replays them on the real keyboard layouts of the machine.
;
; FEATURES & RATIONALE:
; 1. Each level is read again on the layout of the press: a layout switch
;    between the criterion and the handler's thread leaves nothing to type,
;    which is logged.
; 2. Every emit takes Critical("On"), the atomicity contract of _RemapEmit
;    (remap-emit-critical-uneven), and records the character only when it
;    reached the screen (_EmitReachedScreen).
; 3. Every emit goes through NumberRowSendEvent: SendEvent, or the recorder a
;    test harness installs (_SendHook), so a replay types nothing.
; ==============================================================================

#Requires AutoHotkey v2.0




/**
 * The number row's one send primitive: SendEvent, or the recorder a test
 * harness installs in _SendHook (as the hotstring engine's sends use it).
 * @param {String} Keys The SendEvent argument.
 */
NumberRowSendEvent(Keys) {
	global _SendHook
	if IsSet(_SendHook) && _SendHook {
		Hook := _SendHook
		Hook.Call("SendEvent", Keys)
		return
	}
	SendEvent(Keys)
}

; « Also reorder the three edge keys »: the other level of the effective
; layout. A registry layout types it through its own action machine.
_NumberRowEdgeSend(Sc, Shift, *) {
	Hkl := NumberRowForegroundLayout()
	Caps := KS_CapsLockToggleState()
	Text := NumberRowEdgeText(Sc, Shift, Hkl, Caps)
	if Text == "" {
		try LoggerWarn("Layout", "SC{1:03X}: the edge keys are no longer reordered on the layout of the press; nothing typed.", Sc)
		return
	}
	if _DigitRowEffectiveKey(Sc, Hkl, Caps)["source"] == "emulated" {
		_KLE_Emit(Format("SC{:03X}", Sc), !Shift, false)
		return
	}
	_DigitShiftSend(Text)
}

; « Symbols first » on a row no registry layout owns.
_NumberRowSymbolsFirstSend(Sc, Shift, *) {
	Text := NumberRowSymbolsFirstText(Sc, Shift, NumberRowForegroundLayout(), KS_CapsLockToggleState())
	if Text == "" {
		try LoggerWarn("Layout", "SC{1:03X}: symbols first no longer applies on the layout of the press; nothing typed.", Sc)
		return
	}
	_DigitShiftSend(Text)
}

; The Shift level of « digits first »: the effective layout's unshifted symbol.
_DigitRowSwapIsLive(Sc, ForegroundFn := 0, *) {
	if TapHoldKanaAltGrHeld()
		return false
	Hkl := IsObject(ForegroundFn) ? ForegroundFn.Call() : GetForegroundKeyboardLayout()
	return _DigitRowSwapResolution(Sc, Hkl)["swap"]
}

_DigitRowSwapSend(Sc, ForegroundFn := 0, *) {
	Hkl := IsObject(ForegroundFn) ? ForegroundFn.Call() : GetForegroundKeyboardLayout()
	Resolution := _DigitRowSwapResolution(Sc, Hkl)
	if !Resolution["swap"] {
		try LoggerWarn("Layout", "Shift+SC{1:03X}: the foreground layout changed during the press; nothing typed.", Sc)
		return
	}
	if Resolution["source"] == "emulated" {
		; A real press, unlike the neutral-state probe, advances the source's own
		; action/dead-key machine on its effective unshifted level.
		_KLE_Emit(Format("SC{:03X}", Sc), false, false)
		return
	}
	if Resolution["source"] == "builtin" && Resolution["descriptor"]["Kind"] != "text" {
		; The shipped Ergopti rows type text; a dead key here has no emitter.
		try LoggerError("Layout", "Shift+SC{1:03X}: the built-in row's unshifted level is not text ({2}); nothing typed.",
			Sc, Resolution["descriptor"]["Kind"])
		return
	}
	; Native symbols retain the established Unicode path and emission timing.
	_DigitShiftSend(Resolution["descriptor"]["Text"])
}

; The shifted-symbol send.
_DigitShiftSend(Symbol, *) {
	; Critical("On") so this shifted-symbol emit shares the one atomicity
	; contract with _RemapEmit / _DigitRowDown and cannot interleave with a
	; neighbouring remap's SendEvent (remap-emit-critical-uneven).
	Critical("On")
	; SendEvent {Text} bypasses the keyboard hook and sends the Unicode
	; character directly, so the SC002–SC00B digit remaps never interfere.
	NumberRowSendEvent("{Text}" . Symbol)
	; Same rule as _RemapEmit: an armed dead-key hook eats this character, so it
	; must not be recorded as having reached the screen.
	if _EmitReachedScreen()
		UpdateLastSentCharacter(Symbol)
}
