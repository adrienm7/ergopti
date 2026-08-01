; tests/meta/test_prefix_onkeydown_tab_llm_feed_gap.ahk

; ==============================================================================
; MODULE: PrefixWatcher OnKeyDown LLM Flush-On-Nav Meta Test
; DESCRIPTION:
; Static source guard for finding `prefix-onkeydown-tab-llm-feed-gap`.
;
; The reset_on_nav contract requires the rolling LLM context buffer to flush
; when the user presses Enter (and Tab when no suggestion is accepted) so the
; next prediction starts fresh after a line break. On the PrefixWatcher hook
; path that flush lived in a trailing else-if that AHK could never reach,
; because the live Tab/Enter clause above it matched first and returned. The
; net effect: Enter never flushed the LLM bridge through this watcher.
;
; The fix calls LLM_Bridge_FeedKeyDownIfActive(VK) inside the live Tab/Enter
; clause (which maps 0x0D -> OnFlush) and removes the dead clause. This test
; verifies the live Tab/Enter clause performs the bridge feed AND that
; LLM_Bridge_FeedKeyDownIfActive still routes 0x0D to a flush, so the Enter
; flush is wired end-to-end through the watcher.
;
; Meta-static because _OnPrefixKeyDown and LLM_Bridge_FeedKeyDownIfActive
; (modules/keymap/llm_bridge.ahk) are not both in the run_all include graph and
; have OS / tooltip side effects.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_PTLFG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Flush-on-nav wiring assertions ========
; ==================================================
; ==================================================

_PTLFG_EnterFlushReachesBridgeFromWatcher() {
	Src := _PTLFG_ReadSource("infra/hotstrings/hotstring_prefix_watcher.ahk")
	Seg := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(Seg != "", "_OnPrefixKeyDown must exist in hotstring_prefix_watcher.ahk")
	; Locate the live Tab/Enter clause and confirm it feeds the bridge  -  the
	; only place Enter (0x0D) can reach the LLM flush on this hook path.
	Idx := InStr(Seg, "else if (VK == 0x09 or VK == 0x0D)")
	Assert(Idx > 0, "the live Tab/Enter clause must be present")
	Tail := SubStr(Seg, Idx)
	NextClause := InStr(Tail, "} else if")
	Branch := NextClause ? SubStr(Tail, 1, NextClause) : Tail
	Assert(InStr(Branch, "LLM_Bridge_FeedKeyDownIfActive(VK)") > 0,
		"Enter flush must be wired through the live Tab/Enter clause via LLM_Bridge_FeedKeyDownIfActive(VK); the dead trailing else-if can never run")
}
Test("PrefixWatcher: Enter flush reaches the LLM bridge via the watcher (prefix-onkeydown-tab-llm-feed-gap)", _PTLFG_EnterFlushReachesBridgeFromWatcher)

_PTLFG_BridgeMapsEnterToFlush() {
	Src := _PTLFG_ReadSource("modules/keymap/llm_bridge.ahk")
	Seg := _DriverFuncBody("LLM_Bridge_FeedKeyDownIfActive")
	Assert(Seg != "", "LLM_Bridge_FeedKeyDownIfActive must exist in llm_bridge.ahk")
	; The bridge entry point must still route Enter (0x0D) to a flush, otherwise
	; the watcher feeding it the VK would be a no-op.
	Assert(InStr(Seg, "0x0D") > 0 and InStr(Seg, "LLM_Bridge_OnFlush") > 0,
		"LLM_Bridge_FeedKeyDownIfActive must map 0x0D to LLM_Bridge_OnFlush so the Enter flush actually clears the rolling context")
}
Test("LLM bridge: FeedKeyDownIfActive maps Enter to a flush (prefix-onkeydown-tab-llm-feed-gap)", _PTLFG_BridgeMapsEnterToFlush)
