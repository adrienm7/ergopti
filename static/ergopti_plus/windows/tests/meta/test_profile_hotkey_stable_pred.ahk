; tests/meta/test_profile_hotkey_stable_pred.ahk

; ==============================================================================
; MODULE: Profile Hotkey Stable Predicate Meta-Test
; DESCRIPTION:
; Structural regression for the HotIf predicate hoisting fix in
; ui/tray_llm/menu_profiles.ahk.
;
; Before the fix, LLM_Tray_BindProfileHotkeys() passed a fresh anonymous
; lambda to HotIf on every call:
;   HotIf((*) => _LLM_Tray_IsProfileHotkeyActive())
; AHK v2 keys each HotIf context on the function-reference identity.
; A new lambda object on every call creates a new, distinct context; the
; previous context is never destroyed (AHK has no HotIf deregister API),
; so every menu rebuild leaks an orphaned HotIf slot and its Ctrl+1..9
; bindings.
;
; The fix allocates a single BoundFunc at module load time:
;   global _LLM_PROFILE_HOTKEY_PRED := _LLM_Tray_IsProfileHotkeyActive.Bind()
; and passes that stable reference to HotIf inside LLM_Tray_BindProfileHotkeys().
; Subsequent calls reuse the same context — the hotkeys are simply updated
; in-place with no new context leak.
;
; This test inspects menu_profiles.ahk source and asserts:
;   1. _LLM_PROFILE_HOTKEY_PRED is declared as a module-level global.
;   2. HotIf inside LLM_Tray_BindProfileHotkeys() references _LLM_PROFILE_HOTKEY_PRED.
;   3. An anonymous (*) => lambda is NOT passed directly to HotIf.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================================
; ================================================================
; ======= 1/ Source-inspection helpers ===========================
; ================================================================
; ================================================================

_PHSP_ReadSource() {
	return FileRead(A_ScriptDir . "\..\ui\tray_llm\menu_profiles.ahk", "UTF-8")
}


_PHSP_FindBindBlock(src) {
	pos := InStr(src, "LLM_Tray_BindProfileHotkeys()")
	if (!pos)
		return ""
	return SubStr(src, pos, 400)
}




; ================================================================
; ================================================================
; ======= 2/ Assertions ==========================================
; ================================================================
; ================================================================

_PHSP_StablePredDeclared() {
	src := _PHSP_ReadSource()
	Assert(InStr(src, "_LLM_PROFILE_HOTKEY_PRED") > 0,
		"menu_profiles.ahk: _LLM_PROFILE_HOTKEY_PRED must be declared as a module-level stable BoundFunc for HotIf")
}
Test("Profile hotkeys: _LLM_PROFILE_HOTKEY_PRED stable BoundFunc declared (profile-hotkey-stable-pred)", _PHSP_StablePredDeclared)


_PHSP_HotIfUsesStablePred() {
	block := _PHSP_FindBindBlock(_PHSP_ReadSource())
	Assert(InStr(block, "HotIf(_LLM_PROFILE_HOTKEY_PRED)") > 0,
		"menu_profiles.ahk: LLM_Tray_BindProfileHotkeys() must pass _LLM_PROFILE_HOTKEY_PRED (not a fresh lambda) to HotIf")
}
Test("Profile hotkeys: HotIf uses stable _LLM_PROFILE_HOTKEY_PRED in LLM_Tray_BindProfileHotkeys (profile-hotkey-stable-pred)", _PHSP_HotIfUsesStablePred)


_PHSP_NoFreshLambdaInHotIf() {
	block := _PHSP_FindBindBlock(_PHSP_ReadSource())
	; An anonymous (*) => lambda inside HotIf(...) would look like HotIf((*) =>
	Assert(InStr(block, 'HotIf((*) =>') = 0,
		"menu_profiles.ahk: LLM_Tray_BindProfileHotkeys() must not pass a fresh lambda to HotIf — use the hoisted _LLM_PROFILE_HOTKEY_PRED")
}
Test("Profile hotkeys: no fresh lambda passed to HotIf in LLM_Tray_BindProfileHotkeys (profile-hotkey-stable-pred)", _PHSP_NoFreshLambdaInHotIf)
