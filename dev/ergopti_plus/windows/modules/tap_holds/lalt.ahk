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
	return ResolveHoldModifierKey(TapHoldHoldModifier(TapHold, "left_alt"), "left_alt")
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
	; Arm LShift for the hold, then release it in a finally so it can NEVER latch.
	; The wait is capped (U T<timeout>) so a lost SC038 key-up (focus stolen by a
	; UAC prompt, Suspend toggled mid-press) cannot block the release forever.
	TapHoldSyntheticKeyDown("LShift")
	try {
		KeyWait("SC038", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp("LShift")
	}
}
#HotIf







; ======= 4.2) tab+layer tap =======

#HotIf TapHoldTapAction(TapHold, "left_alt") == "tab" and not LayerEnabled
SC038::
{
	UpdateLastSentCharacter("LAlt")

	ActivateLayer()
	try {
		; The cap is a failsafe for waits that hold a SYNTHETIC modifier Down: those
		; must never latch it forever if the key-up event is lost. A hold LAYER holds no
		; synthetic key, so there is nothing to latch. Applied verbatim, the cap simply
		; dropped the layer out from under the user after five seconds of legitimate
		; navigation, and base-layer letters then landed in the document until it
		; re-armed. Re-arm the wait instead while the key is still physically down: every
		; iteration stays bounded, which is the property test_hold_layer_release_bounded
		; pins, and a timeout with the key already up means the key-up really was lost --
		; exactly the case the failsafe exists for.
		while !KeyWait("SC038", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
			if !GetKeyState("SC038", "P")
				break
		}
	} finally {
		DisableLayer()
	}

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
	tap := ((Now - CharacterSentTime) <= TapHoldDuration(TapHold, "left_alt") * 1000)
	if (tap and (Now - CharacterSentTime) >= TapMinDurationMs()) { ; TapMinDurationMs floor suppresses spurious taps when LAlt is brushed mid-roll
		TapHoldDispatchTap("left_alt", LLM_Tooltip_FireTabOrAccept.Bind(""))
	}
}

SC02A & SC038:: TextPressKey("Tab", "Shift") ; LShift held
; RCtrl+LAlt emits Shift+Tab only when right_ctrl IS the one-shot-shift key. A
; runtime `if` around a `::` definition does NOT gate its registration in AHK v2
; (hotkeys are load-time constructs), so the old `if` here was dead and the combo
; fired for every config. The extra condition must live in the #HotIf, which is
; re-evaluated live on each press so a tray change takes effect without a reload.
#HotIf TapHoldTapAction(TapHold, "left_alt") == "tab" and not LayerEnabled and TapHoldTapAction(TapHold, "right_ctrl") == "one_shot_shift"
SC11D & SC038:: {
	OneShotShiftFix()
	TextPressKey("Tab", "Shift")
}
#HotIf TapHoldTapAction(TapHold, "left_alt") == "tab" and not LayerEnabled
#SC038:: TextPressKey("Tab", "Win") ; Doesn't fire when SendInput is used
!SC038:: TextPressKey("Tab", "Alt")
#HotIf







; ======= 4.3) alt_tab_monitor tap =======

#HotIf TapHoldTapAction(TapHold, "left_alt") == "alt_tab_monitor" and not LayerEnabled
SC038::
{
	TapHoldSyntheticKeyDown("LAlt")
	tap := KeyWait("SC038", "T" . TapHoldDuration(TapHold, "left_alt"))
	if tap {
		; The synthetic LAlt Down armed above must always be released regardless
		; of Suspend state; only the AltTabMonitor() side effect is guarded —
		; native Suspend() never disarms this hotkey's own KeyWait/dispatch.
		TapHoldSyntheticKeyUp("LAlt")
		TapHoldDispatchTap("left_alt", AltTabMonitor)
	} else {
		; Bound the wait and release LAlt in a finally so a lost SC038 key-up (Alt+Tab
		; focus steal, a UAC prompt, or Suspend toggled mid-press) can never latch Alt
		; Down system-wide — this else is the SOLE release path (no SC038 Up:: fallback
		; exists here, unlike tab.ahk) (hold-modifier-unbounded-keywait)
		try {
			KeyWait("SC038", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
		} finally {
			TapHoldSyntheticKeyUp("LAlt")
		}
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
			if A_IsSuspended
				break
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
	tap := KeyWait("SC038", "T" . TapHoldDuration(TapHold, "left_alt"))
	if tap {
		if (
			A_PriorKey == "LAlt" ; Prevents spurious BackSpace when layer key was actually used
			and KS_IsUp("SC03A") ; Prevents spurious BackSpace on quick LAlt+CapsLock release
		) {
			TapHoldDispatchTap("left_alt", _LAltBackspaceTap)
		}
		return
	}
	ActivateLayer()
	try {
		; The cap is a failsafe for waits that hold a SYNTHETIC modifier Down: those
		; must never latch it forever if the key-up event is lost. A hold LAYER holds no
		; synthetic key, so there is nothing to latch. Applied verbatim, the cap simply
		; dropped the layer out from under the user after five seconds of legitimate
		; navigation, and base-layer letters then landed in the document until it
		; re-armed. Re-arm the wait instead while the key is still physically down: every
		; iteration stays bounded, which is the property test_hold_layer_release_bounded
		; pins, and a timeout with the key already up means the key-up really was lost --
		; exactly the case the failsafe exists for.
		while !KeyWait("SC038", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
			if !GetKeyState("SC038", "P")
				break
		}
	} finally {
		DisableLayer()
	}
}
#HotIf







; ======= 4.6) backspace tap + hold-modifier =======

; LAlt's default tap is "backspace", which _LAltIsSpecialTap() excludes from the
; generic hold-modifier block (4.7). Without this dedicated block, choosing
; tap=backspace with hold=<ctrl/shift/alt/alt_gr/win> matched NO #HotIf variant,
; so the chosen hold modifier silently did nothing and only hold=none (4.4) and
; hold=nav (4.5) worked — the « le hold ne peut être que la couche navigation »
; symptom. This mirrors block 4.7 but fires the backspace tap via BackSpaceLogic()
; instead of _LAltDispatch(), preserving the Ctrl+BS / Shift+Del tap semantics
; while honouring the configured hold modifier (CapsLock/Win already work this way).
#HotIf TapHoldTapAction(TapHold, "left_alt") == "backspace" and TapHoldHoldModifier(TapHold, "left_alt") != "" and not LayerEnabled
$SC038:: {
	ModKey := _LAltHoldModKey()
	HoldGuardMs := TapHoldDuration(TapHold, "left_alt") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("left_alt", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "LAlt (backspace) hold suppressed after long press because wheel activity was detected.")
		return
	}
	TapHoldSyntheticKeyDown(ModKey)
	tap := KeyWait("SC038", "T" . TapHoldDuration(TapHold, "left_alt"))
	if tap {
		TapHoldSyntheticKeyUp(ModKey)
		TapHoldDispatchTap("left_alt", _LAltBackspaceTap)
		return
	}
	; Bound the wait and release in a finally so a lost key-up or thrown Send can
	; never latch the modifier Down (tap_holds/constants.ahk explains the cap)
	try {
		KeyWait("SC038", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}
#HotIf







; ======= 4.7) Generic — hold-modifier, any other tap =======

; The gate deliberately does NOT require a configured tap action. The tray
; picker offers the hold options independently of the tap, persists the choice
; and puts a checkmark next to it — so requiring a tap here made « Natif / Rien »
; + hold=<modifier> match no variant at all, and the hold the user just picked
; did nothing. Holding on the hold alone is what the eight keys that never had
; the conjunct (CapsLock, Space, Escape, Enter, Backspace, Delete, Win) already
; do. The tap branch below is safe with no action configured:
; _TapHoldInvokeConfiguredAction logs a native pass-through and returns.
#HotIf not _LAltIsSpecialTap() and TapHoldHoldModifier(TapHold, "left_alt") != "" and not LayerEnabled
$SC038:: {
	ModKey := _LAltHoldModKey()
	tap := KeyWait("SC038", "T" . TapHoldDuration(TapHold, "left_alt"))
	if tap {
		_LAltDispatch()
		return
	}
	HoldGuardMs := TapHoldDuration(TapHold, "left_alt") * 1100
	if (HoldGuardMs < 250)
		HoldGuardMs := 250
	if (TapHoldShouldSuppressHold("left_alt", HoldGuardMs)) {
		if LoggerIsDebugEnabled()
			LoggerDebug("TapHold", "LAlt hold suppressed after long press because wheel activity was detected.")
		return
	}
	TapHoldSyntheticKeyDown(ModKey)
	; Bound the wait and release in a finally so a lost key-up or thrown Send can
	; never latch the modifier Down (tap_holds/constants.ahk explains the cap)
	try {
		KeyWait("SC038", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		TapHoldSyntheticKeyUp(ModKey)
	}
}
#HotIf







; ======= 4.8) Generic — hold-layer, any other tap =======

; No tap-action conjunct, for the reason given on block 4.7: a hold must arm on
; the hold alone or the picker offers a choice the driver silently ignores.
#HotIf not _LAltIsSpecialTap() and TapHoldHoldLayer(TapHold, "left_alt") != "" and not LayerEnabled
$SC038:: {
	UpdateLastSentCharacter("LAlt")

	ActivateLayer()
	try {
		; The cap is a failsafe for waits that hold a SYNTHETIC modifier Down: those
		; must never latch it forever if the key-up event is lost. A hold LAYER holds no
		; synthetic key, so there is nothing to latch. Applied verbatim, the cap simply
		; dropped the layer out from under the user after five seconds of legitimate
		; navigation, and base-layer letters then landed in the document until it
		; re-armed. Re-arm the wait instead while the key is still physically down: every
		; iteration stays bounded, which is the property test_hold_layer_release_bounded
		; pins, and a timeout with the key already up means the key-up really was lost --
		; exactly the case the failsafe exists for.
		while !KeyWait("SC038", "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
			if !GetKeyState("SC038", "P")
				break
		}
	} finally {
		DisableLayer()
	}

	Now := A_TickCount
	CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
	tap := ((Now - CharacterSentTime) <= TapHoldDuration(TapHold, "left_alt") * 1000)
	if (tap and (Now - CharacterSentTime) >= TapMinDurationMs() and A_PriorKey == "LAlt") { ; TapMinDurationMs floor suppresses spurious taps when LAlt is brushed mid-roll
		_LAltDispatch()
	}
}
#HotIf







; ======= 4.9) Generic — tap-only (hold=none, not a special tap) =======

#HotIf not _LAltIsSpecialTap() and TapHoldHoldModifier(TapHold, "left_alt") == "" and TapHoldHoldLayer(TapHold, "left_alt") == "" and TapHoldTapAction(TapHold, "left_alt") != "" and not LayerEnabled
SC038:: _LAltDispatch()
#HotIf







; ======= 4.10) Tap dispatch + BackSpaceLogic =======

_LAltDispatch() {
	_TapHoldFireAction("left_alt")
}

; Backspace has modifier-aware special handling, but is still a tap output and
; therefore runs inside TapHoldDispatchTap whenever LAlt has a hold behaviour.
_LAltBackspaceTap() {
	BackSpaceActionWithModifiers := BackSpaceLogic()
	if not BackSpaceActionWithModifiers {
		TextPressKey("BackSpace", "")
	}
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
