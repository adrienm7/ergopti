; tests/meta/modules/hotstrings/catalogue/test_menu_delay_prompt_rebuild.ahk

; ==============================================================================
; MODULE: Tray delay prompts re-register hotstrings after persisting
; DESCRIPTION:
; Hotstring expansion delays are baked into each spec at REGISTRATION time
; (LoadHotstringsSection folds the resolved delay into the spec meta). The tray
; delay prompts (_HS_PromptDefaultDelay / _HS_PromptCategoryDelay for magickey,
; autocorrection, dynamichotstrings, and the base expansion delay) ended at HotstringsSetOverride, which
; only bumps the resolve generation and writes the override file — nothing
; re-registered, so every live spec kept its old delay until a full Reload or an
; unrelated section toggle. Each override write must re-register live, the same path
; a section toggle uses. (F32, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_MDPR_OverrideWriteRebuildsLive(FuncName, Helper) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must exist in ui/menu/menu_hotstrings.ahk")
	Assert(InStr(Body, Helper . "(") > 0,
		FuncName . " must route persistence and live rebuilding through the shared strict-result helper")
}

; Both persistence helpers accept only a strict successful write, then hand the
; live re-registration to the one rebuild owner.
_MDPR_HelperRebuildsAfterStrictWrite(Helper, Writer) {
	Commit := _DriverFuncBody(Helper)
	Assert(Commit != "", Helper . " must exist in ui/menu/menu_hotstrings.ahk")
	SetPos := InStr(Commit, Writer . "(")
	StrictPos := InStr(Commit, "Committed is Integer")
	RebuildPos := InStr(Commit, "_HS_RebuildAfterDelayChange(")
	Assert(SetPos > 0, Helper . " must persist through " . Writer)
	Assert(StrictPos > SetPos and RebuildPos > StrictPos,
		Helper . " must accept only a strict successful persist BEFORE rebuilding live hotstrings; a refused write must never rebuild from stale state")
}

_MDPR_BothDelayPromptsRebuild() {
	_MDPR_OverrideWriteRebuildsLive("_HS_PromptDefaultDelay", "_HS_CommitBaseDelay")
	_MDPR_OverrideWriteRebuildsLive("_HS_PromptCategoryDelay", "_HS_CommitDelayOverride")
	_MDPR_HelperRebuildsAfterStrictWrite("_HS_CommitDelayOverride", "HotstringsSetOverride")
	_MDPR_HelperRebuildsAfterStrictWrite("_HS_CommitBaseDelay", "HotstringsSetBaseDelay")

	Rebuild := _DriverFuncBody("_HS_RebuildAfterDelayChange")
	Assert(Rebuild != "", "_HS_RebuildAfterDelayChange must exist in ui/menu/menu_hotstrings.ahk")
	Assert(InStr(Rebuild, "RebuildHotstringsLive()") > 0,
		"the rebuild owner must re-register the hotstrings live")
}
Test("menu: hotstring delay prompts rebuild only after strict durable success",
	_MDPR_BothDelayPromptsRebuild)
