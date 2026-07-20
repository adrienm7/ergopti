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
	SetPos := InStr(Body, "HotstringsSetOverride(")
	RebuildPos := InStr(Body, "RebuildHotstringsLive()")
	Assert(SetPos > 0, FuncName . " must persist the delay via HotstringsSetOverride")
	Assert(RebuildPos > SetPos,
		FuncName . " must call RebuildHotstringsLive() AFTER HotstringsSetOverride so the new delay takes effect live, not only after a Reload")
}
_MDPR_BothDelayPromptsRebuild() {
	_MDPR_OverrideWriteRebuildsLive("_HS_PromptDefaultDelay")
	_MDPR_OverrideWriteRebuildsLive("_HS_PromptCategoryDelay")
}
Test("menu: hotstring delay prompts re-register live after writing the override",
	_MDPR_BothDelayPromptsRebuild)
