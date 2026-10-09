; platform/remap/altgr.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — AltGr
; DESCRIPTION:
; AltGr tap-hold: gated on not IsOnboardingActive() so the wizard's Edit
; fields receive native AltGr characters. AltGrTapHoldDispatchV2() maps the
; single configured tap_action to the corresponding key event.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================
; ========================
; ======= 6/ ALTGR =======
; ========================
; ========================

; Every standalone AltGr hotkey below is declared by its scan code, SC138, and
; never by the modifier name RAlt. AutoHotkey hooks "RAlt::" on the same scan
; code as a separate hotkey, and when none of its variants is eligible it does
; not fall back to the SC138 hotkeys: on a Kana-style layout, where only the
; SC138 variants are eligible, nothing fired at all. With one identity, AHK
; picks the eligible variant, so the standard and Kana criteria below only need
; to be mutually exclusive.

; The AltGr key prefixes the AltGr layer, the rolls and the script chords
; ("SC138 & X"), and AutoHotkey decides whether a prefix is armed while it
; handles the key's own press (hook.cpp Case #1, PrefixHasEnabledSuffixes),
; before it has recorded a modifier's physical state. Those combinations gate
; on the physical AltGr (IsRealAltGrPress), so on a layout without the AltGr
; fake LCtrl (QWERTY, or any AltGr layout while no "SC01D & SC138" is
; eligible) the prefix never armed on a press and the layer only worked after
; the key's auto-repeat. Where it did arm (every Kana press), AHK postponed each
; standalone SC138 hotkey without ~ to the key's release and fired it only if
; no other key was pressed: the held modifier never engaged, a 2 s hold still
; typed its tap, the navigation Escape came on release. This combination is
; always eligible and carries ~ on the prefix: the prefix now arms on every
; press, a standalone SC138 hotkey fires on the press whether or not it passes
; the key through (hook.cpp: "If suppress_this_prefix == false, this prefix
; key's key-down hotkey should fire immediately"), and each combination still
; checks the physical AltGr when its suffix fires, when that state is known. Its
; suffix, F24, is a key no keyboard here sends; its ~ passes it through anyway.
; With no criterion it arms SC138 during the first-run wizard too, where every
; other SC138 hotkey is false. The wizard's fields still get the host layout's
; native AltGr, with or without this ~: AutoHotkey reads SC138 as the RAlt
; modifier on every layout, and a modifier prefix no variant fires for is never
; suppressed (hook.cpp Case #1 allows the press when "this_key.as_modifiersLR").
; The ~ on the prefix is what fires the standalone SC138 hotkeys on the press
; (hook.cpp: "Record the use of ~ on this prefix even if it's a standard
; modifier which wouldn't normally be suppressed, since this also affects
; whether the key's own hotkeys fire on press vs. release"). Never drop it
; (test_altgr_prefix_arms_on_press.ahk).
; Suspend disables it with every hotkey, and the suspend drain waits for SC138
; on every layout since it now arms everywhere.
#HotIf
~SC138 & ~F24:: return

; Each variant's criterion is a named function in altgr_criteria.ahk, where the
; unit suite evaluates it: one AltGr press reaches exactly one owner.
;
; AltGr held as the layout's own AltGr, or holding nothing (a tap-only key),
; keeps its native function on every layout, as LShift held as Shift does: the
; press passes through (~), nothing is injected, and only the tap is the
; driver's. On a standard AltGr layout the suppressing "SC01D & SC138" of an
; AltGr hold made AHK send a blocked RAlt-up, which Windows answers with the
; fake LCtrl-up (hook.cpp: "Sending RAlt up on a layout with AltGr causes the
; system to send LCtrl up"); that LCtrl-up cleared the SC01D prefix, so every
; "SC138 & X" combination of the AltGr layer, the rolls and the AltGr shortcuts
; was dead for the whole hold, and the key typed the host layout's AltGr level
; of the Ergopti base character under the synthetic AltGr instead. The same
; happened to a combination that holds AltGr (Shift+AltGr, Ctrl+AltGr...), so
; on a standard AltGr layout it passes through too and its owner presses only
; the other members (AltGrHoldIsNative). A tap-only AltGr suppressed the key on
; QWERTY and Kana layouts only: RAlt+F4 was plain F4 and the Kana layout's own
; AltGr level was lost.
; The ~ on the SC01D prefix keeps a left_ctrl tap-hold's own hotkey firing on
; the LCtrl press: without it, SC01D was a suppressed prefix with enabled
; suffixes, so AutoHotkey postponed that hotkey to the LCtrl release, and LCtrl
; held as Alt then Tab gave Tab instead of Alt+Tab (hook.cpp: "Key-down is
; eligible but lacks ~, so should postpone until release"). The fake LCtrl of
; an AltGr press then reaches that hotkey too; the AltGr owner takes it back
; (TapHoldAltGrTakesItsLCtrl).
#HotIf AltGrOwnerPassesThrough(false)
~SC01D & ~SC138:: _AltGrHandleHold(true) ; AltGr on an AltGr layout: the fake LCtrl, then RAlt
~*SC138:: _AltGrHandleLonePassThrough() ; RAlt alone, e.g. on QWERTY, where it is a plain Alt
#HotIf AltGrOwnerPassesThrough(true)
~*$SC138:: _AltGrHandleHold(true) ; the Kana-style AltGr, SC138 alone
#HotIf

; Any other hold, a modifier, a combination or a layer, is the driver's: the
; press is suppressed and the owner presses the hold.
#HotIf AltGrOwnerHolds(false)
~SC01D & SC138:: ; AltGr on an AltGr layout
*SC138:: { ; RAlt alone, e.g. on QWERTY
	_AltGrHandleHold(false)
}
#HotIf AltGrOwnerHolds(true)
*$SC138:: _AltGrHandleHold(false)
#HotIf

; Own one AltGr press from key-down to release, then dispatch its tap.
; @param Passthrough {Boolean} True for a pass-through variant: the key itself
;        reached the system and is the hold's AltGr (or the key holds nothing);
;        the owner presses the rest of a combination.
_AltGrHandleHold(Passthrough) {
	; On an AltGr layout this press began with a fake LCtrl, which a left_ctrl
	; tap-hold holding another modifier may have taken as its own press.
	TapHoldAltGrTakesItsLCtrl(Passthrough)
	if (TapHoldHoldLayer(TapHold, "alt_gr") != "")
		Result := TapHoldOwnImmediateLayer("alt_gr", "SC138", TapHoldDuration(TapHold, "alt_gr"))
	else
		Result := TapHoldOwnImmediateModifier("alt_gr", "SC138",
			_AltGrHoldModKey(), TapHoldDuration(TapHold, "alt_gr"),
			,,,,,, Passthrough ? KS_AltGrKeyName() : false)
	if (Result["tap"] and TapHoldPriorKeyIsSelf("alt_gr")) {
		DisableCapsWord()
		AltGrTapHoldDispatchV2()
	}
}

; RAlt alone passed through, where right Alt is a plain Alt. Its release with
; nothing typed would put the focused window's menu bar in menu mode, and the
; tap output would land there; the hook passes that release before any thread
; runs, so the menu mask goes out now, while RAlt is still down. The mask key is
; ignored by the hooks and by A_PriorKey, so the tap guard is unchanged.
_AltGrHandleLonePassThrough() {
	if !TextSendMenuMask()
		try LoggerError("TapHoldDispatch", "Menu mask for a lone right Alt could not be sent; its release may open the window menu.")
	_AltGrHandleHold(true)
}

; Dispatch the configured tap action for "alt_gr".
; AltGr is already released when this fires (tap=true means key-up occurred),
; so the tap never carries AltGr itself; a keystroke tap still carries the
; modifiers held on other keys (TapHoldEmitKeyTap), Shift+Tab under Shift.
AltGrTapHoldDispatchV2() {
		_TapHoldFireAction("alt_gr")
}







; ====================================
; ====================================
; ======= 6.1) Own auto-repeat =======
; ====================================
; ====================================

; The key's own auto-repeat while an owner holds its suppressed press. Under
; a layer hold no variant above is eligible any more, and the navigation layer
; would map the repeat (CapsLock repeated its layer Backspace) or let it reach
; the system. Declared before nav_layer.ahk, so this variant wins there
; (see TapHoldPressIsOwned).
#HotIf TapHoldPressIsOwned("alt_gr")
*SC138:: return
#HotIf
