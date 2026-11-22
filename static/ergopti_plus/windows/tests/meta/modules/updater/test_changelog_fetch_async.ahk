; tests/meta/modules/updater/test_changelog_fetch_async.ahk

; ==============================================================================
; MODULE: Changelog Async Fetch Meta Test
; DESCRIPTION:
; Regression guard for HIGH-05: _CLW_DoFetch froze the main thread.
;
; _CLW_DoFetch opened the GitHub releases request synchronously
; (Req.Open("GET", Url, false)) and read Req.ResponseText inline. On the AHK
; main thread a synchronous WinHttp Send blocks until the network responds —
; on a slow or captive network this freezes keyboard remapping for seconds.
;
; The fix launches CurlAsyncRequest and harvests the response via a non-blocking
; SetTimer poll calling WaitForResponse(0),
; mirroring _Updater_FetchLatestJsonAsync / _Updater_PollAsync. This test asserts
; the synchronous open is gone and the async poll pattern is present, so a
; regression back to a blocking fetch fails CI.
;
; SCOPE: source introspection of ui/changelog_window.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Guard assertion =======================
; ==================================================
; ==================================================

_CLFA_FetchIsAsync() {
	; Move-resilient: concat the whole window folder, not a pinned single-file path.
	Src := _DriverDirConcat("ui/changelog")
	Body := _DriverFuncBody("_CLW_DoFetch")
	Assert(Body != "", "_CLW_DoFetch(Channel) must exist in ui/changelog/init.ahk")

	Q := Chr(34)
	SyncOpen := "Req.Open(" . Q . "GET" . Q . ", Url, false)"
	Assert(!InStr(Body, SyncOpen),
		"_CLW_DoFetch must NOT open the request synchronously (Url, false) — it blocks the main thread (HIGH-05)")
	Assert(InStr(Body, "CurlAsyncRequest()") > 0 and !InStr(Body, "ComObject("),
		"_CLW_DoFetch must put DNS/connect/Send in the tree-owned curl child")
	; The completion poll lives in the sibling _CLW_PollFetch in the same module;
	; scan the whole source so the async harvesting machinery is detected wherever
	; the refactor placed it.
	Assert(InStr(Src, "WaitForResponse(0)") > 0,
		"changelog_window must harvest the response via the non-blocking WaitForResponse(0) poll (HIGH-05)")
}
Test("meta changelog-fetch-async: _CLW_DoFetch uses child-process HTTP (HIGH-05)", _CLFA_FetchIsAsync)
