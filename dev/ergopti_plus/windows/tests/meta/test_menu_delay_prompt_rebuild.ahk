; tests/meta/test_menu_delay_prompt_rebuild.ahk

; ==============================================================================
; MODULE: Tray delay prompts re-register hotstrings after persisting
; DESCRIPTION:
; Hotstring expansion delays are baked into each spec at REGISTRATION time
; (LoadHotstringsSection folds the resolved delay into the spec meta). The tray
; delay prompts (_HS_PromptDefaultDelay / _HS_PromptCategoryDelay for magickey,
; autocorrection, dynamichotstrings, global) ended at HotstringsSetOverride, which
; only bumps the resolve generation and writes the override file — nothing
; re-registered, so every live spec kept its old delay until a full Reload or an
; unrelated section toggle. Each override write must re-register live, the same path
; a section toggle uses. (F32, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_MDPR_OverrideWriteRebuildsLive(FuncName) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must exist in ui/menu/menu_hotstrings.ahk")
	Assert(InStr(Body, "_HS_CommitDelayOverride(") > 0,
		FuncName . " must route persistence and live rebuilding through the shared strict-result helper")
}
_MDPR_BothDelayPromptsRebuild() {
	_MDPR_OverrideWriteRebuildsLive("_HS_PromptDefaultDelay")
	_MDPR_OverrideWriteRebuildsLive("_HS_PromptCategoryDelay")

	Commit := _DriverFuncBody("_HS_CommitDelayOverride")
	Assert(Commit != "", "_HS_CommitDelayOverride must exist in ui/menu/menu_hotstrings.ahk")
	SetPos := InStr(Commit, "HotstringsSetOverride(")
	StrictPos := InStr(Commit, "Committed is Integer")
	RebuildPos := InStr(Commit, "RebuildHotstringsLive()")
	Assert(SetPos > 0, "the shared helper must persist through HotstringsSetOverride")
	Assert(StrictPos > SetPos and RebuildPos > StrictPos,
		"the helper must accept only a strict successful persist BEFORE rebuilding live hotstrings; a refused write must never rebuild from stale state")
}
Test("menu: hotstring delay prompts rebuild only after strict durable success",
	_MDPR_BothDelayPromptsRebuild)
