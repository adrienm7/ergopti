; tests/meta/test_llm_inflight_hygiene.ahk

; ==============================================================================
; MODULE: Regression — in-flight LLM requests must abandon, defer and re-check
;         (llm-inflight-hygiene)
; DESCRIPTION:
; Five findings, one theme: what an LLM request does while it is still in
; flight, and what it is allowed to do once it no longer speaks for the user.
;
; ROOT CAUSE ENCODED:
;   * Two poll ticks never received the COM-exception abandonment fix their
;     siblings did. A dropped connection (WiFi cut, Ollama restarted) raised
;     from WaitForResponse, the bare `try` swallowed it, and the tick re-armed —
;     so a dead request polled every 50 ms to its deadline against a socket that
;     was never going to answer, with nothing in the log to say why.
;   * Both SINGULAR cancels killed the transport inline. They are reached from
;     the per-keystroke Critical, where a blocking TerminateProcess or a WinHTTP
;     Abort (a cross-apartment COM call) starves the keyboard hook while the
;     message pump is suspended. Both plural siblings already deferred.
;   * The engine's staleness check ran only at callback ENTRY. Finalization logs,
;     hides tooltips and writes to the keylogger before it renders, and any of
;     those can yield long enough for a keystroke to supersede the request — so
;     the render painted a prediction for text the user had already left, and
;     re-seeded the cache with that stale context for the NEXT request too.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ Every poll abandons on a COM exception ================
; ==================================================================
; ==================================================================

; Counts the real WaitForResponse CALL sites (an assignment from a COM handle) in
; the LLM backends. Derived rather than hardcoded: the guarantee is "every site
; abandons", not "there are N sites", so adding or retiring a poll must not need a
; number edited here. Docstring mentions of ``WaitForResponse(0)`` carry no ":=",
; so prose can never inflate the count.
_LIH_WaitForResponseSiteCount(Src) {
	Sites := 0
	Pos := 1
	while (F := RegExMatch(Src, "i):=\s*\w+\.WaitForResponse\(", &M, Pos)) {
		Pos := F + M.Len
		Sites += 1
	}
	return Sites
}

; Every WaitForResponse call in the async backends must sit in a try/catch that
; ABANDONS. A bare `try` re-queues the tick, which is the busy-loop.
_LIH_EveryWaitForResponseAbandons() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm"))

	Bare := 0
	Pos := 1
	while (F := RegExMatch(Src, "try\s+\w+\s*:=\s*\w+\.WaitForResponse\(", &M, Pos)) {
		Pos := F + M.Len
		Bare += 1
	}
	Assert(Bare == 0,
		"a WaitForResponse still runs under a bare `try` (found " . Bare . "). The exception means the connection dropped; swallowing it re-arms the tick, so a dead request polls every 50 ms to its deadline against a socket that will never answer")

	Guarded := 0
	Pos := 1
	while (F := RegExMatch(Src, "catch\s+as\s+com_err", &M2, Pos)) {
		Pos := F + M2.Len
		Guarded += 1
	}
	; The old form of this assertion was ``Guarded >= 4``, which pinned the SIZE of
	; the class instead of the invariant over it — retiring the dead Ollama WinHTTP
	; generation poll (which never ran, and whose entries never held an "http" key)
	; would have "failed" the suite for removing dead code. The guarantee is one
	; abandonment guard per live call site, so both numbers are now derived and
	; compared. The floor keeps the scan from passing vacuously if the regex ever
	; stops matching.
	Sites := _LIH_WaitForResponseSiteCount(Src)
	Assert(Sites >= 3,
		"the scan must still find the WaitForResponse call sites (found " . Sites . ") — a regex that matches nothing would make this whole test vacuous")
	Assert(Guarded == Sites,
		"every WaitForResponse call site must carry the abandonment contract (" . Sites . " site(s), " . Guarded . " guard(s)) — a guard that only forbids the old spelling is satisfied by deleting the call instead of handling it")
}

; Abandoning must also RELEASE the transport, or the socket and COM object stay
; resident until WinHTTP's own timeout fires, long after we stopped polling.
_LIH_AbandonmentReleasesTheTransport() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm"))
	Pos := 1
	Checked := 0
	while (F := RegExMatch(Src, "catch\s+as\s+com_err", &M, Pos)) {
		Pos := F + M.Len
		Window := SubStr(Src, F, 600)
		Checked += 1
		Assert(InStr(Window, ".Abort()") > 0 or InStr(Window, "_LLM_Ollama_Async.Delete") > 0,
			"an abandoning poll must release the in-flight request, not merely stop looking at it")
	}
	; Same reasoning as above: the count is derived from the live call sites rather
	; than frozen at 4, so the invariant survives a poll being added or retired.
	Sites := _LIH_WaitForResponseSiteCount(Src)
	Assert(Sites >= 3,
		"the scan must still find the WaitForResponse call sites (found " . Sites . ")")
	Assert(Checked == Sites,
		"the scan must reach every abandonment site (" . Sites . " site(s), " . Checked . " reached)")
}




; ==================================================================
; ==================================================================
; ======= 2/ Cancels never kill under the caller's Critical ========
; ==================================================================
; ==================================================================

; The singular cancels must defer their kills exactly as the plural ones do.
; The set is DERIVED from the source rather than listed here: the previous
; hardcoded pair pinned which cancels exist, so retiring one (the Ollama singular
; had no production caller — the engine only ever cancels all) read as a test
; failure, and a newly added sibling would silently never be checked. What the
; test promises is "every singular cancel defers", so the class is enumerated.
_LIH_SingularCancelsDeferTheirKills() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm"))

	Fns := []
	Pos := 1
	while (F := RegExMatch(Src, "m)^[ \t]*(\w+CancelAsync)\(req_id\)\s*\{", &MD, Pos)) {
		Pos := F + MD.Len
		Fns.Push(MD[1])
	}
	Assert(Fns.Length >= 1,
		"at least one singular per-request cancel must exist for this invariant to mean anything (found " . Fns.Length . ")")

	for _, Fn in Fns {
		At := InStr(Src, Fn . "(req_id) {")
		Assert(At > 0, "the singular cancel " . Fn . " must exist")
		Body := SubStr(Src, At, 900)

		Assert(InStr(Body, "LLM_DeferCancelKills") > 0,
			Fn . " must defer its kill. It is reached from the per-keystroke Critical, where a blocking TerminateProcess or a WinHTTP Abort starves the keyboard hook while the message pump is suspended — the exact reason the plural sibling already defers")
		Assert(InStr(Body, 'entry["cancelled"] := true') > 0,
			Fn . " must still flip the cancelled flag INLINE — the poll ticks read it, and deferring that too would let one more tick act on a cancelled request")
	}
}

; The deferred path must be the one that actually performs the kill, otherwise
; "deferring" would just be dropping the cancellation.
_LIH_DeferredKillsAreExecuted() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm"))
	At := InStr(Src, "_LLM_RunCancelKills(Kills) {")
	Assert(At > 0, "the deferred kill runner must exist")
	Body := SubStr(Src, At, 500)
	Assert(InStr(Body, "ProcessClose") > 0,
		"the runner must close curl children")
	Assert(InStr(Body, ".Abort()") > 0,
		"and abort WinHTTP requests — the remote backend defers both kinds")
}




; ==================================================================
; ==================================================================
; ======= 3/ A superseded prediction is never rendered =============
; ==================================================================
; ==================================================================

; The staleness test must have ONE owner and be applied again immediately before
; the render, not only at callback entry.
_LIH_StalenessIsRecheckedBeforeRender() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm"))

	Assert(InStr(Src, "_LLM_Engine_IsCurrent(state) {") > 0,
		"the staleness test must have a single owner — it was four copies of the same expression, which is how one of them came to be missing where it mattered")

	At := InStr(Src, '_LLM_Engine["last_ctx"]     := state["ctx"]')
	Assert(At > 0, "the cache seed must still exist")

	Before := SubStr(Src, Max(1, At - 700), 700)
	Assert(InStr(Before, "_LLM_Engine_IsCurrent(state)") > 0,
		"the request must be re-checked immediately before the render and cache seed. Everything between the entry check and this point — the summary log, the tooltip hide, the keylogger write — can yield, and a keystroke arriving in that window supersedes the request. Rendering anyway paints text the user has already left, and seeding last_ctx hands that stale context to the NEXT request as well")
}

; The entry checks must go through the same owner, or the duplication is back.
_LIH_EveryStalenessCheckUsesTheOwner() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm"))

	Inline := 0
	Pos := 1
	while (F := RegExMatch(Src, "current_id\s*:=\s*_LLM_Engine\.Has\(", &M, Pos)) {
		Pos := F + M.Len
		Inline += 1
	}
	Assert(Inline <= 1,
		"the request-id comparison must live in one place (found " . Inline . " inline copies). Four copies is what let the render path keep an entry-only check while its siblings were tightened")

	Uses := 0
	Pos := 1
	while (F := RegExMatch(Src, "_LLM_Engine_IsCurrent\(", &M2, Pos)) {
		Pos := F + M2.Len
		Uses += 1
	}
	Assert(Uses >= 6,
		"and every caller must route through it (found " . Uses . ")")
}


Test("meta llm-inflight-hygiene: every WaitForResponse abandons on a COM exception",
	_LIH_EveryWaitForResponseAbandons)
Test("meta llm-inflight-hygiene: abandonment releases the transport",
	_LIH_AbandonmentReleasesTheTransport)
Test("meta llm-inflight-hygiene: singular cancels defer their kills",
	_LIH_SingularCancelsDeferTheirKills)
Test("meta llm-inflight-hygiene: deferred kills are actually executed",
	_LIH_DeferredKillsAreExecuted)
Test("meta llm-inflight-hygiene: staleness is re-checked before the render",
	_LIH_StalenessIsRecheckedBeforeRender)
Test("meta llm-inflight-hygiene: every staleness check uses the single owner",
	_LIH_EveryStalenessCheckUsesTheOwner)
