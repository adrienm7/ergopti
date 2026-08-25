; tests/meta/test_fast_timer_inventory.ahk

; ==============================================================================
; MODULE: Fast Repeating Timer Inventory
; DESCRIPTION:
; Every repeating SetTimer in this driver runs on the SAME message thread that
; dispatches keystrokes. A poller that fires four times a second and does a
; WinGetTitle against a Not Responding window, or a cross-process COM
; round-trip, is not "background work": it is a periodic stall inserted into
; typing. The driver already carries twenty of them, and they were added one at
; a time, each individually defensible, with nothing anywhere that could show
; the accumulated total.
;
; This is an INVENTORY, not a ban. Every sub-second poller is listed below with
; the period it is expected to have, and the guard fails on three things:
;   1. a new sub-second repeating timer nobody listed;
;   2. a listed timer whose period changed — including a period that got
;      SHORTER, which is the change that silently costs the most and is the
;      easiest to make (one constant, in one module, reviewed on its own);
;   3. a listed timer that no longer exists, so the table cannot rot into a set
;      of exemptions for code that is gone.
;
; A period that cannot be resolved statically (a caller-supplied argument, an
; expression, a randomised interval) is recorded as unresolved and still has to
; be listed — fail-closed, because an unreadable period is exactly where an
; unnoticed fast poll would hide.
;
; SCOPE: source introspection via the move-resilient driver-source helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; A repeating timer at or above this period is slow enough not to be a typing
; hazard on its own, and is left out of the inventory to keep the table about
; the ones that matter.
global _FTI_FAST_THRESHOLD_MS := 1000
; Recorded period for a site whose interval cannot be resolved from source.
global _FTI_UNRESOLVED := "?"
; Floor on the number of repeating SetTimer sites the scan must find. The scan
; is the whole test: one that stops matching finds nothing, asserts nothing and
; passes. Set below the current count so ordinary churn does not trip it.
global _FTI_MIN_REPEATING_SITES := 30





; ================================
; ================================
; ======= 2/ The inventory =======
; ================================
; ================================

; Every repeating timer that fires more often than once a second, keyed by the
; callback expression as written at the SetTimer call site, valued by the period
; the driver is expected to arm it with.
_FTI_Inventory() {
	return Map(
		'Job["timer"]',                 "15",    ; selection capture, torn down on completion
		"_SuspendPendingPoll",          "25",    ; short-lived, awaits a pending suspend
		"FocusTimerFn",                 "50",    ; generation-bound focus snapshot, title deadline <= 5 ms
		"_LLM_PointerWatch_MoveFn",     "50",    ; only armed while a prediction is on screen
		"WPMWidget_MouseWatch",         "50",    ; only armed while the WPM widget is visible
		"_SR_Poll",                     "100",   ; shell_runner completion poll
		"_SR_TreePoll",                 "100",   ; only armed while a Job-owned process tree is live
		"_LLM_NavEventOwnerServiceFn",  "100",   ; native receipt/fault drain, disarmed on Stop
		"_SpotlightTick",               "100",   ; only armed while spotlight is open
		"_TooltipDequeuePollFn",        "100",   ; only armed during a dequeue cycle
		"AwakeCheckMouseMoved",         "150",   ; only armed in awake mode
		"KLHook.flush_timer",           "200",   ; keylogger buffer flush
		"PLC_Poll",                     "250",   ; process lifecycle watch
		"_Updater_MonitorStagingWorker", "250",  ; only armed while staging an update
		"KLHook.context_timer",         "250",   ; memory-only projection of shared focus snapshot
		"KLMouse.park_timer_fn",        "250",   ; mouse park detection
		"_LoggerFlush",                 "500",   ; batched log write
		"_UIA_SelectionPollTimer",      "500",   ; cross-process COM round-trip
		"WPMWidget_Tick",               "500",   ; only armed while the WPM widget is visible
		"BoundFn",                      "?",     ; generic scheduler adapter, period is the caller's
		"_SuspendStateWatchdog",        "?",     ; period is a non-global constant
		"SimulateActivity",             "?")     ; randomised interval, awake mode only
}





; =============================================
; =============================================
; ======= 3/ Scanning the driver source =======
; =============================================
; =============================================

; Split the argument list of a call whose opening parenthesis is at OpenPos.
; Bracket- and quote-aware: a comma inside a Bind(), a nested call or a string
; is not an argument separator, and a naive split on "," reports the wrong
; period for a third of this driver's timers.
; @param Src {String} Driver source.
; @param OpenPos {Integer} 1-based position of the opening parenthesis.
; @returns {Array} Trimmed argument expressions.
_FTI_SplitArgs(Src, OpenPos) {
	Args := []
	Depth := 0
	Cur := ""
	Quote := ""
	Idx := OpenPos
	Len := StrLen(Src)
	while (Idx <= Len) {
		Ch := SubStr(Src, Idx, 1)
		if (Quote != "") {
			Cur .= Ch
			if (Ch == Quote)
				Quote := ""
			Idx += 1
			continue
		}
		if (Ch == '"' or Ch == "'") {
			Quote := Ch
			Cur .= Ch
		} else if (Ch == "(" or Ch == "[" or Ch == "{") {
			Depth += 1
			if (Depth == 1)
				Cur := ""
			else
				Cur .= Ch
		} else if (Ch == ")" or Ch == "]" or Ch == "}") {
			Depth -= 1
			if (Depth == 0) {
				Args.Push(Trim(Cur, " `t`r`n"))
				return Args
			}
			Cur .= Ch
		} else if (Ch == "," and Depth == 1) {
			Args.Push(Trim(Cur, " `t`r`n"))
			Cur := ""
		} else {
			Cur .= Ch
		}
		Idx += 1
	}
	return Args
}

_FTI_MultilineOneShotKeepsItsSign() {
	Src := "SetTimer(_DeadlineOwner,`n`t-Max(1, DelayMs))"
	Args := _FTI_SplitArgs(Src, InStr(Src, "("))
	AssertEqual(2, Args.Length,
		"the timer scanner fixture must produce both SetTimer arguments")
	AssertEqual("-Max(1, DelayMs)", Args[2],
		"argument trimming must remove line breaks without dropping the unary minus; otherwise a multiline one-shot is misclassified as an unresolved repeating poller")
}

; Resolve a period expression to milliseconds, or "" when it cannot be read
; statically. Only a numeric literal or a declared numeric constant resolves:
; a bare local variable deliberately does NOT, because a match on some unrelated
; assignment elsewhere in the driver would invent a period out of nothing.
; @param Src {String} Driver source.
; @param Expr {String} The period expression as written.
; @returns {String} Milliseconds as text, or "" when unresolved.
_FTI_ResolvePeriod(Src, Expr) {
	if RegExMatch(Expr, "^\d+$")
		return Expr
	if !RegExMatch(Expr, "^(?:[_A-Za-z][_A-Za-z0-9]*\.)?([_A-Za-z][_A-Za-z0-9]*)$", &Name)
		return ""
	if RegExMatch(Src, "m)^\s*(?:global|static)\s+" . Name[1] . "\s*:=\s*(\d+)\b", &Value)
		return Value[1]
	return ""
}

; Every repeating SetTimer site in the driver.
; One-shots (a negative period) and cancels (period 0) are excluded: neither can
; become a background poller.
; @returns {Array} { Callback, Period } — Period is "" when unresolved.
_FTI_RepeatingSites() {
	static Sites := ""
	if IsObject(Sites)
		return Sites
	Src := _DriverSourceNoComments()
	Sites := []
	Pos := 1
	while (Pos := InStr(Src, "SetTimer(", , Pos)) {
		OpenPos := Pos + StrLen("SetTimer(") - 1
		Args := _FTI_SplitArgs(Src, OpenPos)
		Pos += 1
		if (Args.Length < 2)
			continue
		Period := Args[2]
		if (SubStr(Period, 1, 1) == "-" or Period == "0")
			continue
		Sites.Push({ Callback: Args[1], Period: _FTI_ResolvePeriod(Src, Period) })
	}
	return Sites
}





; =============================
; =============================
; ======= 4/ Assertions =======
; =============================
; =============================

_FTI_NoUnlistedFastPoller() {
	global _FTI_FAST_THRESHOLD_MS, _FTI_UNRESOLVED, _FTI_MIN_REPEATING_SITES
	Sites := _FTI_RepeatingSites()
	Assert(Sites.Length >= _FTI_MIN_REPEATING_SITES,
		"the repeating-timer scan found only " . Sites.Length . " site(s) — it must still reach the whole driver, or this guard passes by finding nothing")

	Inventory := _FTI_Inventory()
	for , Site in Sites {
		Resolved := (Site.Period != "")
		if (Resolved and (Site.Period + 0) >= _FTI_FAST_THRESHOLD_MS)
			continue
		Assert(Inventory.Has(Site.Callback),
			"a repeating timer fires every " . (Resolved ? Site.Period . " ms" : "unreadable interval") . " on the keystroke-dispatch thread and is not in the inventory: " . Site.Callback . ". Add it with its period and a one-line justification, or make it a one-shot. Every poller here is a periodic stall inserted into typing")
		Expected := Inventory[Site.Callback]
		Actual := Resolved ? Site.Period : _FTI_UNRESOLVED
		Assert(Expected == Actual,
			"the period of " . Site.Callback . " changed from " . Expected . " to " . Actual . ". Update the inventory deliberately — a shortened poll is the cheapest possible change to make and the most expensive to run, and nothing else in the suite would notice it")
	}
}

_FTI_InventoryHasNoStaleEntries() {
	Sites := _FTI_RepeatingSites()
	Seen := Map()
	for , Site in Sites
		Seen[Site.Callback] := true
	for Callback in _FTI_Inventory() {
		Assert(Seen.Has(Callback),
			"the inventory lists " . Callback . " but the driver no longer arms it as a repeating timer. Remove the entry: a table that keeps entries for code that is gone stops being an inventory and becomes a list of exemptions nobody rereads")
	}
}


Test("meta timers: no sub-second repeating timer exists outside the inventory",
	_FTI_NoUnlistedFastPoller)
Test("meta timers: the timer inventory has no stale entries",
	_FTI_InventoryHasNoStaleEntries)
Test("meta timers: multiline one-shot periods retain their negative sign",
	_FTI_MultilineOneShotKeepsItsSign)
