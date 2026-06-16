; tests/meta/test_layout_quiescence.ahk

; ==============================================================================
; MODULE: Layout Reload Quiescence Test
; DESCRIPTION:
; Regression test for the layout-poll-blind-reload finding. The 1 s layout-poll
; timer used to call Reload() the instant the foreground HKL differed, which
; dropped in-flight typing on any transient HKL flicker. The decision now lives
; in the pure helper _ShouldReloadForHkl (lib/layout_poll_helper.ahk), which only
; returns true when the new layout has been stable across two consecutive polls,
; the user is physically idle, no expansion is in flight, and the driver is
; neither suspended nor on a blacklisted app.
;
; This test drives that helper directly (no OS, no Reload) and asserts every gate
; so a regression to the old blind-reload behaviour fails loudly. _ShouldReloadForHkl
; is supplied by run_all.ahk including lib/layout_poll_helper.ahk; Assert/AssertEqual
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

	; Second poll, stable changed HKL, idle, nothing suppressed -> reload now.
	res := _ShouldReloadForHkl(200, &last, &pending, false, false, 0, 0, 1000)
	AssertEqual(res, true, "Stable changed HKL with full quiescence must reload")
	AssertEqual(last, 200, "Last HKL must advance once the reload is authorised")
}

Test("ErgoptiPlus: _ShouldReloadForHkl enforces quiescence and debounce (layout-poll-blind-reload)", _T_LayoutPollReloadQuiescence)
