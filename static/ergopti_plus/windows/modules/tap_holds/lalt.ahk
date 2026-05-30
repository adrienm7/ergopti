; modules/tap_holds/lalt.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — LAlt
; DESCRIPTION:
; LAlt tap-hold: any action from GESTURE_ACTIONS on tap, any hold modifier or
; nav layer on hold.
;
; Architecture: specific variants that need special hold mechanics are handled
; by dedicated #HotIf blocks (higher priority, matched first). A generic
; fallback block covers every other tap+hold combination so the dispatcher
; does not need to be updated when new actions are added to the picker.
;
; Preserved subtleties:
; - one_shot_shift tap: 4-key guard prevents firing mid-shortcut when another
;   modifier is already held (RCtrl, CapsLock, LShift, LCtrl).
; - tab+layer: layer activated immediately on press, Tab emitted only if tap.
;   SC02A&SC038 and SC11D&SC038 hotkeys for Shift+Tab via LShift/RCtrl hold.
; - backspace plain: key-repeat loop with KEY_REPEAT_INITIAL_DELAY_MS / INTERVAL.
;   BackSpaceLogic() handles Ctrl+BS, Shift+BS, RCtrl-as-Shift combinations.
; - backspace+layer: same BackSpaceLogic(), but gated by A_PriorKey==LAlt and
;   KS_IsUp(CapsLock) to prevent spurious fires on LAlt+CapsLock quick release.
; - alt_tab_monitor+alt: pre-arms LAlt Down so the OS sees Alt held during the
;   hold phase; released immediately on tap to let AltTabMonitor() fire clean.
; - Generic hold-modifier fallback: pre-arms the modifier, releases on tap.
; - Generic hold-layer fallback: same layer pattern as tab+layer.
; - Generic tap-only fallback (hold=none): fires action immediately on press.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; =======================
; ======= 4/ LALT =======
; =======================
; ==============================

; Helper predicates -------------------------------------------------------

_LAltIsPlainBackspace() {
	return TapHoldTapAction(TapHold, "left_alt") == "backspace"
		and TapHoldHoldLayer(TapHold, "left_alt") == ""
		and TapHoldHoldModifier(TapHold, "left_alt") == ""
}

_LAltIsBackspaceLayer() {
	return TapHoldTapAction(TapHold, "left_alt") == "backspace"
		and TapHoldHoldLayer(TapHold, "left_alt") == "nav"
}

; True when the tap action is handled by a dedicated block above (special mechanics).
; Everything else falls through to the generic block.
_LAltIsSpecialTap() {
	local action := TapHoldTapAction(TapHold, "left_alt")
	return action == "one_shot_shift"
		or action == "tab"
		or action == "alt_tab_monitor"
		or action == "backspace"
}

; Return the AHK key name for the configured hold modifier.
_LAltHoldModKey() {
	switch TapHoldHoldModifier(TapHold, "left_alt") {
		case "ctrl":   return "LCtrl"
		case "shift":  return "LShift"
		case "alt":    return "LAlt"
		case "alt_gr": return "RAlt"
		case "win":    return "LWin"
		default:       return ""
	}
}




; ======= 4.1) one_shot_shift tap =======

#HotIf TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift" and not LayerEnabled
SC038:: {
	if (
		KS_IsDown("SC11D") ; RCtrl physically held
		or KS_IsDown("SC03A") ; CapsLock physically held
		or KS_IsDown("LShift") ; LShift physically held
		or KS_IsDown("LCtrl") ; LCtrl physically held
	) {
		; Another modifier already held — let the shortcut through without also firing OneShotShift
		return
	}

	TextPressKey("LAlt", "Up")
	OneShotShift()
	TextPressKey("LShift", "Down")
	KeyWait("SC038")
	TextPressKey("LShift", "Up")
}
#HotIf




; ======= 4.2) tab+layer tap =======

#HotIf TapHoldTapAction(TapHold, "left_alt") == "tab" and not LayerEnabled
SC038::
{
	UpdateLastSentCharacter("LAlt")

	ActivateLayer()
	KeyWait("SC038")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
	tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "left_alt") * 1000)
	if tap {
		TextPressKey("Tab", "")
	}
}

SC02A & SC038:: TextPressKey("Tab", "Shift") ; LShift held
if TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift" {
	SC11D & SC038:: {
		OneShotShiftFix()
		TextPressKey("Tab", "Shift")
	}
}
#SC038:: TextPressKey("Tab", "Win") ; Doesn't fire when SendInput is used
!SC038:: TextPressKey("Tab", "Alt")
#HotIf




; ======= 4.3) alt_tab_monitor tap =======

#HotIf TapHoldTapAction(TapHold, "left_alt") == "alt_tab_monitor" and not LayerEnabled
SC038::
{
	TextPressKey("LAlt", "Down")
	tap := KeyWait("SC038", "T" . TapHoldDuration(TapHold, "left_alt"))
	if tap {
		TextPressKey("LAlt", "Up")
		AltTabMonitor()
	} else {
		KeyWait("SC038")
		TextPressKey("LAlt", "Up")
	}
}
#HotIf




; ======= 4.4) backspace plain (key-repeat, no hold) =======

#HotIf _LAltIsPlainBackspace() and not LayerEnabled
*SC038::
{
	BackSpaceActionWithModifiers := BackSpaceLogic()
	if not BackSpaceActionWithModifiers {
		TextPressKey("BackSpace", "") ; Event keeps hotstring engine in sync
		Sleep(KEY_REPEAT_INITIAL_DELAY_MS)
		while KS_IsDown("SC038") { ; key-repeat loop while LAlt physically held
			TextPressKey("BackSpace", "")
			Sleep(KEY_REPEAT_INTERVAL_MS)
		}
	}
}
#HotIf




; ======= 4.5) backspace+layer tap =======

#HotIf _LAltIsBackspaceLayer() and not LayerEnabled
*SC038::
{
	UpdateLastSentCharacter("LAlt")

	ActivateLayer()
	KeyWait("SC038")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
	tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "left_alt") * 1000)

	if (
		tap
		and A_PriorKey == "LAlt" ; Prevents spurious BackSpace when layer key was actually used
		and KS_IsUp("SC03A") ; Prevents spurious BackSpace on quick LAlt+CapsLock release
	) {
		BackSpaceActionWithModifiers := BackSpaceLogic()
		if not BackSpaceActionWithModifiers {
			TextPressKey("BackSpace", "")
		}
	}
}
#HotIf




; ======= 4.6) Generic — hold-modifier, any other tap =======

#HotIf not _LAltIsSpecialTap() and TapHoldHoldModifier(TapHold, "left_alt") != "" and TapHoldTapAction(TapHold, "left_alt") != "" and not LayerEnabled
SC038:: {
	ModKey := _LAltHoldModKey()
	TextPressKey(ModKey, "Down")
	tap := KeyWait("SC038", "T" . TapHoldDuration(TapHold, "left_alt"))
	if tap {
		TextPressKey(ModKey, "Up")
		_LAltDispatch()
		return
	}
	KeyWait("SC038")
	TextPressKey(ModKey, "Up")
}
#HotIf




; ======= 4.7) Generic — hold-layer, any other tap =======

#HotIf not _LAltIsSpecialTap() and TapHoldHoldLayer(TapHold, "left_alt") != "" and TapHoldTapAction(TapHold, "left_alt") != "" and not LayerEnabled
SC038:: {
	UpdateLastSentCharacter("LAlt")

	ActivateLayer()
	KeyWait("SC038")
	DisableLayer()

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
	tap := (Now - CharacterSentTime <= TapHoldDuration(TapHold, "left_alt") * 1000)
	if (tap and A_PriorKey == "LAlt") {
		_LAltDispatch()
	}
}
#HotIf




; ======= 4.8) Generic — tap-only (hold=none, not a special tap) =======

#HotIf not _LAltIsSpecialTap() and TapHoldHoldModifier(TapHold, "left_alt") == "" and TapHoldHoldLayer(TapHold, "left_alt") == "" and TapHoldTapAction(TapHold, "left_alt") != "" and not LayerEnabled
SC038:: _LAltDispatch()
#HotIf




; ======= 4.9) Tap dispatch + BackSpaceLogic =======

_LAltDispatch() {
	_TapHoldFireAction("left_alt")
}

BackSpaceLogic() {
	RCtrlIsOneShotShift := TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift"

	if (
		KS_IsDown("SC01D") ; LCtrl physically held
		and KS_IsDown("Shift") ; Shift physically held
	) {
		TextPressKey("Delete", "Ctrl")
		return True
	} else if (
		KS_IsDown("SC11D") ; RCtrl physically held
		and not RCtrlIsOneShotShift
		and KS_IsDown("Shift") ; Shift physically held
	) {
		TextPressKey("Delete", "Ctrl")
		return True
	} else if (
		KS_IsDown("SC01D") ; LCtrl physically held
		and RCtrlIsOneShotShift
		and KS_IsDown("SC11D") ; RCtrl physically held (acting as Shift)
	) {
		OneShotShiftFix()
		TextPressKey("Right", "Ctrl")
		TextPressKey("BackSpace", "Ctrl") ; = ^Delete without triggering Ctrl+Alt+Delete
		return True
	} else if (
		RCtrlIsOneShotShift
		and KS_IsDown("SC11D") ; RCtrl physically held (acting as Shift)
	) {
		OneShotShiftFix()
		TextPressKey("Right", "")
		TextPressKey("BackSpace", "") ; = Delete without triggering Ctrl+Alt+Delete
		return True
	} else if KS_IsDown("Shift") {
		TextPressKey("Delete", "")
		return True
	} else if KS_IsDown("SC01D") { ; LCtrl physically held
		TextPressKey("BackSpace", "Ctrl")
		return True
	} else if (
		not RCtrlIsOneShotShift
		and KS_IsDown("SC11D") ; RCtrl physically held
	) {
		TextPressKey("BackSpace", "Ctrl")
		return True
	}
	return False
}
