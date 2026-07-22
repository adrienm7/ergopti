; tests/meta/test_changelog_fetch_status_logged.ahk

; ==============================================================================
; MODULE: Changelog Fetch Status Logging Meta Test
; DESCRIPTION:
; _CLW_PollFetch tested Req.Status == 200 but never captured it, so every
; non-200 response left through the empty-Json branch in complete silence. The
; request had SUCCEEDED, so none of the surrounding catches fired; the only
; trace was a lifecycle line opened for a fetch that then reported nothing.
;
; The user was shown "check your internet connection" for what is most often a
; GitHub 403 rate-limit — an error message that sends them after the wrong
; problem entirely, on a machine whose connection is fine.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE: the empty-Json exit must never be reachable without
;    a log line, and that line must carry the status. Asserting merely that a
;    LoggerWarn exists somewhere in the function would pass on the old code,
;    which already had three unrelated warnings.
; 2. Pins the rate-limit distinction, since conflating it with an outage is the
;    user-visible half of the defect.
;
; SCOPE: source introspection of ui/changelog via the move-resilient helper.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ The silent exit is now instrumented ===
; ==================================================
; ==================================================

_CFSL_EmptyResponseIsLogged() {
	Body := _DriverFuncBody("_CLW_PollFetch")
	Assert(Body != "", "_CLW_PollFetch() must exist in ui/changelog/init.ahk")

	; The status must be captured, not merely compared. `if (Req.Status == 200)`
	; reads it and throws it away, which is exactly how the value went missing
	; from every diagnostic.
	Assert(RegExMatch(Body, "Status\s*:=\s*Req\.Status") > 0,
		"_CLW_PollFetch must capture Req.Status into a local — testing it inline discards the one value that explains a failed fetch")

	GuardPos := InStr(Body, 'if (Json == "")')
	Assert(GuardPos > 0, "the empty-response branch must still exist")

	; Scope strictly to the branch BODY. Two traps here, both hit while writing
	; this test: a fixed-size window runs past the closing brace and picks up
	; unrelated Logger calls further down the function (which makes the assertion
	; pass against the very code it is meant to reject), and searching for
	; "return" as the end anchor matches the word "returned" inside the log
	; message itself. _CLW_Eval is the stable last statement of the branch.
	EndPos := InStr(Body, "_CLW_Eval(", , GuardPos)
	Assert(EndPos > GuardPos, "the empty-response branch must still inject an error into the page")
	Branch := SubStr(Body, GuardPos, EndPos - GuardPos)
	Assert(InStr(Branch, "Logger") > 0,
		"the empty-response branch must log before returning — a successful request with a non-200 status fires none of the surrounding catches, so this is the only place the failure can be recorded")
	Assert(InStr(Branch, "Status") > 0,
		"the log line must include the HTTP status, or it cannot distinguish a rate-limit from an outage")
}

; A 403/429 is not a network failure, and telling the user to check their
; connection is actively misleading.
_CFSL_RateLimitIsDistinguished() {
	Body := _DriverFuncBody("_CLW_PollFetch")
	Assert(Body != "", "_CLW_PollFetch() must exist")

	Assert(InStr(Body, "403") > 0,
		"_CLW_PollFetch must recognise HTTP 403 — GitHub's unauthenticated rate limit is the most common non-200 here")
	Assert(InStr(Body, "changelog_window.error_rate_limited") > 0,
		"a rate-limited fetch must use its own user-facing message rather than the network-error string")

	NetPos := InStr(Body, "changelog_window.error_network")
	Assert(NetPos > 0,
		"the genuine network-error message must survive for the non-rate-limited case")
}


Test("meta changelog: a non-200 response is logged with its status, not swallowed",
	_CFSL_EmptyResponseIsLogged)
Test("meta changelog: a rate-limit is reported as such, not as a network outage",
	_CFSL_RateLimitIsDistinguished)
