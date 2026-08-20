; tests/meta/test_tap_hold_suspend_boundary.ahk

; ==============================================================================
; MODULE: Tap-Hold Suspend Boundary Meta Tests
; DESCRIPTION:
; Prevents an in-flight KeyWait from activating a synthetic modifier or the
; navigation layer after native Suspend. Suspend unregisters future hotkeys but
; does not cancel the pseudo-thread already waiting on a physical key.
; ==============================================================================

#Requires AutoHotkey v2.0

_THSB_HoldModifierGateChecksSuspendBeforeInjection() {
	Body := _DriverFuncBody("TapHoldShouldSuppressHold")
	Assert(Body != "", "TapHoldShouldSuppressHold must remain the common hold-modifier gate")
	SuspendPos := InStr(Body, "if A_IsSuspended")
	SuccessPos := InStr(Body, "if (CancelReason != " . Chr(34) . Chr(34) . ")")
	Assert(SuspendPos > 0,
		"TapHoldShouldSuppressHold must reject candidates when Suspend occurs during KeyWait")
	Assert(SuccessPos > SuspendPos,
		"the suspend veto must run before the normal hold activation path can report success")
}
Test("tap-holds: in-flight hold-modifier candidates are cancelled by Suspend (tap-hold-suspend-boundary)",
	_THSB_HoldModifierGateChecksSuspendBeforeInjection)

_THSB_HoldLayerGateChecksSuspendBeforeMutation() {
	Body := _DriverFuncBody("ActivateLayer")
	Assert(Body != "", "ActivateLayer must remain the common hold-layer activation boundary")
	SuspendPos := InStr(Body, "if A_IsSuspended")
	WritePos := InStr(Body, "global LayerEnabled := True")
	Assert(SuspendPos > 0,
		"ActivateLayer must reject stale hold candidates after Suspend")
	Assert(WritePos > SuspendPos,
		"ActivateLayer must check A_IsSuspended before setting LayerEnabled true")
	Assert(InStr(Body, "return false") > SuspendPos,
		"ActivateLayer must return without mutating state when the driver is suspended")
}
Test("tap-holds: in-flight hold-layer candidates cannot activate after Suspend (tap-hold-suspend-boundary)",
	_THSB_HoldLayerGateChecksSuspendBeforeMutation)

_THSB_PreArmedSyntheticKeysAreSuspendOwned() {
	Src := _DriverDirConcat("platform/remap")
	Whole := _DriverSourceNoComments()
	Lifecycle := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(InStr(Lifecycle, "TapHoldReleaseSyntheticKeys()") > 0,
		"Ergopti_OnSuspendEnter must immediately release synthetic tap-hold keys that were armed before an in-flight KeyWait")

	; A direct sustained TextPressKey in a tap-hold module cannot retain a failed
	; Down or Up. The ownership helper is deliberately the sole producer of that
	; raw output; its implementation lives in constants.ahk and is excluded from
	; this sibling scan.
	SplitPath(A_ScriptDir, , &Root)
	Q := Chr(34)
	; Floored, because it was not. This loop scanned the directory by a hardcoded
	; path and asserted per file; when platform/remap was extracted the pattern
	; matched nothing, the body never ran, and every per-file assertion below
	; disappeared without a single failure. A scan that finds no file is a broken
	; scan, never a clean one — the sibling _DriverDirConcat throws for exactly
	; this reason, and this loop predated it.
	Scanned := 0
	Loop Files, Root . "\platform\remap\*.ahk", "FR" {
		if (A_LoopFileName = "constants.ahk")
			continue
		Scanned++
		FileSrc := FileRead(A_LoopFileFullPath)
		Assert(!RegExMatch(FileSrc, "TextPressKey\([^`r`n]+,\s*" . Q . "(?:Down|Up)" . Q . "\)"),
			A_LoopFileName . " must route every sustained key transition through the synthetic owner so failed sends remain retryable")
	}
	Assert(Scanned >= 15,
		"expected the tap-hold key modules to be scanned (got " . Scanned . ") — a moved or renamed "
			. "directory must fail here, not quietly assert nothing")
	; Guard the lifetime class across the entire production driver as well. A
	; future sustained transition may move out of platform/remap; only the two
	; owner-internal sends and the separately modelled pass-through physical Up
	; are allowed to bypass the public ownership pair.
	RawTransitionCount := 0
	Pos := 1
	while Found := RegExMatch(Whole,
		'TextPressKey\([^`r`n]+,\s*"(?:Down|Up)"', &Match, Pos) {
		RawTransitionCount++
		Pos := Found + Match.Len
	}
	AssertEqual(3, RawTransitionCount,
		"the complete driver may contain only the owner-internal transactional Down/retrying Up and the pass-through physical Up; every other sustained transition must route through an explicit owner")
	PhysicalRelease := _DriverFuncBody("TapHoldReleasePhysicalKey")
	Assert(InStr(PhysicalRelease, 'Ok := TextPressKey(Key, "Up", false)') > 0,
		"the sole untracked sustained transition must remain the status-bearing physical-key release helper")
	Assert(InStr(Src, "TapHoldSyntheticKeyDown") > 0 and InStr(Src, "TapHoldSyntheticKeyUp") > 0,
		"tap-hold modules must use the synthetic-key ownership pair around every cross-KeyWait modifier")
}
Test("tap-holds AHK-03: every pre-armed synthetic key is released by the suspend owner (tap-hold-suspend-boundary)",
	_THSB_PreArmedSyntheticKeysAreSuspendOwned)

; AHK-03: every process-lifecycle boundary must drain the same synthetic-key
; owner before slower teardown can delay it. Suspend had this cleanup; OnExit
; did not, so quitting during KeyWait left the OS modifier down permanently.
_THSB_SuspendAndShutdownShareEarlySyntheticCleanup() {
	for Fn in ["Ergopti_OnSuspendEnter", "Ergopti_OnShutdown"] {
		Body := _StripFullLineComments(_DriverFuncBody(Fn))
		Assert(Body != "", Fn . " must exist for synthetic-key lifecycle parity")
		ReleasePos := Fn == "Ergopti_OnShutdown"
			? InStr(Body, "try SyntheticReleased := TapHoldShutdownReleaseGate()")
			: InStr(Body, "try TapHoldReleaseSyntheticKeys()")
		Assert(ReleasePos > 0,
			Fn . " must call the bounded synthetic-key owner drain")
		if (Fn == "Ergopti_OnShutdown") {
			RefusalPos := InStr(Body, "if !SyntheticReleased")
			AbortPos := InStr(Body, "return 1", , RefusalPos)
			RetryPos := InStr(Body, "SetTimer(TapHoldReleaseSyntheticKeys, -1)", , RefusalPos)
			Assert(RefusalPos > ReleasePos and RetryPos > RefusalPos
				and AbortPos > RetryPos,
				"shutdown must retry and abort exit rather than destroy a failed release owner")
		}
		Compared := 0
		for _, Cleanup in ["LoggerStart", "GestureScreenshotCancelAll", "GetSelectionCancel", ".Stop()",
			"TooltipHide", "LLM_Engine_StopGeneration", "KLPF_CancelBuild", "UIASW_Stop",
			"KL_Stop", "HotstringPrefixWatcherStop", "HookDispatcher.Stop",
			"KLWV_CloseAll", "OllamaWV_Close", "_Updater_AbortStagingOnExit"] {
			CleanupPos := InStr(Body, Cleanup)
			if (CleanupPos = 0)
				continue
			Compared++
			Assert(CleanupPos > ReleasePos,
				Fn . " must release OS-level modifiers before slower subsystem teardown: " . Cleanup)
		}
		Assert(Compared >= 6,
			Fn . " lifecycle-order test must compare the synthetic release against the teardown class, not one hand-picked sibling")
	}
}
Test("tap-holds AHK-03: Suspend and Shutdown share the early bounded synthetic-key cleanup",
	_THSB_SuspendAndShutdownShareEarlySyntheticCleanup)

; The ledger is shared by hotkey finalizers and lifecycle callbacks. Critical
; must cover only the snapshot/send/commit transaction, always restore the
; caller's setting, and never grow around a wait or file/registry operation.
_THSB_SyntheticLedgerTransactionsUseShortCriticalSpans() {
	for Fn in ["TapHoldReleasePhysicalKey", "TapHoldSyntheticKeyDown",
		"TapHoldSyntheticKeyUp", "TapHoldReleaseSyntheticKeys"] {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must exist for the synthetic-ledger atomicity guard")
		EnterPos := InStr(Body, 'Critical("On")')
		RestorePos := InStr(Body, "Critical(PreviousCritical)")
		Assert(EnterPos > 0 and RestorePos > EnterPos,
			Fn . " must restore its short Critical span after the ledger/send commit")
		CriticalBody := SubStr(Body, EnterPos, RestorePos - EnterPos)
		Assert(!RegExMatch(CriticalBody, "\bLogger(?:Start|Success|Debug|Info|Warn|Error|Fatal)\s*\("),
			Fn . " must defer synchronous file logging until after Critical is restored")
		Assert(!RegExMatch(Body, "i)\b(KeyWait|Sleep|FileRead|FileOpen|RegRead|DllCall)\s*\("),
			Fn . " must not hold Critical across waits, file/registry I/O, or raw OS calls")
	}
	DownBody := _DriverFuncBody("TapHoldSyntheticKeyDown")
	RetryBody := _DriverFuncBody("_TH_RetrySyntheticKeyRelease")
	Assert(RetryBody != "", "the release retry helper must exist for the Critical I/O guard")
	Assert(InStr(DownBody, 'TextPressKey(KeysToPress, "Down", false, Transition)') > 0,
		"all 0->1 keys must enter one sender-owned Array transaction with an explicit rollback outcome")
	Assert(InStr(DownBody, "Transition.RollbackFailedKeys") > 0
		and InStr(DownBody, "_TH_MarkSyntheticKeyReleasePending(Name)") > 0,
		"failed compensating Ups must move into the release-pending ledger before Critical is restored")
	Assert(InStr(RetryBody, 'TextPressKey(Key, "Up", false)') > 0,
		"synthetic Up failures must defer synchronous ERROR flushing until Critical is restored")
	PhysicalBody := _DriverFuncBody("TapHoldReleasePhysicalKey")
	Assert(InStr(PhysicalBody, 'TextPressKey(Key, "Up", false)') > 0,
		"physical early release must also defer synchronous ERROR flushing until Critical is restored")
}
Test("tap-holds AHK-03: synthetic ownership uses short transactional Critical spans",
	_THSB_SyntheticLedgerTransactionsUseShortCriticalSpans)

; The owner verdict is part of the public contract. A caller that continues
; into KeyWait after a false Down recreates an untracked final Up and can clear
; a physical modifier. Derive every production call so a new sibling joins the
; guard automatically instead of extending a hand-maintained filename list.
_THSB_EverySyntheticDownCallerConsumesTheVerdict() {
	Src := _DriverSourceNoComments()
	Needle := "m)^[^`r`n]*TapHoldSyntheticKeyDown\([^`r`n]*"
	Pos := 1
	CallCount := 0
	while Found := RegExMatch(Src, Needle, &Match, Pos) {
		Line := Match[0]
		Pos := Found + Match.Len
		if InStr(Line, "TapHoldSyntheticKeyDown(Key) {")
			continue
		CallCount++
		Assert(RegExMatch(Line, "i)^\s*if\b[^`r`n]*!\s*TapHoldSyntheticKeyDown\("),
			"every synthetic Down caller must stop when ownership is not proven: " . Line)
	}
	Assert(CallCount >= 15,
		"the verdict guard must enumerate the full driver-wide synthetic-Down caller class")
}
Test("tap-holds AHK-03: every synthetic Down caller consumes the ownership verdict",
	_THSB_EverySyntheticDownCallerConsumesTheVerdict)

; The pass-through LAlt/RCtrl tap paths have a real physical key-up as their
; fallback, so they use a separate helper instead of fabricating a synthetic
; owner. They still must suppress the tap action when the early Up fails.
_THSB_EveryPhysicalReleaseCallerConsumesTheVerdict() {
	Src := _DriverSourceNoComments()
	Needle := "m)^[^`r`n]*TapHoldReleasePhysicalKey\([^`r`n]*"
	Pos := 1
	CallCount := 0
	while Found := RegExMatch(Src, Needle, &Match, Pos) {
		Line := Match[0]
		Pos := Found + Match.Len
		if InStr(Line, "TapHoldReleasePhysicalKey(Key) {")
			continue
		CallCount++
		Assert(RegExMatch(Line, "i)^\s*if\b[^`r`n]*!\s*TapHoldReleasePhysicalKey\("),
			"every pass-through physical release caller must suppress its tap action on failure: " . Line)
	}
	Assert(CallCount >= 2,
		"the verdict guard must enumerate both LAlt and RCtrl pass-through release paths")
}
Test("tap-holds AHK-03: every physical early-release caller consumes its verdict",
	_THSB_EveryPhysicalReleaseCallerConsumesTheVerdict)

; F45 (audit 2026-07-20): every nav-layer mapping routes through the send-based
; ActionLayer except SC031, which called WinMaximize("A") directly with no try —
; WinMaximize throws TargetError when no window is active (tray-only desktop, or the
; foreground window closing mid-press), and layer handlers must not throw.
_THSB_WindowVerbsAreGuarded() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\platform\remap\nav_layer.ahk")
	Assert(Src != "", "platform/remap/nav_layer.ahk must be readable")
	Code := _StripFullLineComments(Src)
	for Verb in ["WinMaximize(", "WinMinimize(", "WinRestore("] {
		Pos := InStr(Code, Verb)
		while (Pos > 0) {
			; The statement must be guarded: a `try ` immediately precedes the call.
			Before := SubStr(Code, Max(1, Pos - 6), Min(6, Pos - 1))
			Assert(InStr(Before, "try ") > 0,
				"every window-management call in the nav layer must be wrapped in try — " . Verb . " throws when no window is active")
			Pos := InStr(Code, Verb, , Pos + 1)
		}
	}
}
Test("tap-holds: nav-layer window verbs are guarded against a missing active window",
	_THSB_WindowVerbsAreGuarded)
