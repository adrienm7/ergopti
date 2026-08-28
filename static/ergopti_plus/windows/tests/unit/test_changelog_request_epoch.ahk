; tests/unit/test_changelog_request_epoch.ahk

; ==============================================================================
; MODULE: Changelog Request Epoch Regression Tests
; DESCRIPTION:
; Exercises the real changelog completion and deferred-script boundaries with
; deterministic WinHTTP/WebView fakes.  Each fetch owns an immutable window +
; request epoch so an older channel, a closed window, or an already-queued
; ExecuteScript callback can never repaint the current WebView (AHK-30).
; ==============================================================================

#Requires AutoHotkey v2.0

class _CRE_Request {
	__New(Status, Json := "[]", Ready := true, ThrowOnWait := false) {
		this.Status := Status
		this.ResponseText := Json
		this.Ready := Ready
		this.ThrowOnWait := ThrowOnWait
		this.AbortCount := 0
	}

	WaitForResponse(*) {
		if this.ThrowOnWait
			throw Error("synthetic WaitForResponse failure")
		return this.Ready
	}

	Abort() {
		this.AbortCount += 1
	}
}

class _CRE_WebView {
	__New() {
		this.Scripts := []
	}

	ExecuteScriptAsync(Js) {
		this.Scripts.Push(Js)
	}
}

_CRE_InstallFixture() {
	global _CLW_WindowEpoch, _CLW_RequestEpoch
	global _CLW_ActiveRequest, _CLW_ActiveRequestEpoch
	global _CLW_Ready, _CLW_Queue, _CLW_WebView

	Previous := Map(
		"window_epoch", _CLW_WindowEpoch,
		"request_epoch", _CLW_RequestEpoch,
		"active_request", _CLW_ActiveRequest,
		"active_epoch", _CLW_ActiveRequestEpoch,
		"ready", _CLW_Ready,
		"queue", _CLW_Queue,
		"webview_set", IsSet(_CLW_WebView),
		"webview", IsSet(_CLW_WebView) ? _CLW_WebView : 0
	)

	_CLW_WindowEpoch := 100
	_CLW_RequestEpoch := 200
	_CLW_ActiveRequest := 0
	_CLW_ActiveRequestEpoch := 0
	_CLW_Ready := false
	_CLW_Queue := []
	_CLW_WebView := unset
	return Previous
}

_CRE_RestoreFixture(Previous) {
	global _CLW_WindowEpoch, _CLW_RequestEpoch
	global _CLW_ActiveRequest, _CLW_ActiveRequestEpoch
	global _CLW_Ready, _CLW_Queue, _CLW_WebView

	_CLW_WindowEpoch := Previous["window_epoch"]
	_CLW_RequestEpoch := Previous["request_epoch"]
	_CLW_ActiveRequest := Previous["active_request"]
	_CLW_ActiveRequestEpoch := Previous["active_epoch"]
	_CLW_Ready := Previous["ready"]
	_CLW_Queue := Previous["queue"]
	if Previous["webview_set"]
		_CLW_WebView := Previous["webview"]
	else
		_CLW_WebView := unset
}

_CRE_StableCompletionCannotRepaintDev() {
	global _CLW_Queue, _CLW_Ready, _CLW_WebView

	Previous := _CRE_InstallFixture()
	try {
		_CLW_BeginWindowSession()
		Stable := _CLW_BeginFetchRequest("main")
		StableReq := _CRE_Request(200, '[{"tag_name":"stable-old"}]')
		AssertTrue(_CLW_RegisterActiveRequest(Stable, StableReq),
			"the old Stable request must own the active slot before Dev supersedes it")

		Dev := _CLW_BeginFetchRequest("dev")
		AssertEqual(1, StableReq.AbortCount,
			"starting Dev must actively abort the superseded Stable WinHTTP request")
		DevReq := _CRE_Request(200, '[{"tag_name":"dev-current"}]')
		AssertTrue(_CLW_RegisterActiveRequest(Dev, DevReq),
			"the current Dev request must replace Stable in the active slot")

		_CLW_PollFetch(DevReq, Dev, 0)
		_CLW_PollFetch(StableReq, Stable, 0)
		AssertEqual(1, _CLW_Queue.Length,
			"Dev then older Stable completion must enqueue exactly one page mutation (AHK-30)")
		AssertContains(_CLW_Queue[1].Js, "dev-current",
			"the sole queued payload must be the newer Dev response")
		AssertContains(_CLW_Queue[1].Js, '"dev"',
			"the sole queued payload must preserve the immutable Dev channel")
		AssertFalse(InStr(_CLW_Queue[1].Js, "stable-old") > 0,
			"the superseded Stable response must never reach the WebView queue")

		; Prove the current completion paints exactly once through the real final
		; ExecuteScript boundary, without letting a SetTimer race the test.
		Work := _CLW_Queue[1]
		WebView := _CRE_WebView()
		_CLW_WebView := WebView
		_CLW_Ready := true
		_CLW_RunScript(Work)
		AssertEqual(1, WebView.Scripts.Length,
			"the current Dev completion must paint exactly once")
		AssertContains(WebView.Scripts[1], "dev-current",
			"the visible paint must contain the current Dev result")
	} finally {
		_CRE_RestoreFixture(Previous)
	}
}

Test("changelog: older Stable completion cannot repaint newer Dev (AHK-30)",
	_CRE_StableCompletionCannotRepaintDev)

_CRE_StaleErrorCannotOverwriteNewerSuccess() {
	global _CLW_Queue

	Previous := _CRE_InstallFixture()
	try {
		_CLW_BeginWindowSession()
		Stable := _CLW_BeginFetchRequest("main")
		StableReq := _CRE_Request(503, "")
		AssertTrue(_CLW_RegisterActiveRequest(Stable, StableReq),
			"the stale failure must begin as the active request")

		Dev := _CLW_BeginFetchRequest("dev")
		DevReq := _CRE_Request(200, '[{"tag_name":"dev-success"}]')
		AssertTrue(_CLW_RegisterActiveRequest(Dev, DevReq),
			"the newer success must own the active request slot")
		_CLW_PollFetch(DevReq, Dev, 0)
		_CLW_PollFetch(StableReq, Stable, 0)

		AssertEqual(1, _CLW_Queue.Length,
			"a stale HTTP error must not add an error paint after newer success")
		AssertContains(_CLW_Queue[1].Js, "injectReleases(",
			"the current success must remain the only terminal page mutation")
		AssertFalse(InStr(_CLW_Queue[1].Js, "injectError(") > 0,
			"the stale error must not overwrite a newer successful response")
	} finally {
		_CRE_RestoreFixture(Previous)
	}
}

Test("changelog: stale error cannot overwrite newer success (AHK-30)",
	_CRE_StaleErrorCannotOverwriteNewerSuccess)

_CRE_CurrentPollFailureAbortsAndReportsOnce() {
	global _CLW_Queue, _CLW_ActiveRequest, _CLW_ActiveRequestEpoch

	Previous := _CRE_InstallFixture()
	try {
		_CLW_BeginWindowSession()
		Context := _CLW_BeginFetchRequest("dev")
		Request := _CRE_Request(0, "", false, true)
		AssertTrue(_CLW_RegisterActiveRequest(Context, Request),
			"the failing current request must own the active slot")

		_CLW_PollFetch(Request, Context, 0)
		AssertEqual(1, Request.AbortCount,
			"a WinHTTP poll exception must explicitly abort the owned request")
		AssertEqual(0, _CLW_ActiveRequest,
			"the terminal failure must release the active request object")
		AssertEqual(0, _CLW_ActiveRequestEpoch,
			"the terminal failure must release the active request epoch")
		AssertEqual(1, _CLW_Queue.Length,
			"the current failure must report exactly one visible terminal result")
		AssertContains(_CLW_Queue[1].Js, "injectError(",
			"the current failure must still reach the page after ownership cleanup")
	} finally {
		_CRE_RestoreFixture(Previous)
	}
}

Test("changelog: current poll failure aborts and reports once (AHK-30)",
	_CRE_CurrentPollFailureAbortsAndReportsOnce)

_CRE_CloseReopenInvalidatesOldRequest() {
	global _CLW_Queue

	Previous := _CRE_InstallFixture()
	try {
		OldWindow := _CLW_BeginWindowSession()
		OldRequest := _CLW_BeginFetchRequest("dev")
		OldHttp := _CRE_Request(200, '[{"tag_name":"old-window"}]')
		AssertTrue(_CLW_RegisterActiveRequest(OldRequest, OldHttp),
			"the old window must own its live request")

		_CLW_InvalidateWindowSession()
		AssertEqual(1, OldHttp.AbortCount,
			"closing the window must abort its live WinHTTP request")
		NewWindow := _CLW_BeginWindowSession()
		Assert(NewWindow > OldWindow,
			"reopening must allocate a distinct window epoch")

		_CLW_PollFetch(OldHttp, OldRequest, 0)
		AssertEqual(0, _CLW_Queue.Length,
			"an old-window completion must not target the reopened global WebView")
	} finally {
		_CRE_RestoreFixture(Previous)
	}
}

Test("changelog: close and reopen invalidates old window requests (AHK-30)",
	_CRE_CloseReopenInvalidatesOldRequest)

_CRE_DeferredScriptKeepsItsRequestEpoch() {
	global _CLW_Queue, _CLW_Ready, _CLW_WebView

	Previous := _CRE_InstallFixture()
	try {
		_CLW_BeginWindowSession()
		Stable := _CLW_BeginFetchRequest("main")
		AssertTrue(_CLW_Eval('injectReleases([],"main")', Stable),
			"a current completion must be accepted into the deferred script queue")
		StableWork := _CLW_Queue[1]

		Dev := _CLW_BeginFetchRequest("dev")
		WebView := _CRE_WebView()
		_CLW_WebView := WebView
		_CLW_Ready := true
		_CLW_RunScript(StableWork)
		AssertEqual(0, WebView.Scripts.Length,
			"a response superseded after completion but before SetTimer execution must not repaint")

		CurrentWork := {
			Js: 'injectReleases([],"dev")',
			WindowEpoch: Dev.WindowEpoch,
			RequestEpoch: Dev.RequestEpoch
		}
		_CLW_RunScript(CurrentWork)
		AssertEqual(1, WebView.Scripts.Length,
			"the current request's deferred script must still execute exactly once")
	} finally {
		_CRE_RestoreFixture(Previous)
	}
}

Test("changelog: deferred script cannot cross a request epoch (AHK-30)",
	_CRE_DeferredScriptKeepsItsRequestEpoch)

_CRE_ProductionBoundariesCarryEpoch() {
	FetchBody := _DriverFuncBody("_CLW_FetchAndInject")
	PollBody := _DriverFuncBody("_CLW_PollFetch")
	EvalBody := _DriverFuncBody("_CLW_Eval")
	RunBody := _DriverFuncBody("_CLW_RunScript")
	ResetBody := _DriverFuncBody("_CLW_Reset")

	AssertContains(FetchBody, "_CLW_BeginFetchRequest(Channel, Request, ExpectedWindowEpoch)",
		"every public channel fetch must thread its immutable request provenance into the epoch context")
	AssertContains(FetchBody, "_CLW_DoFetch.Bind(Context)",
		"the deferred network start must carry the exact request context")
	AssertContains(PollBody, "_CLW_RequestIsCurrent(Context)",
		"the async completion poll must reject stale provenance")
	AssertContains(EvalBody, "RequestEpoch", 
		"accepted page mutations must retain their request epoch through deferral")
	AssertContains(RunBody, "_CLW_ScriptWorkEpochIsCurrent(Work)",
		"ExecuteScript must atomically revalidate its epoch after the SetTimer yield")
	AssertContains(ResetBody, "_CLW_InvalidateWindowSession()",
		"window teardown must invalidate every old request and queued script")
}

Test("changelog: all async boundaries carry request/window epochs (AHK-30)",
	_CRE_ProductionBoundariesCarryEpoch)

_CRE_StaleSafetyFlushCannotAdoptReopenedWindow() {
	global _CLW_WindowEpoch, _CLW_Ready, _CLW_Queue

	Previous := _CRE_InstallFixture()
	try {
		OldWindowEpoch := _CLW_WindowEpoch
		_CLW_WindowEpoch += 1
		_CLW_Ready := false
		_CLW_Queue := [{Js: "old-bootstrap", WindowEpoch: OldWindowEpoch,
			RequestEpoch: 0, Request: 0}]

		AssertFalse(_CLW_SafetyFlush(OldWindowEpoch),
			"a safety timer owned by the closed window must be rejected")
		AssertFalse(_CLW_Ready,
			"the stale timer must not mark the reopened page ready")
		AssertEqual(1, _CLW_Queue.Length,
			"the stale timer must not drain the reopened window's queue")

		BuildBody := _DriverFuncBody("_CLW_BuildWindow")
		AssertContains(BuildBody, "_CLW_SafetyFlush.Bind(WindowEpoch)",
			"the one-shot timer must capture the window epoch that created it")
	} finally {
		_CRE_RestoreFixture(Previous)
	}
}

Test("changelog: stale safety timer cannot adopt a reopened window (AHK-064)",
	_CRE_StaleSafetyFlushCannotAdoptReopenedWindow)
