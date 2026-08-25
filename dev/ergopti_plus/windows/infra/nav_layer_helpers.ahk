; infra/nav_layer_helpers.ahk

; ==============================================================================
; MODULE: Navigation Layer Helpers
; DESCRIPTION:
; Pure state-management functions for the navigation layer. Extracted here
; from platform/remap/nav_layer.ahk so the logic is testable without
; loading hotkey-registration code.
;
; FEATURES & RATIONALE:
; 1. ActivateLayer / DisableLayer: toggle the LayerEnabled global and update
;    the CapsLock LED indicator to reflect the active state visually.
; 2. SetNumberOfRepetitions / ResetNumberOfRepetitions: manage the numeric
;    multiplier read by ActionLayer to repeat navigation keystrokes.
; 3. ActionLayer: fire a SendInput payload then reset the repetition counter,
;    so every navigation keystroke is self-contained.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Layer state helpers =======
; ======================================
; ======================================

; Raised A_MaxHotkeysPerInterval ceiling used while the nav layer is engaged
; and restored on release — bursts (holding Ctrl+Shift+Right, scrolling the
; wheel right as the layer engages/disengages) must never trigger AHK's "too
; many hotkeys" warning. Single-sourced here so nav_layer.ahk's boot-time
; raise reads this same value instead of hardcoding its own number — the
; previous version had ActivateLayer LOWER this on key-down (exactly when
; bursts are about to happen) and DisableLayer raise it to a DIFFERENT
; hardcoded number on release, permanently clobbering the boot-time raise on
; every hold cycle.
global NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL := 1000

ActivateLayer() {
	; A hold-layer KeyWait can outlive the hotkey that started it: Suspend only
	; disarms future hotkeys, not an already-running pseudo-thread.  This is the
	; common final activation boundary for every hold-layer variant, so reject a
	; stale candidate here before mutating LayerEnabled or the CapsLock LED.
	if A_IsSuspended {
		try LoggerDebug("NavLayer", "Ignoring layer activation while the driver is suspended.")
		return false
	}
	global LayerEnabled := True
	; Bursts happen WHILE the layer is held active (rapid nav/scroll
	; keystrokes fire back-to-back), so the ceiling must be RAISED on
	; activation, not lowered.
	A_MaxHotkeysPerInterval := NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL
	ResetNumberOfRepetitions()
	UpdateCapsLockLED()
	return true
}

DisableLayer() {
	global LayerEnabled := False
	; Restore the same raised ceiling nav_layer.ahk set at boot rather than a
	; different hardcoded number — a burst can still be in flight at the exact
	; moment the hold key is released (e.g. a trailing wheel event), and there
	; is no separate "idle" ceiling single-sourced anywhere in this codebase.
	A_MaxHotkeysPerInterval := NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL
	UpdateCapsLockLED()
}

_TapHoldLayerWaitRelease(KeyName, TimeoutSec) {
	return KeyWait(KeyName, "U T" . TimeoutSec)
}

_TapHoldLayerKeyIsDown(KeyName) {
	return GetKeyState(KeyName, "P")
}

_TapHoldLayerTickNow() {
	return A_TickCount
}

; Own one hold-layer gesture from the physical key-down through release.  The
; layer is published before the first interruptible wait, so a second key that
; arrives immediately is routed by the layer.  A quick isolated release is
; reported as a tap only after DisableLayer has run.
TapHoldOwnImmediateLayer(KeyName, TapThresholdSec, WaitReleaseFn := 0,
	KeyIsDownFn := 0, TickNowFn := 0, ActivateFn := 0, DisableFn := 0) {
	if !IsObject(WaitReleaseFn)
		WaitReleaseFn := _TapHoldLayerWaitRelease
	if !IsObject(KeyIsDownFn)
		KeyIsDownFn := _TapHoldLayerKeyIsDown
	if !IsObject(TickNowFn)
		TickNowFn := _TapHoldLayerTickNow
	if !IsObject(ActivateFn)
		ActivateFn := ActivateLayer
	if !IsObject(DisableFn)
		DisableFn := DisableLayer

	StartedAt := TickNowFn.Call()
	if !ActivateFn.Call()
		return Map("activated", false, "tap", false, "elapsed_ms", 0)

	try {
		while !WaitReleaseFn.Call(KeyName, STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) {
			if !KeyIsDownFn.Call(KeyName)
				break
		}
	} finally {
		DisableFn.Call()
	}

	ElapsedMs := TickElapsed(StartedAt, TickNowFn.Call())
	return Map(
		"activated", true,
		"tap", ElapsedMs <= TapThresholdSec * 1000,
		"elapsed_ms", ElapsedMs)
}

ResetNumberOfRepetitions() {
	SetNumberOfRepetitions(1)
}

SetNumberOfRepetitions(NewNumber) {
	global NumberOfRepetitions := NewNumber
}

; Wrapper used by nav_layer.ahk hotkeys to read the repetition counter without
; coupling hotkey code to the global variable name directly.
AppState_GetNumberOfRepetitions() {
	global NumberOfRepetitions
	return NumberOfRepetitions
}

; Wrapper used by layout.ahk / nav_layer_helpers to update the repetition
; counter through a single named write path.
AppState_SetNumberOfRepetitions(N) {
	global NumberOfRepetitions := N
}

; Every nav-layer key routes through here, and almost every payload moves the
; caret or deletes text. The send is a SendInput at SendLevel 0, which the
; prefix watcher's InputHook filters out by design (``I1``), so none of the
; eight physical reset sites ever see it: without the declaration below the
; hotstring engine still believed the caret sat where the user stopped typing,
; and the next expansion backspaced over text at the NEW position.
ActionLayer(action) {
	; The adapter's key-press path owns declaration + SendInput as one Critical
	; transaction, then performs tooltip effects and error logging after release.
	_TextSenderSendInput(action, "key press")
	ResetNumberOfRepetitions()
}
