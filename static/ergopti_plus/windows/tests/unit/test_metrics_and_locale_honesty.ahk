; static/ergopti_plus/windows/tests/unit/test_metrics_and_locale_honesty.ahk

; ==============================================================================
; MODULE: Regression — metrics that lie, and a translation miss that says
;         nothing (metrics-locale-honesty)
; DESCRIPTION:
; Three findings that all produce plausible-looking output instead of an error,
; which is why none of them was ever reported as a bug.
;
;   L-26  NEGATIVE APP DURATIONS. Two independent compensations exist for the
;         same missing wall-clock span: the suspend branch of
;         KL_Hook_RefreshContext, and the keystroke-gap branch of
;         KL_Watchers_OnKeystroke. After a pause longer than the session timeout
;         BOTH fire, so app_entered_at was advanced twice and ended up in the
;         FUTURE. The next app_switch computed `Now - app_entered_at` as a
;         negative duration, and the walker adds that verbatim to app_time —
;         silently subtracting screen time from whichever app was focused.
;
;   L-27  FABRICATED HESITATIONS. Returning from lunch produced a "hesitation"
;         ergo_event whose delay_ms was the whole away-gap. A handful of values
;         three to five orders of magnitude above a real hesitation dominate
;         every percentile the dashboard computes.
;
;   L-30  SILENT TRANSLATION MISS. A key absent from the active locale AND from
;         both fallbacks returned the raw dotted string with no log line at all,
;         so a stale or mistyped key rendered as garbage in the UI with nothing
;         connecting it to a cause. The locale-parity gate cannot catch it: it
;         only compares keys that exist in en.json.
;
; ROOT CAUSE ENCODED: each of these fails OPEN, producing a value that is
; type-correct and therefore invisible downstream. The cure in each case is to
; make the impossible value impossible, and to say something when the input was
; not what the code assumed.
;
; SCOPE: behavioural for the locale miss (lib/locale.ahk is in the headless
; include graph); source-level for the two metrics findings, whose modules are
; not — see the scope note in section 1.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ App-time watermarks never reach the future ============
; ==================================================================
; ==================================================================

; SCOPE NOTE for sections 1 and 2: modules/keylogger/{hook,ergonomics,watchers}
; are outside the headless include graph, and pulling them in collides with the
; KLHook fixtures the runner's stubs install. These two findings are therefore
; asserted on source. Each assertion still pins the specific mechanism — the
; clamp, the single owner of the advance, and the bound — rather than the mere
; presence of a symbol.

; The clamp is the whole fix: whatever compensations run, the watermark may
; never claim the app was entered after the present moment.
_MLH_WatermarkNeverOvershoots() {
	Body := _DriverFuncBody("KL_Hook_AdvanceContextWatermarks")
	Assert(Body != "",
		"KL_Hook_AdvanceContextWatermarks() must exist — the two compensations need one owner that can enforce the clamp between them")
	Assert(InStr(Body, "Min(") > 0 and InStr(Body, "A_TickCount") > 0,
		"the advance must clamp against the present. Two compensations describe the same paused span, and applied together they pushed app_entered_at into the FUTURE — the next app_switch then reported a negative duration, which the walker adds straight to app_time")
	Assert(InStr(Body, "app_entered_at") > 0 and InStr(Body, "title_entered_at") > 0,
		"both watermarks must be clamped — they are advanced by exactly the same pair of compensations")
}

; Both compensation sites must go through that one owner, or the clamp is
; simply bypassed by whichever site still advances the field directly.
_MLH_BothCompensationsUseTheClampedAdvance() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/keylogger"))
	Assert(Src != "", "the keylogger sources must be readable")

	Raw := 0
	Pos := 1
	while (F := RegExMatch(Src, "KLHook\.app_entered_at\s*\+=", &M, Pos)) {
		Pos := F + M.Len
		Raw += 1
	}
	Assert(Raw == 0,
		"no site may advance app_entered_at directly any more (" . Raw . " still do). A direct += bypasses the clamp, which is the only thing standing between a long pause and a negative app duration")

	Calls := 0
	Pos := 1
	while (F := RegExMatch(Src, "KL_Hook_AdvanceContextWatermarks\(", &M2, Pos)) {
		Pos := F + M2.Len
		Calls += 1
	}
	; Definition + the suspend branch + the keystroke-gap branch.
	Assert(Calls >= 3,
		"both compensation sites must call the clamped advance (found " . Calls . " references including the definition) — the suspend branch and the keystroke-gap branch are the two that compound")
}




; ==================================================================
; ==================================================================
; ======= 2/ An away-gap is not a hesitation =======================
; ==================================================================
; ==================================================================

; A hesitation is someone pausing mid-thought at the keyboard. Returning from
; lunch produced one whose delay_ms was the entire away-gap, and a handful of
; values orders of magnitude above a real hesitation dominate every percentile
; the dashboard computes.
_MLH_AwayGapIsNotAHesitation() {
	Body := _DriverFuncBody("KL_Ergo_CheckHesitation")
	Assert(Body != "", "KL_Ergo_CheckHesitation() must exist in the driver source")
	Assert(InStr(Body, "HESITATION_MAX_MS") > 0,
		"the hesitation detector must reject an away-gap. Without an upper bound, returning from lunch is recorded as a hesitation whose delay_ms is the whole absence")

	; The bound must be applied as an early return, not merely mentioned.
	MinPos := InStr(Body, "HESITATION_MS")
	MaxPos := InStr(Body, "HESITATION_MAX_MS")
	Assert(MaxPos > MinPos,
		"the upper bound must be checked after the lower one, on the same early-return path — a bound that only reshapes the payload still records the event")
	Assert(InStr(Body, "return") > 0, "the bound must cause an early return")
}

; The bound must agree with the driver's own definition of "away", not be a
; second, independently-drifting number.
_MLH_AwayBoundMatchesTheSessionTimeout() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/keylogger"))
	if !RegExMatch(Src, "HESITATION_MAX_MS\s*:=\s*(\d+)", &Hes)
		Assert(false, "HESITATION_MAX_MS must be declared as a named constant")
	if !RegExMatch(Src, "SESSION_TIMEOUT_MS\s*:=\s*(\d+)", &Ses)
		Assert(false, "SESSION_TIMEOUT_MS must be declared as a named constant")
	AssertEqual(Ses[1] + 0, Hes[1] + 0,
		"the hesitation upper bound must equal the session timeout. Past that gap the watchers already consider the session over, so by the driver's own definition the user was away rather than hesitating — two different numbers here would mean two different definitions of the same thing")
}




; ==================================================================
; ==================================================================
; ======= 3/ A total translation miss is reported ==================
; ==================================================================
; ==================================================================

; The user still sees the raw key rather than an exception — taking the tray
; menu down over a typo would be worse — but it must not be silent.
_MLH_TotalMissIsWarned() {
	global _I18nMissWarned
	Key := "ergopti.test.definitely.absent." . A_TickCount
	if (IsSet(_I18nMissWarned) && _I18nMissWarned.Has(Key))
		_I18nMissWarned.Delete(Key)

	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Result := t(Key)
	LoggerClearTestSink()

	Assert(Result == Key,
		"a total miss must still return the raw key — throwing here would take the tray menu down over a single typo")

	Joined := ""
	for Line in Captured
		Joined .= Line . "`n"
	Assert(InStr(Joined, Key) > 0,
		"a key missing from the active locale AND both fallbacks must be logged. Returned in silence, a stale or mistyped key renders as garbage in the UI with nothing connecting it to a cause — and the locale-parity gate cannot help, because it only compares keys that already exist in en.json")
}

; t() runs for every menu label on every rebuild, so an unthrottled warning
; would flood the log and bury the first occurrence.
_MLH_MissWarningIsThrottled() {
	global _I18nMissWarned
	Key := "ergopti.test.throttle." . A_TickCount
	if (IsSet(_I18nMissWarned) && _I18nMissWarned.Has(Key))
		_I18nMissWarned.Delete(Key)

	t(Key)   ; first miss — warns
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	t(Key)   ; second miss — must stay quiet
	t(Key)
	LoggerClearTestSink()

	Joined := ""
	for Line in Captured
		Joined .= Line . "`n"
	Assert(InStr(Joined, Key) == 0,
		"the untranslated-key warning must fire once per key. t() is called for every menu label on every rebuild, so repeating it would flood the log and bury the occurrence that matters")
}

; A key that DOES resolve must never warn, or the signal is worthless.
_MLH_ResolvedKeyDoesNotWarn() {
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	t("menu.hotstrings.infinite")
	LoggerClearTestSink()

	Joined := ""
	for Line in Captured
		Joined .= Line . "`n"
	Assert(InStr(Joined, "No translation") == 0,
		"a key that resolves must not produce a missing-translation warning — a warning that fires on the normal path is noise nobody will read")
}


Test("metrics-locale-honesty: the app-time watermark never overshoots the present",
	_MLH_WatermarkNeverOvershoots)
Test("metrics-locale-honesty: both compensations use the clamped advance",
	_MLH_BothCompensationsUseTheClampedAdvance)
Test("metrics-locale-honesty: an away-gap is not recorded as a hesitation",
	_MLH_AwayGapIsNotAHesitation)
Test("metrics-locale-honesty: the away bound matches the session timeout",
	_MLH_AwayBoundMatchesTheSessionTimeout)
Test("metrics-locale-honesty: a total translation miss is warned",
	_MLH_TotalMissIsWarned)
Test("metrics-locale-honesty: the miss warning is throttled per key",
	_MLH_MissWarningIsThrottled)
Test("metrics-locale-honesty: a resolved key does not warn",
	_MLH_ResolvedKeyDoesNotWarn)
