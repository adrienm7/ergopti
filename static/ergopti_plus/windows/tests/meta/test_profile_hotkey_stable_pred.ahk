; tests/meta/test_profile_hotkey_stable_pred.ahk

; ==============================================================================
; MODULE: Profile Hotkey Stable Predicate Meta-Test
; DESCRIPTION:
; Structural regression for the HotIf predicate hoisting fix in
; ui/menu/menu_llm/menu_profiles.ahk.
;
; Before the fix, LLM_Menu_BindProfileHotkeys() passed a fresh anonymous
; lambda to HotIf on every call:
;   HotIf((*) => _LLM_Menu_IsProfileHotkeyActive())
; AHK v2 keys each HotIf context on the function-reference identity.
; A new lambda object on every call creates a new, distinct context; the
; previous context is never destroyed (AHK has no HotIf deregister API),
; so every menu rebuild leaks an orphaned HotIf slot and its Ctrl+1..9
; bindings.
;
; The fix allocates a single BoundFunc at module load time:
;   global _LLM_PROFILE_HOTKEY_PRED := _LLM_Menu_IsProfileHotkeyActive.Bind()
; and passes that stable reference to HotIf inside LLM_Menu_BindProfileHotkeys().
; Subsequent calls reuse the same context — the hotkeys are simply updated
; in-place with no new context leak.
;
; This test inspects menu_profiles.ahk source and asserts:
;   1. _LLM_PROFILE_HOTKEY_PRED is declared as a module-level global.
;   2. HotIf inside LLM_Menu_BindProfileHotkeys() references _LLM_PROFILE_HOTKEY_PRED.
;   3. An anonymous (*) => lambda is NOT passed directly to HotIf.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================================
; ================================================================
; ======= 1/ Assertions ==========================================
; ================================================================
; ================================================================

_PHSP_StablePredDeclared() {
	; Move-resilient: scan the menu_llm UI dir via the framework helper. The
	; module-level _LLM_PROFILE_HOTKEY_PRED global lives outside any function, so
	; it cannot be reached via _DriverFuncBody — a dir concat is the right scope.
	src := _DriverDirConcat("ui/menu/menu_llm")
	Assert(InStr(src, "_LLM_PROFILE_HOTKEY_PRED") > 0,
		"menu_profiles.ahk: _LLM_PROFILE_HOTKEY_PRED must be declared as a module-level stable BoundFunc for HotIf")
}
Test("Profile hotkeys: _LLM_PROFILE_HOTKEY_PRED stable BoundFunc declared (profile-hotkey-stable-pred)", _PHSP_StablePredDeclared)


_PHSP_HotIfUsesStablePred() {
	; Move-resilient: extract the LLM_Menu_BindProfileHotkeys body via the bare-name
	; helper instead of a pinned read + 400-char window (which would false-match the
	; call site in init.ahk under any concat).
	block := _DriverFuncBody("LLM_Menu_BindProfileHotkeys")
	Assert(InStr(block, "HotIf(_LLM_PROFILE_HOTKEY_PRED)") > 0,
		"menu_profiles.ahk: LLM_Menu_BindProfileHotkeys() must pass _LLM_PROFILE_HOTKEY_PRED (not a fresh lambda) to HotIf")
}
Test("Profile hotkeys: HotIf uses stable _LLM_PROFILE_HOTKEY_PRED in LLM_Menu_BindProfileHotkeys (profile-hotkey-stable-pred)", _PHSP_HotIfUsesStablePred)


_PHSP_NoFreshLambdaInHotIf() {
	block := _DriverFuncBody("LLM_Menu_BindProfileHotkeys")
	; An anonymous (*) => lambda inside HotIf(...) would look like HotIf((*) =>
	Assert(InStr(block, 'HotIf((*) =>') = 0,
		"menu_profiles.ahk: LLM_Menu_BindProfileHotkeys() must not pass a fresh lambda to HotIf — use the hoisted _LLM_PROFILE_HOTKEY_PRED")
}
Test("Profile hotkeys: no fresh lambda passed to HotIf in LLM_Menu_BindProfileHotkeys (profile-hotkey-stable-pred)", _PHSP_NoFreshLambdaInHotIf)
