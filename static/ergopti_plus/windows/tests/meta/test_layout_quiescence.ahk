; tests/meta/test_layout_quiescence.ahk

; ==============================================================================
; MODULE: Layout Reload Quiescence Test
; DESCRIPTION:
; Regression test for the layout-poll-blind-reload finding. The 1 s layout-poll
; timer used to call Reload() the instant the foreground HKL differed, which
; dropped in-flight typing on any transient HKL flicker. The decision now lives
; in the pure helper _ShouldReloadForHkl (modules/keymap/layout_poll_helper.ahk), which only
; returns true when the new layout has been stable across two consecutive polls,
; the user is physically idle, no expansion is in flight, and the driver is
; neither suspended nor on a blacklisted app.
;
; This test drives that helper directly (no OS, no Reload) and asserts every gate
; so a regression to the old blind-reload behaviour fails loudly. _ShouldReloadForHkl
; is supplied by run_all.ahk including modules/keymap/layout_poll_helper.ahk; Assert/AssertEqual
; come from the already-included test_framework.ahk.
; ==============================================================================

_T_LayoutPollReloadQuiescence() {
	last := 100
	pending := 0

	; Same HKL -> no reload, pending cleared.
	res := _ShouldReloadForHkl(100, &last, &pending, false, false, 0, 0, 1000)
	AssertEqual(res, false, "Same HKL must not reload")

	; Suspended -> never reload (a paused driver must not auto-restart).
	res := _ShouldReloadForHkl(200, &last, &pending, true, false, 0, 0, 1000)
	AssertEqual(res, false, "Suspended must not reload")

	; Blacklisted app -> never reload (no disruptive reload mid-game / private app).
	res := _ShouldReloadForHkl(200, &last, &pending, false, true, 0, 0, 1000)
	AssertEqual(res, false, "Blacklisted must not reload")

	; First poll of a changed HKL -> debounce: record pending, do not reload yet.
	res := _ShouldReloadForHkl(200, &last, &pending, false, false, 0, 0, 1000)
	AssertEqual(res, false, "First poll of new HKL must not reload")
	AssertEqual(pending, 200, "Pending HKL must be recorded on first sighting")

	; Second poll but an expansion is in flight (HSE suppressed) -> hold off.
	res := _ShouldReloadForHkl(200, &last, &pending, false, false, 1, 0, 1000)
	AssertEqual(res, false, "HSE suppression must block reload")

	; Second poll but prefix-watcher suppressed -> hold off.
	res := _ShouldReloadForHkl(200, &last, &pending, false, false, 0, 1, 1000)
	AssertEqual(res, false, "Prefix-watcher suppression must block reload")

	; Second poll but the user is actively typing (idle < 400 ms) -> hold off.
	res := _ShouldReloadForHkl(200, &last, &pending, false, false, 0, 0, 100)
	AssertEqual(res, false, "Active typing must not reload")

	; Physical idle time can increase while a modifier remains held; an owned
	; transaction must still veto reload so its matching Up is not lost.
	res := _ShouldReloadForHkl(200, &last, &pending, false, false, 0, 0, 1000, true)
	AssertEqual(res, false, "An active input transaction must block reload even after a long idle interval")

	; Second poll, stable changed HKL, idle, nothing suppressed -> reload now.
	res := _ShouldReloadForHkl(200, &last, &pending, false, false, 0, 0, 1000)
	AssertEqual(res, true, "Stable changed HKL with full quiescence must reload")
	AssertEqual(last, 200, "Last HKL must advance once the reload is authorised")
}

Test("ErgoptiPlus: _ShouldReloadForHkl enforces quiescence and debounce (layout-poll-blind-reload)", _T_LayoutPollReloadQuiescence)

; F29 (audit 2026-07-20): a tray-only / no-foreground boot (logon autostart, RDP
; reconnect) initialises lastHkl to 0 = baseline UNKNOWN. The first observed real
; layout must be ADOPTED as the baseline, never treated as a switch — otherwise the
; driver Reload()s ~2-3 s after boot with no real layout change.
_T_LayoutPollBaselineAdoption() {
	last := 0
	pending := 0
	; First poll after an unknown (0) baseline: adopt, never reload.
	res := _ShouldReloadForHkl(0x040C0C0C, &last, &pending, false, false, 0, 0, 5000)
	AssertEqual(res, false, "First real layout after an unknown (0) baseline must not reload")
	AssertEqual(last, 0x040C0C0C, "The first real layout must be adopted as the baseline")
	AssertEqual(pending, 0, "Adopting the baseline must clear any pending candidate")
	; Second poll of the SAME layout with full quiescence must still not reload.
	res := _ShouldReloadForHkl(0x040C0C0C, &last, &pending, false, false, 0, 0, 5000)
	AssertEqual(res, false, "A confirmed same-as-baseline layout must never reload")
}
Test("ErgoptiPlus: _ShouldReloadForHkl adopts the first layout as baseline after an unknown (0) boot (spurious-reload)", _T_LayoutPollBaselineAdoption)

; The poll's Reload was the last bare one reachable at runtime: a refused close
; request left its successor on "Keep waiting?", and one fired while a hand-off
; reload was pending let that successor's close request claim the pending
; record, so both successors started (layout-poll-reload-handoff). It now goes
; through ReloadPreservingSuspend, and a refusal re-arms the poll. That retry
; first ran every second poll for ever: a refusal that persists relaunched a
; successor each time, repeated a "save failed" notice, and the fifth OnExit
; veto went through the gate that refused it (layout-poll-retry-bounded). The
; cases below drive LayoutPollTick, the entry file's whole poll, through a fake
; lifecycle port.
global _T_LPR := Map()

; Fresh fake lifecycle. Verdict picks what a reload does: "late" launches and
; an OnExit gate refuses it on the next tick, spending one shutdown veto; "sync"
; is refused before launch; "accept" stays pending, as when the process exits.
; VetoBudget is the veto ceiling the fake OnExit applies, like
; LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS. The driver probed layout 0x100.
_T_LPR_Begin(Verdict, VetoBudget) {
	global _T_LPR, _LAST_KEYBOARD_HKL, _PENDING_KEYBOARD_HKL, _LayoutPollRetry
	_T_LPR := Map("verdict", Verdict, "now", 100000, "pending", false,
		"refused_fn", 0, "attempts", [], "vetoes", 0, "veto_budget", VetoBudget,
		"notices", 0)
	_LAST_KEYBOARD_HKL := 0x100
	_PENDING_KEYBOARD_HKL := 0
	Saved := _LayoutPollRetry
	_LayoutPollRetry := _LayoutPollNewRetry(0)
	return Saved
}

_T_LPR_End(Saved) {
	global _LayoutPollRetry
	_LayoutPollRetry := Saved
}

_T_LPR_Reload(RefusedFn) {
	global _T_LPR
	_T_LPR["attempts"].Push(_T_LPR["now"])
	if (_T_LPR["verdict"] == "sync")
		return false
	_T_LPR["pending"] := true
	_T_LPR["refused_fn"] := RefusedFn
	return true
}

_T_LPR_Pending() {
	global _T_LPR
	return _T_LPR["pending"] ? Map("state", "pending") : false
}

_T_LPR_VetoHonored() {
	global _T_LPR
	return _T_LPR["vetoes"] + 1 < _T_LPR["veto_budget"]
}

_T_LPR_Now() {
	global _T_LPR
	return _T_LPR["now"]
}

_T_LPR_Notify(*) {
	global _T_LPR
	_T_LPR["notices"] += 1
}

; Every layout here needs a reload: the boot registrations fit only 0x100, as
; when, without the Ergopti emulation, layouts type the magic key's source
; character on different keys (LayoutRemapNeedsReload).
_T_LPR_Port() {
	return Map("needs_reload", (Hkl) => true, "reload", _T_LPR_Reload, "pending", _T_LPR_Pending,
		"veto_honored", _T_LPR_VetoHonored, "now", _T_LPR_Now, "notify", _T_LPR_Notify)
}

; One second of the poll on foreground layout Hkl, idle and quiet.
_T_LPR_Tick(Hkl) {
	global _T_LPR
	_T_LPR["now"] += 1000
	if (_T_LPR["pending"] && _T_LPR["verdict"] == "late") {
		_T_LPR["pending"] := false
		_T_LPR["vetoes"] += 1
		RefusedFn := _T_LPR["refused_fn"]
		_T_LPR["refused_fn"] := 0
		RefusedFn.Call("an OnExit gate vetoed")
	}
	return LayoutPollTick(Hkl, false, false, 0, 0, 5000, false, _T_LPR_Port())
}

_T_LPR_Ticks(Hkl, Count) {
	Loop Count
		_T_LPR_Tick(Hkl)
}

_T_LayoutPollRetriesARefusedReloadAFewTimes() {
	global _T_LPR, _LAST_KEYBOARD_HKL, LAYOUT_POLL_RELOAD_MAX_ATTEMPTS
	global LAYOUT_POLL_RELOAD_RETRY_BASE_MS
	for _, Verdict in ["late", "sync"] {
		Saved := _T_LPR_Begin(Verdict, 1000)
		try {
			_T_LPR_Ticks(0x200, 120)
			Attempts := _T_LPR["attempts"]
			AssertEqual(LAYOUT_POLL_RELOAD_MAX_ATTEMPTS, Attempts.Length,
				Verdict . ": a refusal that persists must be retried a bounded number of times, not every second poll")
			Loop Attempts.Length - 1 {
				Wait := LAYOUT_POLL_RELOAD_RETRY_BASE_MS * (2 ** (A_Index - 1))
				Assert(Attempts[A_Index + 1] - Attempts[A_Index] >= Wait,
					Verdict . ": retry " . A_Index . " must wait at least " . Wait . " ms after the refusal")
			}
			AssertEqual(1, _T_LPR["notices"], Verdict . ": the user is told once, when the poll gives up")
			AssertEqual(0x100, _LAST_KEYBOARD_HKL, Verdict . ": the tracker stays on the layout the driver probed")
			; Switching back to the probed layout and away again is a new request.
			_T_LPR_Ticks(0x100, 3)
			_T_LPR_Ticks(0x200, 120)
			AssertEqual(2 * LAYOUT_POLL_RELOAD_MAX_ATTEMPTS, _T_LPR["attempts"].Length,
				Verdict . ": a new switch to the layout gets a fresh attempt budget")
			AssertEqual(2, _T_LPR["notices"], Verdict . ": each abandoned switch is reported once")
		} finally _T_LPR_End(Saved)
	}
}
Test("ErgoptiPlus: a refused layout reload is retried with a doubling wait, a few times (layout-poll-retry-bounded)",
	_T_LayoutPollRetriesARefusedReloadAFewTimes)

; The fake OnExit honors vetoes below the budget and forces the next one through,
; as _LifecycleRefuseShutdown does. However many switches ask for a reload, the
; poll must stop before its own refusal would be that forced one.
_T_LayoutPollNeverSpendsTheForcedVeto() {
	global _T_LPR
	Budget := 5
	Saved := _T_LPR_Begin("late", Budget)
	try {
		Loop 4 {
			_T_LPR_Ticks(0x100, 3)
			_T_LPR_Ticks(0x200, 120)
		}
		Assert(_T_LPR["vetoes"] < Budget,
			"the poll's refusals must never reach the forced veto; spent " . _T_LPR["vetoes"] . " of " . Budget)
		AssertEqual(Budget - 1, _T_LPR["attempts"].Length,
			"the poll may use every veto OnExit still honors, and no more")
	} finally _T_LPR_End(Saved)
}
Test("ErgoptiPlus: the layout poll never spends the veto OnExit would force through (layout-poll-retry-bounded)",
	_T_LayoutPollNeverSpendsTheForcedVeto)

; A reload someone else launched must neither be raced nor count as this
; switch's reload: if it is refused, the poll still owes the switch a reload.
_T_LayoutPollWaitsForAPendingReload() {
	global _T_LPR, _LAST_KEYBOARD_HKL
	Saved := _T_LPR_Begin("accept", 1000)
	try {
		_T_LPR["pending"] := true
		_T_LPR_Ticks(0x200, 6)
		AssertEqual(0, _T_LPR["attempts"].Length, "a pending reload must be waited for, never raced")
		AssertEqual(0x100, _LAST_KEYBOARD_HKL, "a pending reload must not count as the reload for the switch")
		; That reload was refused: its record is gone and this process runs on.
		_T_LPR["pending"] := false
		_T_LPR_Ticks(0x200, 2)
		AssertEqual(1, _T_LPR["attempts"].Length,
			"once the other reload is refused, the next confirmed quiet poll reloads for the switch")
		; The poll's own reload is under way: no second one while it is pending.
		_T_LPR_Ticks(0x200, 10)
		AssertEqual(1, _T_LPR["attempts"].Length, "the poll's own pending reload must not be started again")
		AssertEqual(0x200, _LAST_KEYBOARD_HKL, "the poll's own reload under way counts as the reload for the switch")
		AssertEqual(0, _T_LPR["notices"], "nothing was refused, so nothing is reported")
	} finally _T_LPR_End(Saved)
}
Test("ErgoptiPlus: the layout poll waits for a pending reload and retries if it is refused (layout-poll-retry-bounded)",
	_T_LayoutPollWaitsForAPendingReload)

; Native A_TickCount is monotonic 64-bit. A refused reload must become eligible
; after its wait even when the process was inactive for whole DWORD periods.
; The existing lifecycle port records launches without starting a successor.
_T_LayoutPollNativeRetryCase(Origin, Elapsed, ExpectedAttempts) {
	global _T_LPR, _LAST_KEYBOARD_HKL, _PENDING_KEYBOARD_HKL, _LayoutPollRetry
	SavedPort := _T_LPR
	SavedLast := _LAST_KEYBOARD_HKL
	SavedPending := _PENDING_KEYBOARD_HKL
	SavedRetry := _T_LPR_Begin("accept", 1000)
	try {
		_LayoutPollRetry := _LayoutPollNewRetry(0x200)
		_LayoutPollRetry["attempts"] := 1
		_LayoutPollRetry["refused_at"] := Origin
		_LayoutPollRetry["wait_ms"] := 5000
		_T_LPR["now"] := Origin + Elapsed
		_PENDING_KEYBOARD_HKL := 0x200
		Started := LayoutPollTick(0x200, false, false, 0, 0, 5000, false, _T_LPR_Port())
		AssertEqual(ExpectedAttempts, _T_LPR["attempts"].Length,
			"the actual poll must honor the entire native retry interval")
		AssertEqual(ExpectedAttempts != 0, Started, "launch verdict must match the recorded lifecycle call")
		AssertEqual(ExpectedAttempts ? 2 : 1, _LayoutPollRetry["attempts"],
			"only an eligible reload spends one attempt")
		AssertEqual(ExpectedAttempts ? 0x200 : 0x100, _LAST_KEYBOARD_HKL,
			"waiting must restore the probed layout and launching must advance it")
		AssertEqual(0, _T_LPR["notices"], "waiting and accepted launch must not notify a refusal")
	} finally {
		_LayoutPollRetry := SavedRetry
		_T_LPR := SavedPort
		_LAST_KEYBOARD_HKL := SavedLast
		_PENDING_KEYBOARD_HKL := SavedPending
	}
}

Test("Layout poll: retry waits below its native boundary (layout-retry-native64)",
	_T_LayoutPollNativeRetryCase.Bind(1000, 4999, 0))
Test("Layout poll: retry launches at its native boundary (layout-retry-native64)",
	_T_LayoutPollNativeRetryCase.Bind(1000, 5000, 1))
Test("Layout poll: retry crosses a DWORD boundary (layout-retry-native64)",
	_T_LayoutPollNativeRetryCase.Bind(0xFFFFFF00, 5000, 1))
Test("Layout poll: retry retains one full DWORD period (layout-retry-native64)",
	_T_LayoutPollNativeRetryCase.Bind(1000, 0x100000001, 1))
Test("Layout poll: retry retains multiple DWORD periods (layout-retry-native64)",
	_T_LayoutPollNativeRetryCase.Bind(0x100000100, 0x300000002, 1))
Test("Layout poll: retry retains the maximum native integer interval (layout-retry-native64)",
	_T_LayoutPollNativeRetryCase.Bind(1, 0x7FFFFFFFFFFFFFFE, 1))
