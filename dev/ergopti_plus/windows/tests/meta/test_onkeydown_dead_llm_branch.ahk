; tests/meta/test_onkeydown_dead_llm_branch.ahk

; ==============================================================================
; MODULE: PrefixWatcher OnKeyDown Dead-LLM-Branch Meta Test
; DESCRIPTION:
; Static source guard for finding `onkeydown-dead-llm-branch`.
;
; _OnPrefixKeyDown used an if/else-if chain whose final clause tested
; (VK == 0x09 or VK == 0x0D or VK == 0x1B)  -  a strict subset of the two
; clauses above it. AHK evaluates clauses top-to-bottom, so Tab/Enter matched
; the first clause and Escape matched the second; the trailing clause was
; structurally unreachable, and the Enter (0x0D) LLM flush it was supposed to
; run never executed on this hook path.
;
; The fix folds LLM_Bridge_FeedKeyDownIfActive into the live Tab/Enter clause
; (after the Tab-accept early return) and deletes the dead trailing else-if.
; This test asserts (a) the Tab/Enter branch now feeds the bridge and (b) the
; dead trailing clause is gone, so a regression that reintroduces the dead
; branch or drops the live feed fails here.
;
; Meta-static because _OnPrefixKeyDown depends on LLM_Bridge_FeedKeyDownIfActive
; (defined in modules/keymap/llm_bridge.ahk, NOT in the run_all include graph) and
; on tooltip / HSE side effects; calling it headless is unsafe. The assertions
; read the function body via the move-resilient _DriverFuncBody helper, so they
; survive a move of hotstring_prefix_watcher.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

_OKDLB_TabEnterBranchFeedsBridge() {
	Seg := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(Seg != "", "_OnPrefixKeyDown must exist in hotstring_prefix_watcher.ahk")
	; The Tab/Enter clause must now route the VK through the bridge feed so the
	; Enter flush (and the non-accepted Tab flush) actually fire on this hook.
	Idx := InStr(Seg, "else if (VK == 0x09 or VK == 0x0D)")
	Assert(Idx > 0, "_OnPrefixKeyDown must keep the live Tab/Enter clause")
	Tail := SubStr(Seg, Idx)
	NextClause := InStr(Tail, "} else if")
	Branch := NextClause ? SubStr(Tail, 1, NextClause) : Tail
	Assert(InStr(Branch, "LLM_Bridge_FeedKeyDownIfActive(VK)") > 0,
		"the Tab/Enter clause must call LLM_Bridge_FeedKeyDownIfActive(VK) so the Enter flush reaches the LLM bridge")
}
Test("PrefixWatcher: Tab/Enter clause feeds the LLM bridge (onkeydown-dead-llm-branch)", _OKDLB_TabEnterBranchFeedsBridge)

_OKDLB_NoDeadTrailingClause() {
	Seg := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(Seg != "", "_OnPrefixKeyDown must exist in hotstring_prefix_watcher.ahk")
	; The unreachable trailing clause testing all three nav VKs at once must be
	; gone  -  it could never execute because Tab/Enter/Escape matched earlier.
	Assert(InStr(Seg, "VK == 0x09 or VK == 0x0D or VK == 0x1B") == 0,
		"the dead trailing else-if (VK == 0x09 or VK == 0x0D or VK == 0x1B) must be removed  -  it is unreachable after the earlier clauses match")
}
Test("PrefixWatcher: dead trailing nav-VK clause removed (onkeydown-dead-llm-branch)", _OKDLB_NoDeadTrailingClause)
