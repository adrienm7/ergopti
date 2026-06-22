; tests/meta/test_suspend_watchdog_no_prefix_keywait.ahk

; ==============================================================================
; MODULE: Suspend Prefix-Drain Invariant Meta Test
; DESCRIPTION:
; Static source guard for the "suspend-watchdog-no-prefix-keywait" finding.
;
; The SC138 (AltGr/Kana) custom-combination prefix flag latches across Suspend and
; cannot be cleared by synthetic events — it must be drained (by waiting for the
; physical key to lift) BEFORE Suspend() flips. _SuspendStateWatchdog is only a
; state-change DETECTOR; it reacts AFTER the flip, too late to drain. So the
; invariant is: every code path that triggers a suspend must drain the prefix
; first, which today means the single Suspend(-1) call lives inside ToggleSuspend,
; and ToggleSuspend drains the prefix via _SuspendDrainPrefix() before flipping.
;
; This test encodes that invariant as source text:
;   1. The ONLY Suspend(...) call in the driver is the Suspend(-1) inside
;      ToggleSuspend (no future path may bypass the drain).
;   2. ToggleSuspend calls _SuspendDrainPrefix() BEFORE Suspend(-1).
;   3. _SuspendDrainPrefix performs the KeyWait("SC138"...) drain.
; A future native/external suspend hotkey that calls Suspend() directly, or a
; refactor that drops the drain, fails CI. Meta-static because ErgoptiPlus.ahk
; registers every hotkey at load and cannot be #Included by the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_SWNPK_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Counts non-overlapping occurrences of Needle in Hay.
_SWNPK_CountOccurrences(Hay, Needle) {
	Count := 0
	Pos := 1
	while (Pos := InStr(Hay, Needle, , Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}




; ==================================================
; ==================================================
; ======= 2/ Invariant assertions ==================
; ==================================================
; ==================================================

; Invariant 1: the only Suspend(...) call site is ToggleSuspend's Suspend(-1).
; The token "Suspend(" appears in source only as the ToggleSuspend( declaration
; and as the Suspend(-1) call; any other occurrence is a path that bypasses the
; prefix drain.
_SWNPK_OnlyCallSiteIsToggleSuspend() {
	Src := _DriverSourceConcat()
	TotalSuspendParen := _SWNPK_CountOccurrences(Src, "Suspend(")
	ToggleDecls       := _SWNPK_CountOccurrences(Src, "ToggleSuspend(")
	RealCalls         := _SWNPK_CountOccurrences(Src, "Suspend(-1)")
	; Every "Suspend(" must be accounted for as either the ToggleSuspend(
	; declaration/reference or the single Suspend(-1) toggle call.
	Assert(RealCalls = 1,
		"There must be exactly ONE Suspend(-1) call (inside ToggleSuspend) — found " . RealCalls)
	Assert(TotalSuspendParen = ToggleDecls + RealCalls,
		"Every 'Suspend(' must be a ToggleSuspend( reference or the Suspend(-1) call — any other Suspend() call bypasses the SC138 prefix drain and can reintroduce the 'AltGr latched' bug")
}
Test("ErgoptiPlus: Suspend(-1) is the only suspend call site (suspend-watchdog-no-prefix-keywait)", _SWNPK_OnlyCallSiteIsToggleSuspend)

; Invariant 2: ToggleSuspend drains the prefix before flipping Suspend.
_SWNPK_ToggleDrainsBeforeSuspend() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("ToggleSuspend")
	Assert(Seg != "", "ToggleSuspend(*) must exist in ErgoptiPlus.ahk")
	DrainPos   := InStr(Seg, "_SuspendDrainPrefix()")
	SuspendPos := InStr(Seg, "Suspend(-1)")
	Assert(DrainPos > 0,
		"ToggleSuspend must drain the SC138 prefix via _SuspendDrainPrefix() before suspending")
	Assert(SuspendPos > 0, "ToggleSuspend must contain the Suspend(-1) call")
	Assert(DrainPos < SuspendPos,
		"_SuspendDrainPrefix() must run BEFORE Suspend(-1) — the drain must complete before the flip latches the prefix flag")
}
Test("ErgoptiPlus: ToggleSuspend drains prefix before Suspend (suspend-watchdog-no-prefix-keywait)", _SWNPK_ToggleDrainsBeforeSuspend)

; Invariant 3: the drain helper performs the KeyWait("SC138"...) wait.
_SWNPK_DrainHelperWaitsSc138() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("_SuspendDrainPrefix")
	Assert(Seg != "", "_SuspendDrainPrefix() must exist in ErgoptiPlus.ahk")
	; Q is the ASCII double-quote (the linter bans the backtick-quote escape).
	Q := Chr(34)
	Assert(InStr(Seg, "KeyWait(" . Q . "SC138" . Q) > 0,
		"_SuspendDrainPrefix must KeyWait on SC138 to let the physical AltGr/Kana key lift before suspending — synthetic events cannot clear the latched prefix flag")
}
Test("ErgoptiPlus: _SuspendDrainPrefix waits on SC138 (suspend-watchdog-no-prefix-keywait)", _SWNPK_DrainHelperWaitsSc138)



; ==================================================
; ==================================================
; ======= 3/ Boot phantom-modifier release =========
; ==================================================
; ==================================================

; Invariant 4: the boot phantom-modifier release exists and clears the AltGr keys.
; A Reload can land while AltGr is physically held, leaving the OS modifier
; latched down for the fresh process — stuck on the AltGr layer (transient
; « AltGr bloqué »). _ReleasePhantomModifiers clears it at boot.
_SWNPK_BootReleasesPhantomModifiers() {
	Seg := _DriverFuncBody("_ReleasePhantomModifiers")
	Assert(Seg != "", "_ReleasePhantomModifiers() must exist in lib/lifecycle.ahk")
	Assert(InStr(Seg, "{SC138 up}") > 0,
		"_ReleasePhantomModifiers must release SC138 (the AltGr/Kana prefix key) to clear an OS phantom carried across a Reload")
	Assert(InStr(Seg, "{RAlt up}") > 0,
		"_ReleasePhantomModifiers must release RAlt (vanilla AltGr)")
	Assert(InStr(Seg, "{Blind}") > 0,
		"_ReleasePhantomModifiers must send with {Blind} so AHK does not inject its own modifier state")
}
Test("lifecycle: _ReleasePhantomModifiers releases AltGr/SC138 at boot (suspend-watchdog-no-prefix-keywait)", _SWNPK_BootReleasesPhantomModifiers)

; Invariant 5: the release helper is actually CALLED at boot (not only defined),
; so a Reload-borne phantom modifier is cleared before the first keystrokes.
_SWNPK_BootCallsRelease() {
	Src := _DriverSourceConcat()
	Calls := _SWNPK_CountOccurrences(Src, "_ReleasePhantomModifiers()")
	Assert(Calls >= 2,
		"_ReleasePhantomModifiers() must be CALLED at boot, not only defined — found " . Calls . " occurrence(s) of the bare call token in the driver tree")
}
Test("ErgoptiPlus: boot calls _ReleasePhantomModifiers (suspend-watchdog-no-prefix-keywait)", _SWNPK_BootCallsRelease)
