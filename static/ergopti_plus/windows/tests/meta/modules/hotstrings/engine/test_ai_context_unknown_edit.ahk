; tests/meta/modules/hotstrings/engine/test_ai_context_unknown_edit.ahk

; ==============================================================================
; MODULE: AI Context After Unknown Edits Meta Test
; DESCRIPTION:
; Static source guard for WRSW-002. Ctrl+Backspace, Select All and other
; physical editing shortcuts returned from _OnPrefixKeyDown before either LLM
; key-feed call, and a synthetic edit declared only the hotstring buffers, so a
; fresh observer forwarded the obsolete complete text after the edit.
; LLM_Bridge_OnUnknownEdit is the single owner that retires the prediction and
; agent-only contexts; arrows stay on reset_on_nav and are not routed through it.
;
; Meta-static: the headless runner cannot run the prefix hook together with the
; real bridge and agent observers; native AHK execution remains to be qualified.
; ==============================================================================

#Requires AutoHotkey v2.0

_AIU_OwnerClearsBothContexts() {
	Body := _DriverFuncBody("LLM_Bridge_OnUnknownEdit")
	Assert(InStr(Body, "_LLM_Bridge_ClearBuffer()") > 0 and InStr(Body, "LLM_Bridge_ResetPredictions()") > 0,
		"the prediction context and its requests must be retired")
	Assert(InStr(Body, "LLM_Bridge_MirrorAgentEdit(0, " . Chr(34) . Chr(34) . ", true)") > 0,
		"the agent-only context must be cleared even when predictions are off")
	Assert(InStr(Body, "RESET_ON_NAV") == 0,
		"an unknown edit is not navigation: it must not be gated by reset_on_nav")
}
Test("AI context: one owner retires both contexts after an unknown edit (WRSW-002)", _AIU_OwnerClearsBothContexts)

_AIU_PhysicalBranchesNotify() {
	Body := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(InStr(Body, "LLM_Bridge_OnUnknownEdit(" . Chr(34) . "Modified Backspace" . Chr(34) . ")") > 0,
		"the modified Backspace early return must notify the AI context")
	Assert(InStr(Body, "LLM_Bridge_OnUnknownEdit(" . Chr(34) . "Shortcut" . Chr(34) . ")") > 0,
		"the shortcut early return (Select All, undo, paste) must notify the AI context")
}
Test("AI context: physical editing shortcuts notify the owner (WRSW-002)", _AIU_PhysicalBranchesNotify)

_AIU_SyntheticEffectsNotify() {
	Commit := _DriverFuncBody("HS_CommitSyntheticEffect")
	Assert(InStr(Commit, "ClearsAiContext: Kind != " . Chr(34) . "arrow" . Chr(34)) > 0,
		"a synthetic reset clears the AI context except for arrows, which keep reset_on_nav")
	Finish := _DriverFuncBody("HS_FinishSyntheticEffect")
	Assert(InStr(Finish, "LLM_Bridge_OnUnknownEdit(") > 0,
		"the notification runs after the Critical send boundary, in the finish phase")
}
Test("AI context: qualified synthetic effects notify the owner (WRSW-002)", _AIU_SyntheticEffectsNotify)
