; tests/fixtures/input_probe_hotkey_owner_body.ahk

; ==============================================================================
; MODULE: Input Probe Native Hotkey Owner Fixture
; DESCRIPTION:
; Real hook dispatch in a tree-owned child with an exact private Edit target.
; F24 never writes user text; every injection first proves native focus ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

global _IPHO_State := { Original: 0, Probe: 0 }
global _IPHO_Window := Gui()
global _IPHO_Field := _IPHO_Window.AddEdit("w200 r2")
_IPHO_Window.Show()
_IPHO_Field.Focus()
SetTimer(_IPHO_Run, -20)
Persistent()

_IPHO_Original(*) {
	global _IPHO_State
	_IPHO_State.Original += 1
}

_IPHO_Probe(*) {
	global _IPHO_State
	_IPHO_State.Probe += 1
}

_IPHO_Condition(*) {
	return true
}

_IPHO_Assert(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_IPHO_Emit() {
	global _IPHO_Window, _IPHO_Field
	_IPHO_Assert(InputProbeNativeWaitActive(_IPHO_Window.Hwnd, 1), "The private window must become active")
	_IPHO_Assert(InputProbeNativeOwnsKeyboard(_IPHO_Window.Hwnd, _IPHO_Field.Hwnd), "The private Edit must own keyboard focus")
	SendLevel(1)
	SendEvent("{vk87sc076}")
	Sleep(80)
}

_IPHO_Run() {
	global _IPHO_State, _IPHO_Window
	Code := 1
	try {
		Mode := A_Args[1]
		if Mode == "conditional"
			HotIf(_IPHO_Condition)
		Key := Mode == "virtual-key" ? "*vk87" : "*SC076"
		Hotkey(Key, _IPHO_Original, Mode == "global-disabled" ? "Off I0" : "On I0")
		HotIf()
		_IPHO_Emit()
		Enabled := Mode != "global-disabled"
		_IPHO_Assert(_IPHO_State.Original == (Enabled ? 1 : 0), "The initial original callback state must be observed")
		Loop 3 {
			Before := _IPHO_State.Original
			InputProbeNativeHotkeyOn("*SC076", _IPHO_Probe)
			_IPHO_Emit()
			if Mode == "conditional" {
				_IPHO_Assert(_IPHO_State.Original == Before + 1, "An earlier conditional owner must remain callable")
				_IPHO_Assert(_IPHO_State.Probe == 0, "The earlier conditional owner retains precedence")
			} else {
				_IPHO_Assert(_IPHO_State.Original == Before, "The probe must exclusively receive the active diagnostic key")
				_IPHO_Assert(_IPHO_State.Probe == A_Index, "The actual diagnostic callback must run once per cycle")
			}
			InputProbeNativeHotkeyOff("*SC076")
			Before := _IPHO_State.Original
			_IPHO_Emit()
			_IPHO_Assert(_IPHO_State.Original == Before + (Enabled ? 1 : 0), "Stopping the probe must preserve the prior callback and enabled state")
			_IPHO_Assert(_IPHO_State.Probe == (Mode == "conditional" ? 0 : A_Index), "The retired diagnostic callback must stay silent")
		}
		if Mode == "global-disabled" {
			; On and Off must also leave registration in the default context.
			Hotkey(Key, "On")
			_IPHO_Emit()
			_IPHO_Assert(_IPHO_State.Original == 1, "Re-enabling the original must retain its original callback")
			_IPHO_Assert(_IPHO_State.Probe == 3, "Re-enabling the original must not resurrect the probe")
		}
		FileAppend("PASS input-probe-entry " . Mode . " original=" . _IPHO_State.Original . " probe=" . _IPHO_State.Probe . "`n", "*")
		Code := 0
	} catch as Failure {
		FileAppend("FAIL input-probe-hotkey-owner " . Failure.Message . "`n", "*")
	} finally {
		_IPHO_Window.Destroy()
		ExitApp(Code)
	}
}
