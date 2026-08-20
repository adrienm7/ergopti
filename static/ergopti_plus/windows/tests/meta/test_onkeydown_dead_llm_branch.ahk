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
; The current fix routes every reset/navigation VK through one ResetVKs branch.
; This test asserts (a) Tab and Enter belong to that live branch, (b) the branch
; feeds the bridge, and (c) the old dead trailing else-if is absent. It therefore
; follows the control-flow contract without pinning the pre-refactor clause text.
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
	ResetBranch := InStr(Seg, "else if ResetVKs.Has(VK)")
	TabEntry := InStr(Seg, "0x09, true")
	EnterEntry := InStr(Seg, "0x0D, true")
	BridgeFeed := InStr(Seg,
		"LLM_Bridge_FeedKeyDownIfActive(VK, true)", true, ResetBranch)
	CatchPos := InStr(Seg, "} catch", true, ResetBranch)
	Assert(ResetBranch > 0 and TabEntry > 0 and TabEntry < ResetBranch
		and EnterEntry > 0 and EnterEntry < ResetBranch,
		"Tab and Enter must remain enrolled in the live ResetVKs branch")
	Assert(BridgeFeed > ResetBranch and CatchPos > BridgeFeed,
		"the live ResetVKs branch must feed its I1-filtered physical Tab/Enter event to the LLM bridge before leaving the guarded dispatch")
}
Test("PrefixWatcher: Tab/Enter clause feeds the LLM bridge (onkeydown-dead-llm-branch)", _OKDLB_TabEnterBranchFeedsBridge)

_OKDLB_NoDeadTrailingClause() {
	Seg := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(Seg != "", "_OnPrefixKeyDown must exist in hotstring_prefix_watcher.ahk")
	; The unreachable trailing clause testing all three nav VKs at once must be
	; gone  -  it could never execute because Tab/Enter/Escape matched earlier.
	Assert(!RegExMatch(Seg,
		"else\s+if\s*\(\s*VK\s*==\s*0x09\s+or\s+VK\s*==\s*0x0D\s+or\s+VK\s*==\s*0x1B\s*\)"),
		"the dead trailing else-if (VK == 0x09 or VK == 0x0D or VK == 0x1B) must be removed  -  it is unreachable after the earlier clauses match")
}
Test("PrefixWatcher: dead trailing nav-VK clause removed (onkeydown-dead-llm-branch)", _OKDLB_NoDeadTrailingClause)
