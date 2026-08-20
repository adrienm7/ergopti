; tests/meta/test_fire_log_never_synchronous.ahk

; ==============================================================================
; MODULE: Regression — the hotstring fire log must never run on the keystroke
;         thread (fire-log-never-synchronous)
; DESCRIPTION:
; Typing "abcd" through an expansion produced "acd": a physical key vanished.
;
; ROOT CAUSE ENCODED: KL_LogHotstring is not a cheap record. It flushes the
; keylogger buffer, appends a line to a JSONL file on disk, and pushes WPM
; samples. Called from a fire path it runs on the keystroke thread, inside the
; ~60 ms suppress window armed for the expansion's own send burst and (for the
; space tap-hold) under Critical("On"). A disk spike anywhere in that window —
; a cloud-synced config dir, an AV scan, a slow spindle — holds the thread past
; the point where Windows will still deliver the next keystroke to the hook.
;
; The prefix-watcher fire path was moved onto a deferred queue for exactly this
; reason. The queue was then the ONLY path that used it: the space tap-hold and
; the native dispatch both kept calling KL_LogHotstring inline. Fixing the one
; site that was reported would leave the other, which is the shape this driver
; keeps repeating — so the guard below is an allowlist over every caller in the
; tree, and a new one has to be triaged rather than silently inheriting the bug.
;
; SCOPE: source-level. Both fire paths need a live InputHook and a registered
; keylogger, neither of which exists in the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0

; The ONLY function allowed to call KL_LogHotstring synchronously. It is the
; drain: by construction it already runs off the keystroke path.
global _FLNS_DRAIN_FUNC := "_HSE_DrainFireLog"

; Fire paths that must route through the deferred queue. Each may still name
; KL_LogHotstring as a fallback for contexts where the prefix watcher is not
; loaded, but only AFTER the queue attempt.
global _FLNS_QUEUEING_FIRE_PATHS := ["_SpaceTap", "_HotstringDispatch"]





; ===================================================================
; ===================================================================
; ======= 1/ Every fire path queues instead of logging inline =======
; ===================================================================
; ===================================================================

_FLNS_FirePathsQueue() {
	global _FLNS_QUEUEING_FIRE_PATHS
	for FuncName in _FLNS_QUEUEING_FIRE_PATHS {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . "() must exist in the driver source")

		QueuePos := InStr(Body, "_HSE_QueueFireLog")
		Assert(QueuePos > 0,
			FuncName . " must record the fire through the deferred queue — KL_LogHotstring flushes a buffer, appends to a JSONL file and pushes WPM samples, and doing that on the keystroke thread inside the post-expansion suppress window is what swallowed physical keys")

		; A direct call may survive as the not-loaded fallback, but never as the
		; primary: if it comes first, the queue is dead code and the disk work is
		; back on the keystroke thread.
		DirectPos := InStr(Body, "KL_LogHotstring(")
		if (DirectPos > 0)
			Assert(QueuePos < DirectPos,
				FuncName . " still calls KL_LogHotstring before it queues — the deferred path must be tried FIRST, with the direct call reachable only where the queue does not exist")
	}
}





; ====================================================================
; ====================================================================
; ======= 2/ No other caller reintroduces the synchronous path =======
; ====================================================================
; ====================================================================

; Names of every top-level driver function whose body calls KL_LogHotstring.
; Derived from source so a new caller cannot appear unnoticed.
_FLNS_CallerNames() {
	Src := _DriverSourceNoComments()
	Names := []
	Current := ""
	for Line in StrSplit(Src, "`n", "`r") {
		; A column-0 definition opens a new function scope.
		if RegExMatch(Line, "^([A-Za-z_]\w*)\([^\r\n]*\)\s*\{", &Def)
			Current := Def[1]
		if !InStr(Line, "KL_LogHotstring(")
			continue
		; The definition line of KL_LogHotstring itself is not a call.
		if (Current == "KL_LogHotstring")
			continue
		Seen := false
		for N in Names
			if (N == Current)
				Seen := true
		if !Seen
			Names.Push(Current)
	}
	return Names
}

_FLNS_NoUnexpectedSynchronousCaller() {
	global _FLNS_DRAIN_FUNC, _FLNS_QUEUEING_FIRE_PATHS
	Callers := _FLNS_CallerNames()
	Assert(Callers.Length >= 1,
		"the scan must find the real KL_LogHotstring callers (found " . Callers.Length . ") — a scan that matches nothing cannot fail")

	for Name in Callers {
		Allowed := (Name == _FLNS_DRAIN_FUNC)
		for Fire in _FLNS_QUEUEING_FIRE_PATHS
			if (Name == Fire)
				Allowed := true
		Assert(Allowed,
			"'" . Name . "' calls KL_LogHotstring and is not a known fire path. Route it through _HSE_QueueFireLog if it runs on the keystroke thread; if it genuinely does not, add it here with the reason. Inheriting the synchronous call by default is how the space tap-hold kept the key-swallow bug after the prefix watcher was fixed")
	}
}

; The queue must stay genuinely deferred. If the drain were ever invoked
; directly by the enqueue function, every assertion above would be satisfied
; while the disk work returned to the keystroke thread.
_FLNS_QueueIsActuallyDeferred() {
	Body := _DriverFuncBody("_HSE_QueueFireLog")
	Assert(Body != "", "_HSE_QueueFireLog() must exist in the driver source")
	Assert(InStr(Body, "_HSE_ArmFireLogDrain") > 0,
		"the enqueue must hand the record to the lifecycle-owned timer arm — that is the only thing that moves the flush off the keystroke thread without losing suspend ownership")
	Assert(InStr(Body, "KL_LogHotstring(") == 0,
		"the enqueue must not log inline; it exists precisely to avoid that")

	ArmBody := _DriverFuncBody("_HSE_ArmFireLogDrain")
	Assert(ArmBody != "", "_HSE_ArmFireLogDrain() must exist in the driver source")
	Assert(InStr(ArmBody, "_HSE_DrainFireLog.Bind(_PrefixDeferredGeneration)") > 0,
		"the lifecycle-owned arm must freeze the exact generation in its callback — a stale queued timer must not impersonate the resumed owner")
	Assert(InStr(ArmBody, "TimerAfter(") > 0,
		"the lifecycle-owned callback must schedule through the TimerScheduler port")
	AdapterBody := _DriverFuncBody("TimerAfter")
	Assert(InStr(AdapterBody, "SetTimer(BoundFn, Ms)") > 0,
		"TimerAfter must still reach the OS one-shot primitive — a synchronous fake adapter would make the deferral assertion false-green")
	Assert(InStr(ArmBody, "KL_LogHotstring(") == 0,
		"the timer arm must not hide a synchronous sink call")
}


Test("meta fire-log-never-synchronous: every fire path queues the record",
	_FLNS_FirePathsQueue)
Test("meta fire-log-never-synchronous: no unexpected synchronous caller",
	_FLNS_NoUnexpectedSynchronousCaller)
Test("meta fire-log-never-synchronous: the queue stays deferred",
	_FLNS_QueueIsActuallyDeferred)
