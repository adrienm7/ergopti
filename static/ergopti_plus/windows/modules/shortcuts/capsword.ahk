; modules/shortcuts/capsword.ahk

; ==============================================================================
; MODULE: Shortcuts — CapsWord
; DESCRIPTION:
; CapsWord mode: auto-capitalises characters while the user types a word and
; deactivates as soon as Space, Enter, or a mouse click is detected.
; Reference: https://github.com/qmk/qmk_firmware/blob/master/users/drashna/keyrecords/capwords.md
; ==============================================================================

#Requires AutoHotkey v2.0




; Bound callback stored at module scope so Register/Unregister can use the same
; object reference — HookDispatcher identity-compares on Unregister, so a new
; .Bind() at unregister time would never match the registered one.
_CapsWord_OnMouseDown := _CapsWord_HandleMouseDown.Bind()

_CapsWord_HandleMouseDown(*) {
	if (GestureLeftClickHeld) {
		GestureReleaseLeftClick()
	}
	if (GestureRightClickHeld) {
		GestureReleaseRightClick()
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
		; Arm mouse-click cancellation via HookDispatcher so the mouse events go
		; through the unified fan-out rather than bypassing it with static hotkeys
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_LDOWN, _CapsWord_OnMouseDown)
		HookDispatcher.Register(HookDispatcherConst.EVT_MS_RDOWN, _CapsWord_OnMouseDown)
	} else {
		HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_LDOWN, _CapsWord_OnMouseDown)
		HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_RDOWN, _CapsWord_OnMouseDown)
	}
	UpdateCapsLockLED()
}

DisableCapsWord() {
	global CapsWordEnabled := False
	; Always unregister on deactivation — Unregister is a no-op if not registered,
	; so calling it unconditionally is safe and prevents listener leaks on any
	; deactivation path (Space, Enter, or mouse click triggering this directly)
	HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_LDOWN, _CapsWord_OnMouseDown)
	HookDispatcher.Unregister(HookDispatcherConst.EVT_MS_RDOWN, _CapsWord_OnMouseDown)
	UpdateCapsLockLED()
}

; UpdateCapsLockLED is the SINGLE owner of the physical CapsLock LED. Three
; logical states can independently want the LED lit: CapsWord, the nav layer,
; and a real hardware CapsLock toggle (AltGr+CapsLock). Computing the LED from
; the OR of all three — instead of letting each state drive SetCapsLockState
; on its own — keeps the LED a reliable indicator no matter how the three are
; interleaved. ToggleCapsLock flips the hardware toggle then routes through
; here so the LED can never disagree with the union of the logical states.
UpdateCapsLockLED() {
	if CapsWordEnabled or LayerEnabled or GetKeyState("CapsLock", "T") {
		SetCapsLockState("On")
	} else {
		SetCapsLockState("Off")
	}
}

; Defines what deactivates the CapsLock triggered by CapsWord
#HotIf CapsWordEnabled
SC039::
{
	TextPressKey("Space", [])
	; A lost key-up must not leave CapsWord active forever after the visible space
	try {
		KeyWait("SC039", "T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)
	} finally {
		DisableCapsWord()
	}
}

; Big Enter key
SC01C::
{
	TextPressKey("Enter", [])
	DisableCapsWord()
}
#HotIf
