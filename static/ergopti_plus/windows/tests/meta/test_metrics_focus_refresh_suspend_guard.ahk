; static/ergopti_plus/windows/tests/meta/test_metrics_focus_refresh_suspend_guard.ahk

; ==============================================================================
; MODULE: Metrics Focus-Refresh Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for finding F-06 (metrics-focus-poll-bypasses-suspend),
; audit 2026-07-20 second pass.
;
; A generation-bound callback delegates to MF_RefreshFocus as a REPEATING
; SetTimer at MF_FOCUS_TTL_MS (50 ms), acquiring one bounded canonical focus
; snapshot. The previous lifecycle had
; three compounding defects:
;   1. no A_IsSuspended guard  — SetTimer callbacks bypass native Suspend, which
;      only disarms hotkeys, so it probed the foreground window 20x/second for
;      the entire pause. Even a bounded probe still observes the foreground and
;      shares the keyboard-dispatch thread. This violates « pause = tout
;      éteint » and is privacy-relevant.
;   2. no exact cancel site    — there was exactly one repeating timer arm and
;      no cancellation of that timer’s exact callback identity, so it ran for
;      the whole process lifetime. A shared callback would also let a stale
;      Stop cancel a newer Start during a rapid pause/resume transition.
;   3. armed unconditionally   — MF_StartFocusRefresh() sat OUTSIDE the
;      `if MetricsShortcuts.enabled` guard, so users with metrics disabled paid
;      the poll for a cache whose only reader (MF_ShouldFilter) never runs.
;
; Meta-static rather than behavioral: the headless harness cannot run a real
; repeating OS timer across a suspend transition, so the STRUCTURAL guarantees
; are what we pin.
;
; NOTE on shape: this test deliberately asserts the invariant across the whole
; suspend-reactor CLASS (guard + cancel + re-arm), not just the one line that
; was missing. Five findings in this audit exist because a guard test named the
; site that was fixed instead of enumerating the class it belongs to.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================================
; ================================================================
; ======= 1/ The tick must refuse to probe while suspended =======
; ================================================================
; ================================================================

_MFS_TickIsSuspendGuarded() {
	Body := _DriverFuncBody("MF_RefreshFocus")
	Assert(Body != "", "MF_RefreshFocus must exist in infra/metrics/metrics_filters.ahk")

	Guard := InStr(Body, "A_IsSuspended")
	Assert(Guard > 0,
		"MF_RefreshFocus must bail out on A_IsSuspended — SetTimer callbacks bypass native Suspend and would otherwise observe focus 20x/second for the entire pause")

	Delegate := InStr(Body, "_MF_RefreshFocusNonCritical")
	Assert(Delegate > Guard,
		"the A_IsSuspended guard must precede the non-Critical acquisition delegate")
	NativeBody := _DriverFuncBody("_MF_RefreshFocusNonCritical")
	Assert(NativeBody != "" && InStr(NativeBody,
		"WICaptureBoundedFocusSnapshot") > 0,
		"the delegated refresh must still own the bounded foreground acquisition")
}
Test("metrics: MF_RefreshFocus refuses to probe while suspended (F-06)", _MFS_TickIsSuspendGuarded)





; ==========================================================
; ==========================================================
; ======= 2/ The repeating timer must be cancellable =======
; ==========================================================
; ==========================================================

_MFS_PollIsCancellable() {
	Start := _DriverFuncBody("MF_StartFocusRefresh")
	Stop := _DriverFuncBody("MF_StopFocusRefresh")
	Tick := _DriverFuncBody("_MF_FocusTimerTick")
	Assert(Start != "" && Stop != "" && Tick != "",
		"the focus refresh lifecycle must expose start, stop, and generation-bound tick functions")

	Pending := InStr(Start, 'failure_reason: "refresh_pending"')
	PendingPublish := InStr(Start, "_MF_ApplyFocusStateLocked(PendingState)")
	Bind := InStr(Start, "_MF_FocusTimerTick.Bind(StartGeneration)")
	Store := InStr(Start, "MetricsFocusCache.timer_fn := FocusTimerFn")
	Arm := InStr(Start, "SetTimer(FocusTimerFn, MF_FOCUS_TTL_MS)")
	Assert(Pending > 0 && PendingPublish > Pending && Bind > PendingPublish
		&& Store > Bind && Arm > Store,
		"each start must publish a fail-closed pending barrier, bind its lifecycle generation, publish that exact callback identity, then arm it — a shared timer callback lets stale stop/start work target the wrong owner")

	Capture := InStr(Stop, "FocusTimerFn := MetricsFocusCache.timer_fn")
	Clear := InStr(Stop, "MetricsFocusCache.timer_fn := 0")
	Cancel := InStr(Stop, "SetTimer(FocusTimerFn, 0)")
	Assert(Capture > 0 && Clear > Capture && Cancel > Clear,
		"stop must capture, retire, then cancel the exact timer identity owned by that lifecycle — without this cancel the poll survives pause, while cancelling a shared callback can evict a newer resume owner")

	Assert(InStr(Tick, "MetricsFocusCache.lifecycle_generation = OwnerGeneration") > 0,
		"a queued callback from an older lifecycle must verify its owner generation before acquiring focus")
	Assert(InStr(Stop, 'failure_reason: "refresh_stopped"') > 0
		&& InStr(Stop, "_MF_ApplyFocusStateLocked(StoppedState)") > 0,
		"stop must publish an invalid canonical snapshot before native Suspend can lift; otherwise an early resumed keystroke can reuse the pre-pause window identity")
}
Test("metrics: the focus poll has generation-bound arm/cancel ownership (F-06)", _MFS_PollIsCancellable)





; =========================================================
; =========================================================
; ======= 3/ Suspend stops it and resume re-arms it =======
; =========================================================
; =========================================================

; Both halves matter and fail in opposite directions: without the stop, a paused
; driver keeps probing (leak); without the re-arm, the cache freezes after the
; first pause and every metrics privacy filter reads a stale foreground window
; for the rest of the session (dead feature).
_MFS_SuspendReactorOwnsThePoll() {
	Enter := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Enter != "", "Ergopti_OnSuspendEnter must exist in infra/lifecycle.ahk")
	Assert(InStr(Enter, "MF_StopFocusRefresh") > 0,
		"Ergopti_OnSuspendEnter must stop the metrics focus poll, like it already stops the LLM pointer watch and the updater async checks — all three are timers that bypass native Suspend")

	Resume := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(Resume != "", "Ergopti_OnSuspendResume must exist in infra/lifecycle.ahk")
	Assert(InStr(Resume, "MF_StartFocusRefresh") > 0,
		"Ergopti_OnSuspendResume must re-arm the metrics focus poll — a stop with no matching re-arm leaves the focus cache frozen after the first pause, so every metrics privacy filter reads a stale foreground window for the rest of the session")
}
Test("metrics: suspend stops and resume re-arms the focus poll (F-06)", _MFS_SuspendReactorOwnsThePoll)





; =============================================================
; =============================================================
; ======= 4/ The poll is gated on its consuming feature =======
; =============================================================
; =============================================================

; The cache has exactly ONE reader, MF_ShouldFilter, which only runs when the
; keylogger/metrics feature is on. Arming the poll unconditionally made users
; with metrics disabled pay 20 blocking WM_GETTEXT probes a second for data
; nothing reads.
_MFS_PollIsFeatureGated() {
	; Helper read, never a pinned path (a CI ratchet caps those at 20). Each
	; file’s content is contiguous inside the concatenation, so anchoring on two
	; tokens unique to the boot block isolates it without knowing which file it
	; lives in. Comment-stripped so prose mentioning these tokens cannot satisfy
	; the assertion.
	Src := _DriverSourceNoComments()

	; The boot metrics block opens with this debug line and closes past KL_Init;
	; both strings appear exactly once in the driver.
	GatePos := InStr(Src, 'LoggerDebug("Startup", "Metrics enabled')
	Assert(GatePos > 0,
		"prerequisite: the boot metrics gate must still open with its `Metrics enabled` debug line — update this anchor if that log message was reworded")

	InitPos := InStr(Src, "KL_Init(", , GatePos)
	Assert(InitPos > GatePos,
		"prerequisite: KL_Init() must follow the metrics gate — it is the consumer that reads the focus cache")

	Segment := SubStr(Src, GatePos, InitPos - GatePos)
	Assert(InStr(Segment, "MF_StartFocusRefresh()") > 0,
		"the boot-time MF_StartFocusRefresh() must sit INSIDE the `if MetricsShortcuts.enabled` block and BEFORE KL_Init — the focus cache's only reader is MF_ShouldFilter, so with metrics off the poll issues blocking WM_GETTEXT probes nobody reads, and arming it after KL_Init would leave the first events reading an empty cache")
}
Test("metrics: the focus poll is gated on MetricsShortcuts.enabled (F-06)", _MFS_PollIsFeatureGated)
