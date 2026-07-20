; tests/meta/test_healthcheck_collectors_guarded.ahk

; ==============================================================================
; MODULE: Healthcheck Collector Guard Meta Test
; DESCRIPTION:
; HealthCheck_Run used to call ten collectors bare, eight of them inside a single
; Map(...) constructor, with not one log line between its LoggerStart and its
; LoggerSuccess. Any one of them throwing aborted the whole run.
;
; That matters because the healthcheck is run to BUILD A CRASH REPORT, and the
; collectors read subsystem state the crash has just left half-built — so the
; run was most likely to abort exactly when it was most needed. Field evidence:
; "Running healthcheck..." was the last line two crashed processes ever wrote,
; and neither produced a crash report. _HealthCheck_SysInfo is the most exposed
; of the ten: WMI ConnectServer, three RegRead calls and a git subprocess poll.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE — an unguarded collector between START and SUCCESS —
;    rather than the symptom of one missing crash report.
; 2. Asserts the collectors are OUT of the Map(...) constructor, because a guard
;    cannot be applied to a bare call nested in an argument list.
; 3. Enumerates the whole collector set, so an eleventh added bare fails here.
;
; SCOPE: source introspection of ui/healthcheck/core.ahk via the move-resilient
; driver-source helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================
; =============================================
; ======= 1/ Every collector is guarded =======
; =============================================
; =============================================

; The enriched collector set, by the field name each populates in the result.
_HCG_CollectorFields() {
	return ["recent_issues", "sys", "pause_state", "keylogger", "llm",
		"layout", "hotstrings", "logs", "config"]
}

_HCG_AllCollectorsAreGuarded() {
	Body := _DriverFuncBody("HealthCheck_Run")
	Assert(Body != "", "HealthCheck_Run() must exist")

	for Field in _HCG_CollectorFields() {
		Assert(RegExMatch(Body, '_HealthCheck_Collect\("' . Field . '"') > 0,
			"collector '" . Field . "' must run through _HealthCheck_Collect — a bare call inside HealthCheck_Run aborts the entire run, and the run exists to produce a crash report")
	}
}

; A guard is only reachable if the call was hoisted out of the argument list, so
; assert the Map(...) constructor no longer invokes any collector directly.
_HCG_ConstructorHasNoBareCollectorCalls() {
	Body := _DriverFuncBody("HealthCheck_Run")
	Assert(Body != "", "HealthCheck_Run() must exist")

	MapPos := InStr(Body, "Result := Map(")
	Assert(MapPos > 0, "HealthCheck_Run must still build its result with Result := Map(")
	Constructor := SubStr(Body, MapPos)

	Assert(RegExMatch(Constructor, "_HealthCheck_[A-Za-z]+\(") == 0,
		"the Result := Map(...) constructor must not call a collector directly — a call nested in an argument list cannot be individually guarded, which is exactly how one failing subsystem took the whole healthcheck down")
}

; The guard helper itself must degrade rather than rethrow, and must name the
; culprit: an unpaired START that names nothing is what made the original
; incidents undiagnosable.
_HCG_GuardHelperDegradesAndNames() {
	Body := _DriverFuncBody("_HealthCheck_Collect")
	Assert(Body != "", "_HealthCheck_Collect() must exist")

	Assert(InStr(Body, "catch as") > 0,
		"_HealthCheck_Collect must catch explicitly, not with a bare try")
	Assert(InStr(Body, "LoggerWarn") > 0,
		"_HealthCheck_Collect must report a failed collector at WARNING so the culprit reaches the errors sink")
	Assert(InStr(Body, "Name") > 0,
		"_HealthCheck_Collect must include the collector name in its log output")
	Assert(InStr(Body, "return Value") > 0,
		"_HealthCheck_Collect must return a value on every path so one failed collector degrades one field, not the run")

	; trace/done brackets the call, so a collector that HANGS rather than throws
	; leaves the last unpaired TRACE pointing at it (conventions 4.2).
	TracePos := InStr(Body, "LoggerTrace")
	DonePos := InStr(Body, "LoggerDone")
	Assert(TracePos > 0 and DonePos > TracePos,
		"_HealthCheck_Collect must bracket the call with a LoggerTrace/LoggerDone pair so a hanging collector is identifiable from the last unpaired trace")
}


Test("meta healthcheck: every collector runs through the guard helper",
	_HCG_AllCollectorsAreGuarded)
Test("meta healthcheck: the result constructor makes no bare collector calls",
	_HCG_ConstructorHasNoBareCollectorCalls)
Test("meta healthcheck: the guard helper degrades the field and names the collector",
	_HCG_GuardHelperDegradesAndNames)
