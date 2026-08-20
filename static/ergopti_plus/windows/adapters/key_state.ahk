; adapters/key_state.ahk

; ==============================================================================
; MODULE: KeyState Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the KeyState port contract. Wraps the AHK v2
; built-in GetKeyState() behind two stable functions so tap-hold logic and
; modifier-detection routines can query physical key state without coupling
; to AHK-specific function syntax.
;
; NAMING CONVENTION:
; Port method  → AHK name mapping:
;   KS_IsDown(keyName) → KS_IsDown(KeyName)
;   KS_IsUp(keyName)   → KS_IsUp(KeyName)
;
; PHYSICAL MODE:
; Both functions use the "P" (physical) mode of GetKeyState exclusively.
; Logical/toggle state (CapsLock LED, NumLock) is out of scope for this adapter.
;
; FAIL-SAFE:
; GetKeyState is wrapped in try/catch. An unknown key name or any AHK error
; returns 0 (false) from KS_IsDown and 1 (true) from KS_IsUp — an absent key
; is treated as "not pressed".
; ==============================================================================



; ===========================================
; ===========================================
; ======= 1/ Adapter Functions ==============
; ===========================================
; ===========================================

; Returns 1 when the key is physically held down, 0 otherwise.
; An unknown key name or any GetKeyState error yields 0 (not pressed).
; @param KeyName {String} Platform key identifier (e.g. "SC038", "LShift").
; @return {Integer} 1 if the key is currently down, 0 otherwise.
KS_IsDown(KeyName) {
	try {
		return GetKeyState(KeyName, "P") ? 1 : 0
	} catch {
		return 0
	}
}

; Returns 1 when the key is not physically held down, 0 otherwise.
; Equivalent to !KS_IsDown(KeyName) — exists so call sites read naturally.
; @param KeyName {String} Platform key identifier (e.g. "SC038", "LShift").
; @return {Integer} 1 if the key is currently up, 0 if it is down.
KS_IsUp(KeyName) {
	try {
		return GetKeyState(KeyName, "P") ? 0 : 1
	} catch {
		return 1
	}
}

; Returns the wrap-safe tick epoch of the most recent physical keyboard or
; mouse input. A_TimeIdlePhysical ignores AutoHotkey-generated input while the
; hooks are installed, so a deferred output can distinguish the physical event
; which authorized it from any later user action without observing SendInput.
; This is Windows-local state, not part of the cross-platform KeyState port.
; @return {Integer} Unsigned 32-bit A_TickCount epoch.
KS_GetPhysicalInputEpoch() {
	return (A_TickCount - A_TimeIdlePhysical) & 0xFFFFFFFF
}

; Monotonic user-intent generation advanced by HookDispatcher before it fans out
; a physical key-down, mouse-down or wheel action. Unlike A_TimeIdlePhysical it
; deliberately ignores the matching key/button release: a deferred action
; authorized by Tab must not cancel itself merely because Tab comes back up.
; SendInput is invisible to the dispatcher's InputHook, so the generation also
; stays stable across the atomic output which consumes an admission ticket.
global _KS_PhysicalInputGeneration := 0
global _KS_LastPhysicalKeyVk := -1
global _KS_LastPhysicalKeySc := -1
global _KS_LastPhysicalKeyEpoch := -1
global _KS_LastPhysicalKeySources := Map()

; Record one key-down seen by either of the driver's two InputHooks. The prefix
; watcher is started after HookDispatcher and therefore normally receives the
; same physical event first. The physical idle epoch identifies that key-down;
; a source-set then collapses its two callbacks into one generation. A later
; same-key event has a new epoch even if one hook missed the preceding event, so
; stale peer state cannot consume it. This remains correct if hook order flips.
KS_RecordPhysicalKeyDown(VK, SC, Source, EventEpoch := unset) {
	global _KS_PhysicalInputGeneration
	global _KS_LastPhysicalKeyVk, _KS_LastPhysicalKeySc
	global _KS_LastPhysicalKeyEpoch, _KS_LastPhysicalKeySources
	if !(VK is Integer) or !(SC is Integer)
		throw TypeError("Physical key identity must be integer VK/SC values.")
	if !(Source is String) or (Source != "prefix" and Source != "dispatcher")
		throw ValueError("Physical key source must be 'prefix' or 'dispatcher'.")
	if !IsSet(EventEpoch)
		EventEpoch := KS_GetPhysicalInputEpoch()
	if !(EventEpoch is Integer)
		throw TypeError("Physical key event epoch must be an integer.")
	PreviousCritical := Critical("On")
	try {
		IsPeerCallback := (_KS_LastPhysicalKeyVk == VK
			and _KS_LastPhysicalKeySc == SC
			and _KS_LastPhysicalKeyEpoch == EventEpoch
			and !_KS_LastPhysicalKeySources.Has(Source))
		if IsPeerCallback {
			_KS_LastPhysicalKeySources[Source] := true
			return _KS_PhysicalInputGeneration
		}
		_KS_PhysicalInputGeneration += 1
		_KS_LastPhysicalKeyVk := VK
		_KS_LastPhysicalKeySc := SC
		_KS_LastPhysicalKeyEpoch := EventEpoch
		_KS_LastPhysicalKeySources := Map(Source, true)
		return _KS_PhysicalInputGeneration
	} finally {
		Critical(PreviousCritical)
	}
}

; Pointer intent has only the dispatcher owner, so every call is a distinct
; action. Clear the pending key pair as well: if a yielded key callback really
; lets pointer input land before its peer hook, the peer must not reuse the old
; admission ticket after that intervening action.
KS_RecordPhysicalInput() {
	global _KS_PhysicalInputGeneration
	global _KS_LastPhysicalKeyVk, _KS_LastPhysicalKeySc
	global _KS_LastPhysicalKeyEpoch, _KS_LastPhysicalKeySources
	PreviousCritical := Critical("On")
	try {
		_KS_PhysicalInputGeneration += 1
		_KS_LastPhysicalKeyVk := -1
		_KS_LastPhysicalKeySc := -1
		_KS_LastPhysicalKeyEpoch := -1
		_KS_LastPhysicalKeySources := Map()
		return _KS_PhysicalInputGeneration
	} finally {
		Critical(PreviousCritical)
	}
}

KS_GetPhysicalInputGeneration() {
	global _KS_PhysicalInputGeneration
	return _KS_PhysicalInputGeneration
}





; =========================================
; =========================================
; ======= 2/ Keyboard Layout Probes =======
; =========================================
; =========================================

; Win32 keyboard-layout probes used at boot to detect the active layout and the
; physical scancodes behind logical keys. These wrap MapVirtualKeyExW / ToUnicodeEx
; / SystemParametersInfo so every layout-detection DllCall lives in this adapter
; instead of being inlined in the boot sequence. They are Windows-specific and so
; are NOT part of the cross-platform KeyState port contract (isDown/isUp).

; Resolves the active HKL via a 3-step cascade: the foreground window's layout,
; then the AHK thread's own layout, then the system default input language. At
; tray-only startup there may be no foreground window, hence the fallbacks.
; @return {Integer} The resolved HKL, or 0 when none could be obtained.
KS_ResolveKeyboardLayout() {
	; Same fail-safe contract as KS_IsDown/KS_IsUp above: an unguarded DllCall
	; failure at boot must degrade to the documented "could not resolve" return
	; (0), not propagate uncaught and abort the boot sequence.
	try {
		local hkl := GetForegroundKeyboardLayout()
		if hkl = 0
			hkl := DllCall("GetKeyboardLayout", "UInt", DllCall("GetCurrentThreadId", "UInt"), "Ptr")
		if hkl = 0 {
			; SPI_GETDEFAULTINPUTLANG = 0x0059; pvParam receives an HKL.
			local buf := Buffer(A_PtrSize, 0)
			DllCall("SystemParametersInfo", "UInt", 0x0059, "UInt", 0, "Ptr", buf, "UInt", 0)
			hkl := NumGet(buf, 0, "Ptr")
		}
		return hkl
	} catch as e {
		try LoggerError("KeyState", "KS_ResolveKeyboardLayout failed: {1}.", e.Message)
		return 0
	}
}

; Reverse-probes VK_RMENU (0xA5) into a scancode under the given layout
; (MAPVK_VK_TO_VSC_EX = 4). SC = 0 means VK_RMENU is not mapped on this layout
; (a Kana-like AltGr remap); a non-zero SC means a standard RAlt/AltGr exists.
; @param Hkl {Integer} The keyboard layout handle to probe.
; @return {Integer} The scancode for VK_RMENU, or 0 when it is unmapped.
KS_ProbeRightAltScancode(Hkl) {
	try {
		return DllCall("MapVirtualKeyExW", "UInt", 0xA5, "UInt", 4, "Ptr", Hkl, "UInt")
	} catch as e {
		try LoggerError("KeyState", "KS_ProbeRightAltScancode failed: {1}.", e.Message)
		return 0
	}
}

; Enumerates base scancodes 0x01-0x7F under Hkl and returns the first whose
; no-modifier output equals TargetChar. ToUnicodeEx is called with wFlags=0x4
; (UNICODE_NOCHAR) so the probe never corrupts pending Win32 dead-key state.
; @param Hkl {Integer} The keyboard layout handle to probe.
; @param TargetChar {String} The character to locate (e.g. the magic-key source).
; @return {Map} Map("scan", SC, "vk", VK); scan = 0 when no scancode matches.
KS_ScanScancodeForChar(Hkl, TargetChar) {
	local keyState := Buffer(256, 0)  ; all modifier keys unpressed
	local foundScan := 0, foundVK := 0
	try {
		; Probe every base scancode. 0x01-0x58 covers all standard keys;
		; extend to 0x7F as a safety margin for exotic layouts.
		Loop 127 {
			local sc := A_Index
			; MAPVK_VSC_TO_VK_EX = 3: extended-key-aware SC -> VK.
			local vk := DllCall("MapVirtualKeyExW", "UInt", sc, "UInt", 3, "Ptr", Hkl, "UInt")
			if vk = 0
				continue
			; Reset buffer before each call - dead-key state can persist across calls.
			local charBuf := Buffer(10, 0)
			local len := DllCall("ToUnicodeEx",
				"UInt", vk, "UInt", sc, "Ptr", keyState,
				"Ptr", charBuf, "Int", 4, "UInt", 0x4, "Ptr", Hkl, "Int")
			if len <= 0
				continue
			local ch := StrGet(charBuf, len, "UTF-16")
			if ch = TargetChar {
				foundScan := sc
				foundVK := vk
				break
			}
		}
	} catch as e {
		try LoggerError("KeyState", "KS_ScanScancodeForChar failed: {1}.", e.Message)
	}
	return Map("scan", foundScan, "vk", foundVK)
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_KEY_STATE := Map(
    "isDown", KS_IsDown,
    "isUp",   KS_IsUp,
)
