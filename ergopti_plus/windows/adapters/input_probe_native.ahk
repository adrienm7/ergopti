; adapters/input_probe_native.ahk

; ==============================================================================
; MODULE: Input Probe Native Adapter
; DESCRIPTION:
; The Win32 surface of the opt-in input probe (infra/input_probe.ahk): the
; low-level keyboard hook the hook-order check installs, the focus test of its
; target window, and the hotkey whose only job is to swallow the probe key. The
; probe keeps its measurements and verdicts; every native call stays here.
; ==============================================================================

#Requires AutoHotkey v2.0

; WH_KEYBOARD_LL
global INPUT_PROBE_NATIVE_WH_KEYBOARD_LL := 13





; ===========================================
; ===========================================
; ======= 1/ Target window and hotkey =======
; ===========================================
; ===========================================

/**
 * Whether the given windows still own the keyboard.
 * @param {Integer} GuiHwnd - The window that must be foreground.
 * @param {Integer} EditHwnd - The control that must have the focus.
 * @returns {Boolean}
 */
InputProbeNativeOwnsKeyboard(GuiHwnd, EditHwnd) {
	return DllCall("GetForegroundWindow", "Ptr") == GuiHwnd
		&& DllCall("GetFocus", "Ptr") == EditHwnd
}

/**
 * Waits until a window is active.
 * @param {Integer} Hwnd - The window handle.
 * @param {Number} Seconds - Longest wait.
 * @returns {Integer} 0 when the wait timed out.
 */
InputProbeNativeWaitActive(Hwnd, Seconds) {
	return WinWaitActive("ahk_id " . Hwnd, , Seconds)
}

/**
 * Registers only the probe-owned variant. Its stable always-true criterion
 * is eligible in every window without replacing a global user callback.
 * @param {String} Key - Hotkey name.
 * @param {Func} Callback - Called when the key fires.
 */
InputProbeNativeHotkeyOn(Key, Callback) {
	HotIf(_InputProbeNativeHotkeyCriterion)
	try Hotkey(Key, Callback, "On I0")
	finally HotIf()
}

/**
 * Turns the probe hotkey off again.
 * @param {String} Key - Hotkey name.
 */
InputProbeNativeHotkeyOff(Key) {
	HotIf(_InputProbeNativeHotkeyCriterion)
	try Hotkey(Key, "Off")
	finally HotIf()
}

; Function identity separates the diagnostic owner from every driver variant.
_InputProbeNativeHotkeyCriterion(*) {
	return true
}





; ================================
; ================================
; ======= 2/ Keyboard hook =======
; ================================
; ================================

/**
 * Passes a low-level keyboard event on to the next hook of the chain.
 * @param {Integer} Code - Hook code.
 * @param {Integer} WParam - Message.
 * @param {Integer} LParam - KBDLLHOOKSTRUCT pointer.
 * @returns {Integer} The next hook's result.
 */
InputProbeNativeCallNext(Code, WParam, LParam) {
	return DllCall("CallNextHookEx", "Ptr", 0, "Int", Code, "Ptr", WParam, "Ptr", LParam, "Ptr")
}

/**
 * Installs a low-level keyboard hook on this thread, the newest of the chain.
 * @param {Integer} Callback - CallbackCreate address.
 * @returns {Integer} The hook handle.
 */
InputProbeNativeHookInstall(Callback) {
	global INPUT_PROBE_NATIVE_WH_KEYBOARD_LL
	Hook := DllCall("SetWindowsHookExW", "Int", INPUT_PROBE_NATIVE_WH_KEYBOARD_LL, "Ptr", Callback,
		"Ptr", DllCall("GetModuleHandleW", "Ptr", 0, "Ptr"), "UInt", 0, "Ptr")
	if !Hook
		throw OSError(A_LastError, "SetWindowsHookExW")
	return Hook
}

/**
 * Removes a hook installed by InputProbeNativeHookInstall.
 * @param {Integer} Hook - The hook handle.
 */
InputProbeNativeHookRemove(Hook) {
	DllCall("UnhookWindowsHookEx", "Ptr", Hook)
}
