; infra/altgr_family.ahk

; ==============================================================================
; MODULE: AltGr family
; DESCRIPTION:
; Owns the AltGr family the whole driver keys on: _ALTGR_KANA_FIXUP and the
; probe record _ALTGR_LAYOUT_PROBE, which KS_AltGrKeyName, KS_AltGrSendKey,
; KS_LayoutHasAltGr, KS_AltGrAddsFakeLCtrl and every #HotIf built on them
; read on each call. The family used to be decided once per process, and a
; layout switch reloaded the driver to decide it again. With Windows' "use a
; different input method for each app window", every window switch may change
; the layout, so the family now follows the foreground window's layout live:
; each layout is probed once and cached by HKL, a foreground change or the
; layout poll re-decides the family, and #HotIf criteria, evaluated on every
; key event, pick the new family's variants at the next press.
;
; A switch waits while an AltGr press or a tap-hold is in flight
; (AltGrFamilyIsBusy): their owners captured the family's key names at the
; press and release them at the end, so the new family applies from the next
; press on.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Constants and state =======
; ======================================
; ======================================

; Wait before trying again a switch an in-flight AltGr press or tap-hold held
; back. Short, so the family is right by the next press; the layout poll tries
; again every second anyway.
global ALTGR_FAMILY_RETRY_MS := 50
; Win32 EVENT_SYSTEM_FOREGROUND and WINEVENT_OUTOFCONTEXT.
global ALTGR_FAMILY_EVENT_SYSTEM_FOREGROUND := 0x0003
global ALTGR_FAMILY_WINEVENT_OUTOFCONTEXT := 0x0000

; HKL -> the raw KS_ProbeAltGrLayout record of that layout. A layout's AltGr key
; does not change while it is loaded, so each one is probed once.
global _AltGrFamilyProbeCache := Map()
; The probe the cache is filled with: KS_ProbeAltGrLayout, or a test seam.
global _AltGrFamilyProbeFn := 0
; The foreground WinEvent hook and its callback, while following.
global _AltGrFamilyWinHook := 0
global _AltGrFamilyWinCallback := 0
global _AltGrFamilyRetryArmed := false





; ==========================================
; ==========================================
; ======= 2/ Deciding and publishing =======
; ==========================================
; ==========================================

; Forgets every cached probe and names the probe that decides from now on.
; The boot decision (HotstringEngineInit) starts here, so a family is never
; decided from a probe of a previous initialization.
; @param ProbeFn {Func} KS_ProbeAltGrLayout by default; a test seam otherwise.
AltGrFamilyResetProbes(ProbeFn := 0) {
	global _AltGrFamilyProbeCache, _AltGrFamilyProbeFn
	_AltGrFamilyProbeCache := Map()
	_AltGrFamilyProbeFn := IsObject(ProbeFn) ? ProbeFn : KS_ProbeAltGrLayout
}

; The record that decides the AltGr family on layout Hkl: the layout's probe,
; cached, with "source" ("probe", "override" when the TOML flag decided,
; "unresolved" when no layout could be read or the layout knows no AltGr key)
; and the manual TOML override applied. HKL 0 is never probed: MapVirtualKeyExW
; reads it as HKL_PREV, another loaded layout. A layout that maps the AltGr key
; neither way is not taken for a Kana one: the family stays the standard one.
; @param Hkl {Integer} Keyboard layout handle, 0 when none could be read.
; @return {Map} A fresh record; the cache keeps its own copy.
AltGrFamilyDecide(Hkl) {
	global _AltGrFamilyProbeCache, _AltGrFamilyProbeFn
	if (Hkl != 0) {
		if !_AltGrFamilyProbeCache.Has(Hkl) {
			if !IsObject(_AltGrFamilyProbeFn)
				_AltGrFamilyProbeFn := KS_ProbeAltGrLayout
			_AltGrFamilyProbeCache[Hkl] := _AltGrFamilyProbeFn.Call(Hkl)
		}
		Probe := _AltGrFamilyProbeCache[Hkl].Clone()
		Probe["source"] := Probe["valid"] ? "probe" : "unresolved"
	} else {
		Probe := Map("hkl", 0, "rmenu_sc", 0, "altgr_vk", 0,
			"valid", false, "kana", false, "altgr_level", false, "source", "unresolved")
	}
	Override := _ReadKanaTomlOverride()
	if (Override != "") {
		Probe["override_against_probe"] := Probe["valid"] and Probe["kana"] != (Override == "true")
		Probe["kana"] := (Override == "true")
		Probe["source"] := "override"
	}
	return Probe
}

; Whether the TOML override decided against what the layout's own probe read:
; a Kana-style layout forced to the standard family, or the reverse. That is
; what the override is for when the probe is wrong, and otherwise a
; configuration that makes every AltGr feature name the wrong key, so the boot
; log names it. A probe that read nothing has no verdict to contradict.
; @param Probe {Map} A record from AltGrFamilyDecide.
; @return {Boolean}
AltGrFamilyOverrideContradictsProbe(Probe) {
	return Probe["source"] == "override" and Probe["override_against_probe"]
}

; Makes Probe the family every reader sees from now on.
; @param Probe {Map} A record from AltGrFamilyDecide.
AltGrFamilyPublish(Probe) {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
	_ALTGR_LAYOUT_PROBE := Probe
	_ALTGR_KANA_FIXUP := Probe["kana"]
}

; The family a record describes, for the log: "kana" (AltGr on SC138 under
; another virtual key), "altgr" (right Alt is AltGr, with the fake LCtrl) or
; "plain" (right Alt is a plain Alt, as on QWERTY).
; @param Probe {Map} A record from AltGrFamilyDecide.
; @return {String}
AltGrFamilyName(Probe) {
	if Probe["kana"]
		return "kana"
	return Probe["altgr_level"] ? "altgr" : "plain"
}





; =======================================
; =======================================
; ======= 3/ Following the layout =======
; =======================================
; =======================================

; Whether switching the family now could strand a key: the AltGr key is
; physically down (under either family's name), a tap-hold owner is resolving
; a press, a synthetic AltGr is held or waiting for its release, or a hotstring
; expansion is sending. Their owners named the AltGr key when they started and
; release it by that name; a switch in between would make every other reader
; name the other key.
; @return {Boolean}
AltGrFamilyIsBusy() {
	global _TH_OwnedPresses, _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	global HSE_Suppressed
	if GetKeyState("SC138", "P") or GetKeyState("RAlt", "P")
		return true
	if (IsSet(_TH_OwnedPresses) and _TH_OwnedPresses.Count > 0)
		return true
	for _, Name in ["SC138", "RAlt"] {
		if (IsSet(_TH_SyntheticHeldKeys) and _TH_SyntheticHeldKeys.Has(Name))
			return true
		if (IsSet(_TH_SyntheticReleasePendingKeys) and _TH_SyntheticReleasePendingKeys.Has(Name))
			return true
	}
	return IsSet(HSE_Suppressed) and HSE_Suppressed > 0
}

; Switches the AltGr family to the one of layout Hkl, without a reload. Nothing
; changes for HKL 0 (no foreground window: the desktop, a lock screen) or for
; the layout already decided. While AltGrFamilyIsBusy, the switch is held back
; and tried again shortly (the layout poll also tries every second).
; @param Hkl {Integer} The foreground window's keyboard layout.
; @param BusyFn {Func} Test seam, AltGrFamilyIsBusy by default.
; @return {Boolean} True when the published record changed.
AltGrFamilyFollow(Hkl, BusyFn := 0) {
	global _ALTGR_LAYOUT_PROBE
	if (Hkl == 0 or Hkl == _ALTGR_LAYOUT_PROBE["hkl"])
		return false
	if !IsObject(BusyFn)
		BusyFn := AltGrFamilyIsBusy
	; A hotkey thread must not start between the busy check and the publication:
	; it would begin a press on the old family and end it on the new one.
	PreviousCritical := Critical("On")
	try {
		if BusyFn.Call() {
			_AltGrFamilyArmRetry()
			return false
		}
		Previous := _ALTGR_LAYOUT_PROBE
		Probe := AltGrFamilyDecide(Hkl)
		AltGrFamilyPublish(Probe)
	} finally {
		Critical(PreviousCritical)
	}
	_AltGrFamilyLogSwitch(Previous, Probe)
	return true
}

_AltGrFamilyLogSwitch(Previous, Probe) {
	Family := AltGrFamilyName(Probe)
	WasFamily := AltGrFamilyName(Previous)
	if (Probe["kana"] and !Probe["altgr_vk"]) {
		try LoggerError("AltGrDetect",
			"HKL=0x{1:X}: a Kana-style AltGr is set (source={2}) but the layout gives the AltGr key no virtual key; every press or release of it the driver sends is refused.",
			Probe["hkl"], Probe["source"])
		return
	}
	if (Family == WasFamily) {
		try LoggerDebug("AltGrDetect", "Foreground layout HKL=0x{1:X}: AltGr family {2} unchanged (source={3}).",
			Probe["hkl"], Family, Probe["source"])
		return
	}
	try LoggerInfo("AltGrDetect",
		"Foreground layout HKL=0x{1:X}: AltGr family {2} (was {3} on HKL=0x{4:X}), VK_RMENU→SC=0x{5:X}, AltGr VK=0x{6:X}, source={7}; no reload.",
		Probe["hkl"], Family, WasFamily, Previous["hkl"], Probe["rmenu_sc"], Probe["altgr_vk"], Probe["source"])
}

; Tries a held-back switch again once, shortly. One pending retry at a time: a
; busy retry arms the next one itself.
_AltGrFamilyArmRetry() {
	global _AltGrFamilyRetryArmed, ALTGR_FAMILY_RETRY_MS
	if _AltGrFamilyRetryArmed
		return
	_AltGrFamilyRetryArmed := true
	SetTimer(_AltGrFamilyRetryTick, -ALTGR_FAMILY_RETRY_MS)
}

_AltGrFamilyRetryTick() {
	global _AltGrFamilyRetryArmed
	_AltGrFamilyRetryArmed := false
	AltGrFamilyFollow(GetForegroundKeyboardLayout())
}

; Starts following the foreground window: every foreground change re-decides
; the family at once, so the first AltGr press in the new window already
; reaches that layout's variants. A layout switched inside the same window
; (Win+Space) raises no foreground event; the layout poll catches it within a
; second (CheckKeyboardLayoutChange). The callback runs as its own thread
; (no "F"): the event arrives through whichever thread pumps messages.
; @return {Boolean} True when the hook is installed; false when Windows refused
;         it, and the layout poll alone follows the layout.
AltGrFamilyStartFollowing() {
	global _AltGrFamilyWinHook, _AltGrFamilyWinCallback
	global ALTGR_FAMILY_EVENT_SYSTEM_FOREGROUND, ALTGR_FAMILY_WINEVENT_OUTOFCONTEXT
	if (_AltGrFamilyWinHook or _AltGrFamilyWinCallback)
		throw Error("The AltGr family already follows the foreground window.", -1)
	try LoggerStart("AltGrDetect", "Following the foreground window's keyboard layout…")
	_AltGrFamilyWinCallback := CallbackCreate(_AltGrFamilyOnForeground, , 7)
	_AltGrFamilyWinHook := DllCall("SetWinEventHook",
		"UInt", ALTGR_FAMILY_EVENT_SYSTEM_FOREGROUND,
		"UInt", ALTGR_FAMILY_EVENT_SYSTEM_FOREGROUND,
		"Ptr", 0,
		"Ptr", _AltGrFamilyWinCallback,
		"UInt", 0,
		"UInt", 0,
		"UInt", ALTGR_FAMILY_WINEVENT_OUTOFCONTEXT,
		"Ptr")
	if !_AltGrFamilyWinHook {
		CallbackFree(_AltGrFamilyWinCallback)
		_AltGrFamilyWinCallback := 0
		try LoggerError("AltGrDetect", "SetWinEventHook failed: the AltGr family follows the foreground layout through the one-second layout poll only.")
		return false
	}
	try LoggerSuccess("AltGrDetect", "The AltGr family follows the foreground window's keyboard layout.")
	return true
}

_AltGrFamilyOnForeground(HWinEventHook, Event, Hwnd, IdObject, IdChild, IdEventThread, EventTime) {
	AltGrFamilyFollow(GetForegroundKeyboardLayout())
}

; Stops following the foreground window at shutdown: unhooks the WinEvent hook
; and frees its callback. Nothing to do when following never started.
; @return {Boolean} False when Windows refused to unhook; the callback is then
;         kept, since the hook may still call it.
AltGrFamilyStopFollowing() {
	global _AltGrFamilyWinHook, _AltGrFamilyWinCallback
	if _AltGrFamilyWinHook {
		if !DllCall("UnhookWinEvent", "Ptr", _AltGrFamilyWinHook)
			return false
		_AltGrFamilyWinHook := 0
	}
	if _AltGrFamilyWinCallback {
		CallbackFree(_AltGrFamilyWinCallback)
		_AltGrFamilyWinCallback := 0
	}
	return true
}
