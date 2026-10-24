; tests/unit/adapters/test_screen_brightness_completion_deadline.ahk

; ==============================================================================
; MODULE: Screen Brightness Terminal Deadline Tests
; DESCRIPTION:
; Real completion and poll handlers receive the same elapsed request deadline.
; An existing process port supplies receipts without querying or changing a
; physical display. Delayed callback delivery cannot bypass the poll refusal.
; ==============================================================================

#Requires AutoHotkey v2.0

_SBCD_Terminal(Mode, Fake, Observed, Notices) {
	PreviousCritical := Critical("On")
	try {
		Job := ScreenBrightnessOwner.job
		AssertTrue(Job is Map && Job["handle"] == Fake, "The exact request must still own its process port")
		AssertEqual(1, Fake.starts)
		AssertEqual(0, Observed.Length)
		Timeout := Job["data"]["worker_timeout_ms"]
		AssertEqual(3000, Timeout, "The actual shared worker bound is the deadline under test")
		Expired := Mode != "current"
		Job["started"] := A_TickCount - (Expired ? Timeout + 100 : 0)
		AssertTrue(Job["started"] >= 0, "The fixture needs a nonnegative native monotonic origin")
		Before := A_TickCount
		AssertEqual(Expired, TickExpired64(Job["started"], Timeout, Before),
			"The independently declared deadline input must be established before terminal delivery")
		if Mode == "poll-control"
			ScreenBrightnessPoll()
		Payload := Mode == "expired-unsupported"
			? '{"version":1,"action":"brightness_up","status":"unsupported","displays":[]}'
			: '{"version":1,"action":"brightness_up","status":"applied","displays":[{"before":40,"target":45,"after":45}]}'
		Fake.callback.Call(0, Payload, "")
		_TestPrint("# brightness-terminal mode=" . Mode . " now=" . Before
			. " origin=" . Job["started"] . " timeout=" . Timeout . " callbacks=" . Observed.Length
			. " result=" . (Observed.Length ? Observed[1] : -1) . " notices=" . Notices.Length
			. " retirements=" . Fake.retirements . " current_owner=" . IsObject(ScreenBrightnessOwner.job))
		AssertEqual(1, Observed.Length, "One terminal receipt must deliver exactly one result")
		if Expired
			AssertFalse(Observed[1], "An expired request cannot acknowledge a late applied receipt")
		else
			AssertTrue(Observed[1], "The same genuine handler must accept an on-time target receipt")
		AssertEqual(0, Notices.Length, "An expired unsupported receipt is not a current capability observation")
		AssertFalse(IsObject(ScreenBrightnessOwner.job), "Terminal processing must release the exact request owner")
		AssertEqual(Mode == "poll-control" ? 1 : 0, Fake.retirements,
			"Only the explicit poll cancellation owns a retirement request in these process models")
		Fake.callback.Call(0, Payload, "")
		AssertEqual(1, Observed.Length, "A duplicate terminal delivery cannot publish again")
		AssertEqual(0, Notices.Length)
	} finally Critical(PreviousCritical)
}

for Mode in ["current", "poll-control", "expired-applied", "expired-unsupported"]
	Test("screen brightness: terminal deadline " . Mode . " (brightness-completion-deadline)",
		_SBT_Owned.Bind("brightness_up", _SBCD_Terminal.Bind(Mode)))
