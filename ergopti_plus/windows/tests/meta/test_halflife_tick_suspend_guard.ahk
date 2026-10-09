; tests/meta/test_halflife_tick_suspend_guard.ahk

; ==============================================================================
; MODULE: Half-Life Tick Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the "halflife-tick-no-suspend-guard" finding.
;
; KL_Roi_HalflifeTick() is a recurring SetTimer callback (HALFLIFE_CHECK_MS
; interval) that iterates over in-memory trigger usage and appends
; "trigger_halflife" entries via KL_AppendLog. SetTimer callbacks bypass
; native AHK Suspend, so the tick was running its full iteration loop while
; the driver was paused. Although KL_AppendLog already has its own pause
; chokepoint guard, the outer loop itself was still executing unnecessarily.
;
; The fix adds `if A_IsSuspended return` at the top of KL_Roi_HalflifeTick,
; immediately after the module init guard, so the entire body is skipped.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helper =====================
; ===================================================
; ===================================================

_HLTSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Guard assertion ========================
; ===================================================
; ===================================================

_HLTSG_HalflifeTickHasSuspendGuard() {
	Src := _HLTSG_ReadSource("modules/keylogger/keylogger_trigger_roi.ahk")
	Seg := _DriverFuncBody("KL_Roi_HalflifeTick")
	Assert(Seg != "", "KL_Roi_HalflifeTick must exist in keylogger_trigger_roi.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"KL_Roi_HalflifeTick must check A_IsSuspended — SetTimer bypasses Suspend; without this the iteration runs while paused")
}
Test("keylogger_trigger_roi: KL_Roi_HalflifeTick has A_IsSuspended suspend guard", _HLTSG_HalflifeTickHasSuspendGuard)
