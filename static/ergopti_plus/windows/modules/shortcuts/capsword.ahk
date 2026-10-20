; modules/shortcuts/capsword.ahk

; ==============================================================================
; MODULE: Shortcuts — CapsWord
; DESCRIPTION:
; CapsWord mode: auto-capitalises characters while the user types a word and
; deactivates on what [shortcuts.caps_word] names (a delay, a delimiter, a
; pointer kind), through capsword_auto_off.ahk.
; Reference: https://github.com/qmk/qmk_firmware/blob/master/users/drashna/keyrecords/capwords.md
; ==============================================================================

#Requires AutoHotkey v2.0




; Bound end callback of the auto-off listeners, resolved through an accessor
; with a static initializer instead of a top-level `global := .Bind()`. A
; module-scope assignment executes only when auto-exec reaches this file's
; #Include position (~700 ms into boot), but ToggleCapsWord/DisableCapsWord are
; reachable far earlier — a key combination bound to caps_word fires from a
; parse-time-armed hotkey once its slots are read — so the old global was
; unset in that window and dereferencing it threw UnsetError -> ExitApp(1) via the
; pre-ready error net. The static initializer runs on first call (any time after
; parse) and returns the SAME object every call.
_CapsWord_Callback() {
	static Bound := _CapsWord_HandleAutoOff.Bind()
	return Bound
}

; Ends CapsWord for the auto-off listeners. A click that ends it first lets go
; of a gesture click-hold, as the click handler always did.
; @param Reason {String} Why CapsWord ends (the auto-off module logs it).
; @param Kind {String} The pointer kind, "" for a key or the delay.
_CapsWord_HandleAutoOff(Reason, Kind) {
	if (Kind == "left_click" || Kind == "right_click") {
		if (GestureLeftClickHeld) {
			GestureReleaseLeftClick()
		}
		if (GestureRightClickHeld) {
			GestureReleaseRightClick()
		}
	}
	DisableCapsWord()
}





; ===========================
; ===========================
; ======= 6/ CAPSWORD =======
; ===========================
; ===========================

ToggleCapsWord() {
	global CapsWordEnabled := not CapsWordEnabled
	if (CapsWordEnabled) {
		; The auto-off listeners subscribe through HookDispatcher, the unified
		; fan-out, never with static mouse hotkeys of their own.
		CapsWordAutoOffArm(_CapsWord_Callback())
	} else {
		CapsWordAutoOffDisarm()
	}
	UpdateCapsLockLED()
}

DisableCapsWord() {
	global CapsWordEnabled := False
	; Always disarm on deactivation — a no-op when nothing is armed, so calling
	; it unconditionally prevents listener and timer leaks on every path (a
	; delimiter, the delay, a pointer kind, CapsLock, a pause).
	CapsWordAutoOffDisarm()
	UpdateCapsLockLED()
}

; The user's genuine CapsLock intent, flipped only by ToggleCapsLock.
;
; This MUST NOT be re-derived from GetKeyState("CapsLock", "T"): that bit is the
; one SetCapsLockState below writes, so reading it back made the function's own
; output an input. Once CapsWord (or the nav layer) lit the LED, the next
; evaluation saw the toggle it had just set, concluded the user wanted CapsLock,
; and re-asserted it — so CapsLock survived CapsWord and everything kept typing
; in uppercase until the user toggled it by hand. Seeded from the real toggle
; once by the entry pre-pump owner, before a parse-time callback can run.
; This module must not re-seed it after an early user toggle.

; The CapsLock toggle changes native character case as well as its LED. Only
; CapsWord and the user's genuine CapsLock intent may drive it. Navigation has
; its own tray indicator: lighting this LED for the layer capitalised every
; unbound key, even when the layer had no bindings.
UpdateCapsLockLED() {
	global _HardwareCapsLockOn
	LedOn := CapsWordEnabled or _HardwareCapsLockOn
	SetCapsLockState(LedOn ? "On" : "Off")
	NavigationLayerUpdateIndicator(LayerEnabled and !A_IsSuspended)
	try {
		if LoggerIsDebugEnabled() {
			LoggerDebug("CapsLockState",
				"LED synchronized: led={1}, capsword={2}, nav_layer={3}, hardware_caps_lock={4}.",
				LedOn ? "on" : "off", CapsWordEnabled ? "on" : "off",
				LayerEnabled ? "on" : "off", _HardwareCapsLockOn ? "on" : "off")
		}
	}
}

; Space and Enter send their key themselves, at level 0, which the auto-off
; InputHook does not see: while their delimiter is checked they end CapsWord
; here. Unchecked, the criterion fails and the key stays native.
#HotIf CapsWordEnabled and CapsWordAutoOffEndsOnNativeKey("space")
SC039:: CapsWordAutoOffNativeKey("Space")

; Big Enter key
#HotIf CapsWordEnabled and CapsWordAutoOffEndsOnNativeKey("enter")
SC01C:: CapsWordAutoOffNativeKey("Enter")
#HotIf
