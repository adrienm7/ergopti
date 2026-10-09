; tests/meta/test_capslock_led_single_owner.ahk

; ==============================================================================
; MODULE: CapsLock LED Single-Owner Meta Test
; DESCRIPTION:
; Static source guard for the capslock-led-multiple-owners finding.
;
; CapsWord and genuine hardware CapsLock own character case and its LED.
; Navigation owns a separate tray indicator so an unbound key keeps its native
; case. ToggleCapsLock delegates to the same CapsLock writer, preserving the
; single-owner and non-latching guarantees when these modes are interleaved.
;
; The native child probe executes the real writer extracted from the driver,
; checks all eight mode combinations, and restores the original machine toggle.
; Extraction avoids loading this module's unrelated top-level hotkeys.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_CLSO_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ===================================================
; ===================================================
; ======= 2/ Single-owner contract assertions =======
; ===================================================
; ===================================================

; Genuine CapsLock intent must survive both navigation and CapsWord transitions.
_CLSO_LedConsultsHardwareToggle() {
	Src := _CLSO_ReadSource("modules/shortcuts/capsword.ahk")
	Seg := _DriverFuncBody("UpdateCapsLockLED")
	Assert(Seg != "", "UpdateCapsLockLED() declaration must exist in capsword.ahk")
	Assert(InStr(Seg, "CapsWordEnabled") > 0,
		"UpdateCapsLockLED must still consider CapsWordEnabled")
	Assert(InStr(Seg, "NavigationLayerUpdateIndicator") > 0,
		"navigation must retain an indicator outside the physical CapsLock toggle")
	AssertTrue(RegExMatch(Seg, "m)^\s*LedOn := CapsWordEnabled or _HardwareCapsLockOn\s*$") > 0,
		"only genuine CapsLock and CapsWord may change native character case")
	; The GUARANTEE is that a genuine hardware CapsLock is part of the OR, so a
	; real toggle is not overridden by CapsWord/layer state. This assertion used
	; to pin the MECHANISM — GetKeyState("CapsLock", "T") — and that mechanism
	; was the bug: it reads back the very bit SetCapsLockState writes two lines
	; below, so once CapsWord lit the LED the next evaluation saw its own output,
	; concluded the user wanted CapsLock, and re-asserted it. CapsLock then
	; survived CapsWord and everything kept typing uppercase (reproduced live).
	; The hardware intent now lives in its own variable, which satisfies the same
	; guarantee without the feedback loop.
	Assert(InStr(Seg, "_HardwareCapsLockOn") > 0,
		"UpdateCapsLockLED must OR the recorded hardware CapsLock intent into its condition, "
		. "otherwise navigation or CapsWord can overwrite genuine CapsLock intent")
	HardwareTerm := "GetKeyState(" . Chr(34) . "CapsLock" . Chr(34) . ", " . Chr(34) . "T" . Chr(34) . ")"
	Assert(InStr(Seg, HardwareTerm) = 0,
		"UpdateCapsLockLED must NOT read back GetKeyState(CapsLock, T) — that is the bit it "
		. "writes, so ORing it makes the function self-latching and CapsLock outlives CapsWord")
}
Test("capsword: UpdateCapsLockLED ORs the hardware CapsLock toggle (capslock-led-multiple-owners)", _CLSO_LedConsultsHardwareToggle)

; ToggleCapsLock must delegate the LED to the single owner instead of driving it
; directly, so it can never leave the LED disagreeing with CapsWord/layer state.
_CLSO_ToggleRoutesThroughLed() {
	Src := _CLSO_ReadSource("platform/remap/one_shot_shift.ahk")
	Seg := _DriverFuncBody("ToggleCapsLock")
	Assert(Seg != "", "ToggleCapsLock() declaration must exist in one_shot_shift.ahk")
	Assert(InStr(Seg, "UpdateCapsLockLED()") > 0,
		"ToggleCapsLock must route the LED through UpdateCapsLockLED() (the single LED owner) instead of independently overwriting the CapsWord or hardware toggle")
}
Test("one_shot_shift: ToggleCapsLock delegates LED to UpdateCapsLockLED (capslock-led-multiple-owners)", _CLSO_ToggleRoutesThroughLed)

; Execute the actual owner, rather than a copy of its boolean expression. Every
; native transition is inspected before restoring the original CapsLock bit.
_CLSO_NativeCaseMatrix() {
	Writer := _DriverFuncBody("UpdateCapsLockLED")
	AssertTrue(Writer != "", "the native probe must execute the real CapsLock owner")
	Root := A_Temp . "\ergopti-nav-case-" . A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Root)
	Script := Root . "\case_matrix.ahk"
	Probe := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n"
		. 'global CapsWordEnabled := false, LayerEnabled := false, _HardwareCapsLockOn := false' . "`n"
		. 'LoggerIsDebugEnabled() => false' . "`n"
		. 'LoggerDebug(*) => 0' . "`n"
		. 'global IndicatorRequests := []' . "`n"
		. 'NavigationLayerUpdateIndicator(IsActive) {' . "`n"
		. '`tIndicatorRequests.Push(IsActive)' . "`n"
		. '`treturn false' . "`n}" . "`n"
		. 'global NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL := ' . NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL . "`n"
		. _DriverFuncBody("DisableLayer") . "`n"
		. Writer . "`n"
		. 'Original := GetKeyState("CapsLock", "T")' . "`n"
		. 'Code := 0' . "`n"
		. 'Checks := 0' . "`n"
		. 'try {' . "`n"
		. '`tfor Nav in [false, true] {' . "`n"
		. '`t`tfor Word in [false, true] {' . "`n"
		. '`t`t`tfor Hardware in [false, true] {' . "`n"
		. '`t`t`t`tLayerEnabled := Nav' . "`n"
		. '`t`t`t`tCapsWordEnabled := Word' . "`n"
		. '`t`t`t`t_HardwareCapsLockOn := Hardware' . "`n"
		. '`t`t`t`tUpdateCapsLockLED()' . "`n"
		. '`t`t`t`tif GetKeyState("CapsLock", "T") != (Word or Hardware)' . "`n"
		. '`t`t`t`t`tthrow Error("Navigation changed native CapsLock case: nav=" . Nav . ", word=" . Word . ", hardware=" . Hardware)' . "`n"
		. '`t`t`t`tChecks += 1' . "`n"
		. '`t`t`t}' . "`n`t`t}`n`t}`n"
		. '`tLayerEnabled := true' . "`n"
		. '`tCapsWordEnabled := false' . "`n"
		. '`t_HardwareCapsLockOn := false' . "`n"
		. '`tSuspend(true)' . "`n"
		. '`tUpdateCapsLockLED()' . "`n"
		. '`tif IndicatorRequests[IndicatorRequests.Length]' . "`n"
		. '`t`tthrow Error("A paused driver retained the navigation indicator")' . "`n"
		. '`tSuspend(false)' . "`n"
		. '`tDisableLayer()' . "`n"
		. '`tif LayerEnabled or GetKeyState("CapsLock", "T")' . "`n"
		. '`t`tthrow Error("A refused indicator prevented native layer cleanup")' . "`n"
		. '} catch as Err {' . "`n"
		. '`tFileAppend(Err.Message, "*", "UTF-8-RAW")' . "`n"
		. '`tCode := 1' . "`n"
		. '} finally {' . "`n"
		. '`tSetCapsLockState(Original ? "On" : "Off")' . "`n"
		. '}' . "`n"
		. 'FileAppend("checks=" . Checks, "*", "UTF-8-RAW")' . "`n"
		. 'ExitApp(Code)' . "`n"
	Receipts := []
	Observe(Code, Out, Err) {
		Receipts.Push({Code: Code, Out: Out, Err: Err})
	}
	Handle := 0
	OriginalCapsLockOn := GetKeyState("CapsLock", "T")
	try {
		FileAppend(Probe, Script, "UTF-8")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Script], Observe)
		AssertTrue(Handle.start(), "the actual native CapsLock probe must start")
		Started := A_TickCount
		while Receipts.Length == 0 && TickElapsed(Started) < 5000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Receipts.Length, "the native probe must finish within its bounded wait")
		AssertEqual(0, Receipts[1].Code, Receipts[1].Out . Receipts[1].Err)
		AssertEqual("checks=8", Receipts[1].Out, "all mode combinations must inspect the real native toggle")
	} finally {
		try {
			if IsObject(Handle)
				AssertTrue(Handle.terminate(), "the probe must release its native process tree")
		} finally {
			; The parent also restores the bit if the bounded child was killed before
			; it could reach its own finally (load error, native failure or timeout).
			SetCapsLockState(OriginalCapsLockOn ? "On" : "Off")
			DirDelete(Root, true)
		}
	}
}
Test("navigation: native CapsLock case ignores the layer and preserves CapsWord and hardware intent", _CLSO_NativeCaseMatrix)
