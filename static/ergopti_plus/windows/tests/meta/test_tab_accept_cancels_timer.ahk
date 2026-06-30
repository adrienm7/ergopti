; tests/meta/test_tab_accept_cancels_timer.ahk

; ==============================================================================
; MODULE: LLM Bridge Tab-Accept Timer Cancellation Meta Test
; DESCRIPTION:
; Static source guard for T-W08: the Tab acceptance path in
; LLM_Bridge_FeedKeyDownIfActive must cancel the debounce timer immediately
; after the suggestion is accepted, so a stale prediction cannot re-flash the
; tooltip after the user has already dismissed it via Tab.
;
; THE INVARIANT:
; When LLM_Tooltip_TryAcceptTab() returns true, the function must call
; LLM_Engine_CancelTimer() before returning — if the call is absent or comes
; before TryAcceptTab the bug silently reintroduces itself: the timer fires a
; few milliseconds after acceptance and shows the tooltip over the freshly
; injected text.
;
; Meta-static because LLM_Bridge_FeedKeyDownIfActive lives in
; modules/keymap/llm_bridge.ahk, which pulls in the full LLM stack (engine,
; tooltip, pointer watcher, HookDispatcher, etc.). Loading it headless would
; require dozens of stubs and is unsafe; a byte-offset scan is the correct
; tool here, following the same pattern as test_onkeydown_dead_llm_branch.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a file by path relative to the windows/ driver root.
; A_ScriptDir is the tests/ directory; its parent is windows/.
_TACT_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ====================================================
; ====================================================
; ======= 2/ Timer-cancellation assertions ===========
; ====================================================
; ====================================================

_TACT_CancelTimerCalledAfterTryAcceptTab() {
	Src := _TACT_ReadSource("modules/keymap/llm_bridge.ahk")
	Body := _DriverFuncBody("LLM_Bridge_FeedKeyDownIfActive")
	Assert(Body != "",
		"LLM_Bridge_FeedKeyDownIfActive must exist in modules/keymap/llm_bridge.ahk")

	; Locate the TryAcceptTab call inside the function body first.
	AcceptPos := InStr(Body, "LLM_Tooltip_TryAcceptTab")
	Assert(AcceptPos > 0,
		"LLM_Bridge_FeedKeyDownIfActive must call LLM_Tooltip_TryAcceptTab "
		. "so Tab over a shown prediction triggers suggestion acceptance")

	; LLM_Engine_CancelTimer must also be present in the function body.
	CancelPos := InStr(Body, "LLM_Engine_CancelTimer")
	Assert(CancelPos > 0,
		"LLM_Bridge_FeedKeyDownIfActive must call LLM_Engine_CancelTimer "
		. "so the debounce timer cannot re-flash the tooltip after acceptance")

	; The cancel must come AFTER the TryAcceptTab call — a cancel placed before
	; the accept guard would not protect against the stale-timer race.
	Assert(CancelPos > AcceptPos,
		"LLM_Engine_CancelTimer (offset " . CancelPos . ") must appear after "
		. "LLM_Tooltip_TryAcceptTab (offset " . AcceptPos . ") in "
		. "LLM_Bridge_FeedKeyDownIfActive — the timer must be cancelled as a "
		. "consequence of a successful accept, not unconditionally before it")
}
Test("llm_bridge: Tab acceptance path calls LLM_Engine_CancelTimer after TryAcceptTab",
	_TACT_CancelTimerCalledAfterTryAcceptTab)
