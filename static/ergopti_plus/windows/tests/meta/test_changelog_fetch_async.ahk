; tests/meta/test_changelog_fetch_async.ahk

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
; The fix opens the request asynchronously (Req.Open(..., true)) and harvests
; the response via a non-blocking SetTimer poll calling WaitForResponse(0),
; mirroring _Updater_FetchLatestJsonAsync / _Updater_PollAsync. This test asserts
; the synchronous open is gone and the async poll pattern is present, so a
; regression back to a blocking fetch fails CI.
;
; SCOPE: source introspection of lib/changelog_window.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_CLFA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Extracts the body of a named function via balanced brace-walking.
_CLFA_FuncBody(Src, FuncName) {
	Idx := InStr(Src, FuncName)
	if (!Idx)
		return ""
	OpenPos := InStr(Src, "{", , Idx)
	if (!OpenPos)
		return ""
	depth := 0
	i := OpenPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, Idx, i - Idx + 1)
		}
		i++
	}
	return SubStr(Src, Idx)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_CLFA_FetchIsAsync() {
	Src := _CLFA_ReadSource("lib/changelog_window.ahk")
	Body := _CLFA_FuncBody(Src, "_CLW_DoFetch(Channel) {")
	Assert(Body != "", "_CLW_DoFetch(Channel) must exist in lib/changelog_window.ahk")

	Q := Chr(34)
	SyncOpen := "Req.Open(" . Q . "GET" . Q . ", Url, false)"
	Assert(!InStr(Body, SyncOpen),
		"_CLW_DoFetch must NOT open the request synchronously (Url, false) — it blocks the main thread (HIGH-05)")
	; The completion poll lives in the sibling _CLW_PollFetch in the same module;
	; scan the whole source so the async harvesting machinery is detected wherever
	; the refactor placed it.
	Assert(InStr(Src, "WaitForResponse(0)") > 0,
		"changelog_window must harvest the response via the non-blocking WaitForResponse(0) poll (HIGH-05)")
}
Test("meta changelog-fetch-async: _CLW_DoFetch uses async WinHttp poll, not sync open (HIGH-05)", _CLFA_FetchIsAsync)
