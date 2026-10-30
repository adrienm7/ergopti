; tests/unit/modules/keymap/test_layout_registry_inline_callback.ahk

; ==============================================================================
; MODULE: Layout Registry Inline Subscriber Failures
; DESCRIPTION:
; A declared scheduler may deliver its callback before returning. A completed
; subscriber failure must propagate unchanged, independently of its message or
; type; it cannot be misclassified as a refused poll scheduling operation.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRIC_Case(Mode) {
	global _HTTP_CURL_ABORT_TIMER, _HTTP_CURL_CLEANUP_TIMER
	PreviousCritical := Critical("On")
	SavedAbort := _HTTP_CURL_ABORT_TIMER, SavedCleanup := _HTTP_CURL_CLEANUP_TIMER
	Directory := _LCR_Directory(), State := _ManagedCurlControlState(), Results := []
	ScheduleCalls := 0, ActualThrown := false, ActualFailure := 0
	ExpectedFailure := Mode == "empty" ? Error("") : Mode == "scalar"
		? "Expected scalar registry subscriber failure." : Error("Expected registry subscriber failure.")
	Schedule(Callback, Delay) {
		ScheduleCalls += 1
		; The real facade receives its exact controlled Job's terminal ACK
		; before this declared scheduler delivers the genuine bound poll.
		_LRR_Terminal(State, false)
		Callback.Call()
	}
	Deliver(Status, Etag, Detail, OutputOwner) {
		Results.Push(Status)
		if Mode != "healthy"
			throw ExpectedFailure
	}
	try {
		Transport := Map("managed", true, "request", _LRR_Factory.Bind(State), "schedule", Schedule)
		try LayoutRegistry_Request("https://example.invalid/index.json", Directory . "response.download",
			Map(), 30000, Transport, Deliver)
		catch Any as Failure {
			ActualThrown := true
			ActualFailure := Failure
		}
		AssertEqual(1, State["spawns"], "the public call must dispatch the real request facade")
		AssertEqual(1, ScheduleCalls, "the scheduler must actually deliver its registered bound poll inline")
		AssertTrue(State["request"].Completed, "the facade's exact controlled Job must retire")
		AssertEqual(1, Results.Length, "the real business subscriber must run exactly once")
		AssertFalse(FileExist(State["request"].OutputPath))
		AssertFalse(FileReadActivityBusy(State["request"].OutputPath))
		AssertTrue(LayoutRegistry_PrepareShutdown(), "propagating a subscriber failure cannot strand output custody")
		if Mode == "healthy"
			AssertFalse(ActualThrown, "a healthy inline subscriber must finish normally")
		else {
			AssertTrue(ActualThrown, "a completed inline subscriber failure cannot be swallowed as a scheduler refusal")
			AssertEqual(Type(ExpectedFailure), Type(ActualFailure), "the original thrown type must survive")
			AssertTrue(ActualFailure == ExpectedFailure, "the exact thrown value or error object must propagate")
		}
	} finally {
		try {
			State["retire"] := true
			if State.Has("request")
				AssertTrue(State["request"].Abort())
			AssertTrue(LayoutRegistry_RetireDownloads())
			_ManagedCurlControlRelease(State)
			DirDelete(Directory, true)
		} finally {
			if !IsObject(SavedAbort) && IsObject(_HTTP_CURL_ABORT_TIMER)
				SetTimer(_HTTP_CURL_ABORT_TIMER, 0)
			if !IsObject(SavedCleanup) && IsObject(_HTTP_CURL_CLEANUP_TIMER)
				SetTimer(_HTTP_CURL_CLEANUP_TIMER, 0)
			_HTTP_CURL_ABORT_TIMER := SavedAbort, _HTTP_CURL_CLEANUP_TIMER := SavedCleanup
			Critical(PreviousCritical)
		}
	}
}

for _LRIC_Mode in ["healthy", "message", "empty", "scalar"]
	Test("layout registry custody: inline " . _LRIC_Mode . " callback preserves completion (layout-registry-inline-callback)",
		_LRIC_Case.Bind(_LRIC_Mode))
