; tests/meta/test_hookdispatcher_swallow.ahk

; ==============================================================================
; MODULE: HookDispatcher Swallow Meta Test
; DESCRIPTION:
; Static source guard for the "dispatch-swallows-subscriber-errors" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_THS_Check() {
	Src := _DriverDirConcat("lib")
	Assert(Src != "", "Source file must exist")
	Assert(InStr(Src, "catch as e") > 0, "HookDispatcher must catch subscriber exceptions")
	Assert(InStr(Src, 'LoggerWarn("HookDispatcher"') > 0, "HookDispatcher must log subscriber exceptions")
}

; Regression guard: the catch block must escalate to the global error handler so
; modifier-release logic (_ShouldReleaseModifier) runs when a subscriber throws
; during a Ctrl/Shift/Alt keydown. Before this fix the modifier stayed logically
; stuck after any subscriber exception, requiring a script restart.
_THS_CheckModifierRelease() {
	Src := _DriverDirConcat("lib")
	; Case-sensitive: assert the CALL ``ErgoptiGlobalErrorHandler(e, ...)`` exists,
	; not merely the definition ``(Exc, Mode)`` now living in lib/error_net.ahk.
	Assert(InStr(Src, "ErgoptiGlobalErrorHandler(e", true) > 0,
		"HookDispatcher catch must call ErgoptiGlobalErrorHandler(e, ...) to release stuck modifiers")
}

_THS_EscalationIsThrottled() {
	Src := _DriverDirConcat("lib")
	; Find the catch region. The escalation must appear inside the throttle if-block,
	; not after it — otherwise every exception fires the heavyweight crash handler per keystroke.
	; Verify: the ErgoptiGlobalErrorHandler call must not appear AFTER the closing brace of
	; the throttle block within the catch.
	; Simple check: the token after the throttle block's _err_cache[sig] := now assignment
	; must contain ErgoptiGlobalErrorHandler before the next unindented block closes.
	; Case-sensitive on the call signature so we match HookDispatcher's CALL
	; ``ErgoptiGlobalErrorHandler(e, ...)`` (lowercase e) and NOT the function
	; DEFINITION ``ErgoptiGlobalErrorHandler(Exc, Mode)`` in lib/error_net.ahk,
	; which would otherwise sort earlier in the lib/ concat and break the ordering.
	CacheAssignIdx := InStr(Src, "_err_cache[sig] := now")
	EscalateIdx    := InStr(Src, "ErgoptiGlobalErrorHandler(e", true)
	; Also check that ErgoptiGlobalErrorHandler appears WITHIN 300 chars of the cache assignment
	; (inside the if block, not floating after it).
	Assert(EscalateIdx > CacheAssignIdx, "ErgoptiGlobalErrorHandler must appear after throttle cache assignment")
	Assert((EscalateIdx - CacheAssignIdx) < 400,
		"ErgoptiGlobalErrorHandler must be inside the throttle block, not floating outside it after the closing brace")
}

_THS_DeltaIsWrapSafe() {
	Src := _DriverDirConcat("lib")
	Assert(InStr(Src, "& 0xFFFFFFFF") > 0,
		"error cache delta must use 32-bit wrap mask to avoid 49-day suppression")
}

; F18 (audit 2026-07-20): a CONTAINED subscriber fault during the RegisterAllHotstrings
; boot phase (_DriverBootPhase still "starting") escalated to ErgoptiGlobalErrorHandler,
; whose pre-ready branch ExitApp(1)s the whole driver — so one bad keystroke mid-boot
; killed the driver. The escalation must be gated on the ready phase.
_THS_EscalationIsBootPhaseGated() {
	Src := _DriverDirConcat("lib")
	EscalateIdx := InStr(Src, "ErgoptiGlobalErrorHandler(e", true)
	Assert(EscalateIdx > 0, "HookDispatcher catch must call ErgoptiGlobalErrorHandler(e, ...)")
	Before := SubStr(Src, 1, EscalateIdx)
	GateIdx := InStr(Before, '_DriverBootPhase == "ready"', , -1)
	Assert(GateIdx > 0 && (EscalateIdx - GateIdx) < 250,
		"the ErgoptiGlobalErrorHandler escalation must be gated on the ready boot phase so a contained subscriber fault during boot cannot re-enter the fatal pre-ready branch")
}

Test("HookDispatcher: logs swallowed subscriber exceptions", _THS_Check)
Test("HookDispatcher: catch escalates to ErgoptiGlobalErrorHandler for modifier release", _THS_CheckModifierRelease)
Test("hook_dispatcher: ErgoptiGlobalErrorHandler escalation is throttled (not per-keystroke)", _THS_EscalationIsThrottled)
Test("hook_dispatcher: error cache delta uses 32-bit wrap mask", _THS_DeltaIsWrapSafe)
Test("hook_dispatcher: subscriber-fault escalation is gated on the ready boot phase", _THS_EscalationIsBootPhaseGated)

; F35 (audit 2026-07-20): every TapHoldTrack* call in the per-keystroke fan-out was a
; bare `try` with no catch, so a broken tracker silently degraded tap-hold
; disambiguation with nothing in the log (§5.3). They must report — but throttled,
; since they run on every keystroke.
_THS_TrackerFaultsAreReported() {
	Src := _DriverDirConcat("lib")
	Assert(InStr(Src, "static _TrackFault(") > 0,
		"HookDispatcher must expose a throttled tracker-fault reporter")
	; Every tracker call must be paired with exactly one fault report: count both.
	TryCount := 0, Pos := 1
	while (Pos := InStr(Src, "try TapHoldTrack", , Pos)) {
		TryCount++
		Pos += 16
	}
	ReportCount := 0, Pos := 1
	while (Pos := InStr(Src, "HookDispatcher._TrackFault(", , Pos)) {
		ReportCount++
		Pos += 27
	}
	Assert(TryCount > 0, "the fan-out must still call the tap-hold trackers")
	Assert(ReportCount == TryCount,
		"every TapHoldTrack* call must be paired with a _TrackFault report — a silently swallowed tracker fault degrades tap-hold disambiguation invisibly (found "
		. TryCount . " call(s) but " . ReportCount . " report(s))")
	Assert(InStr(Src, '_TrackFault("TapHoldTrackKeyDownByScancode"') > 0,
		"the key-down tracker fault must route through the throttled reporter")
}
Test("hook_dispatcher: tap-hold tracker faults are reported, not silently swallowed",
	_THS_TrackerFaultsAreReported)
