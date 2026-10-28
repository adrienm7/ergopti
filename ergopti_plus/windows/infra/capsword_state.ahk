; infra/capsword_state.ahk

; ==============================================================================
; MODULE: CapsWord State
; DESCRIPTION:
; The state machine of CapsWord and of the CapsLock LED it shares with the
; user's genuine CapsLock intent: what a toggle arms, what a deactivation
; disarms, which pointer kinds let go of a held gesture click, and when the LED
; is lit. modules/shortcuts/capsword.ahk keeps only the two native delimiter
; hotkeys and thin entry points over these functions, so the unit suite drives
; the behaviour here without registering a hotkey or touching the real LED.
;
; FEATURES & RATIONALE:
; 1. Ports: every effect on the system (the auto-off arming, the LED, the tray
;    indicator, the gesture click release) is a port the caller may replace.
;    The defaults are the real ones; a test passes a Map with the keys it wants
;    to observe ("arm", "disarm", "set_led", "nav_indicator", "left_held",
;    "right_held", "release_left", "release_right").
; 2. Parse-time safe end callback: a key combination bound to caps_word fires
;    from a parse-time-armed hotkey long before auto-exec reaches the module's
;    include position, so the callback handed to the auto-off listeners comes
;    from a function with a static initializer, never from a module-scope
;    global. It returns the same object every call.
; 3. The LED has one owner: it is lit by CapsWord or by the user's genuine
;    CapsLock intent (_HardwareCapsLockOn, written only by ToggleCapsLock). It
;    is never re-derived from GetKeyState, which would read its own output back.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ Default ports =======
; ================================
; ================================

; The real effects, resolved when asked: the gesture owner is included after
; this file, so its functions are looked up at call time.
; @returns {Map} Port name -> function.
_CapsWordDefaultPorts() {
	return Map(
		"arm", CapsWordAutoOffArm,
		"disarm", CapsWordAutoOffDisarm,
		"set_led", (State) => SetCapsLockState(State),
		"nav_indicator", (Active) => NavigationLayerUpdateIndicator(Active),
		"left_held", () => GestureLeftClickHeld,
		"right_held", () => GestureRightClickHeld,
		"release_left", () => GestureReleaseLeftClick(),
		"release_right", () => GestureReleaseRightClick())
}

; The function a port names: the caller's replacement, else the real effect.
; @param Ports {Map|String} The caller's replacements, "" for none.
; @param Name {String} The port.
_CapsWordPort(Ports, Name) {
	if Ports is Map && Ports.Has(Name)
		return Ports[Name]
	Defaults := _CapsWordDefaultPorts()
	if !Defaults.Has(Name)
		throw ValueError("CapsWord has no port '" . Name . "'.")
	return Defaults[Name]
}





; ===============================
; ===============================
; ======= 2/ End callback =======
; ===============================
; ===============================

; Bound end callback of the auto-off listeners. The static initializer runs on
; the first call, any time after parse, and returns the SAME object every call.
; @returns {BoundFunc}
CapsWordEndCallback() {
	static Bound := CapsWordHandleAutoOff.Bind()
	return Bound
}

; Ends CapsWord for the auto-off listeners. A click that ends it first lets go
; of a gesture click-hold, as the click handler always did.
; @param Reason {String} Why CapsWord ends (the auto-off module logs it).
; @param Kind {String} The pointer kind, "" for a key or the delay.
; @param Ports {Map} Optional port replacements.
CapsWordHandleAutoOff(Reason, Kind, Ports := "") {
	if Kind == "left_click" || Kind == "right_click" {
		if _CapsWordPort(Ports, "left_held").Call()
			_CapsWordPort(Ports, "release_left").Call()
		if _CapsWordPort(Ports, "right_held").Call()
			_CapsWordPort(Ports, "release_right").Call()
	}
	CapsWordDeactivate(Ports)
}





; =================================
; =================================
; ======= 3/ Toggle and LED =======
; =================================
; =================================

; Flips CapsWord. Arming and disarming go through the auto-off module, which
; subscribes through HookDispatcher, never with static mouse hotkeys.
; @param Ports {Map} Optional port replacements.
CapsWordActivationToggle(Ports := "") {
	global CapsWordEnabled := not CapsWordEnabled
	if CapsWordEnabled
		_CapsWordPort(Ports, "arm").Call(CapsWordEndCallback())
	else
		_CapsWordPort(Ports, "disarm").Call()
	CapsWordSyncLed(Ports)
}

; Ends CapsWord on every path (a delimiter, the delay, a pointer kind, CapsLock,
; a pause). Disarming is unconditional: a no-op when nothing is armed, so no
; listener or timer leaks.
; @param Ports {Map} Optional port replacements.
CapsWordDeactivate(Ports := "") {
	global CapsWordEnabled := False
	_CapsWordPort(Ports, "disarm").Call()
	CapsWordSyncLed(Ports)
}

; Whether the CapsLock LED (and toggle) is on: CapsWord, or the user's genuine
; CapsLock intent. Navigation has its own tray indicator and never lights it.
; @returns {Boolean}
CapsWordLedWanted() {
	global _HardwareCapsLockOn
	return (CapsWordEnabled or _HardwareCapsLockOn) ? true : false
}

; Writes the LED once and refreshes the navigation indicator.
; @param Ports {Map} Optional port replacements.
CapsWordSyncLed(Ports := "") {
	global _HardwareCapsLockOn
	LedOn := CapsWordLedWanted()
	_CapsWordPort(Ports, "set_led").Call(LedOn ? "On" : "Off")
	_CapsWordPort(Ports, "nav_indicator").Call(LayerEnabled and !A_IsSuspended)
	try {
		if LoggerIsDebugEnabled() {
			LoggerDebug("CapsLockState",
				"LED synchronized: led={1}, capsword={2}, nav_layer={3}, hardware_caps_lock={4}.",
				LedOn ? "on" : "off", CapsWordEnabled ? "on" : "off",
				LayerEnabled ? "on" : "off", _HardwareCapsLockOn ? "on" : "off")
		}
	}
}
