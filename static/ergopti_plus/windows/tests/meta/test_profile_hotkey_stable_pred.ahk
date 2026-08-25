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
	; The module-level owner lives outside any function, so scan executable driver
	; source (comments stripped) and require its actual assignment, not prose.
	Src := _DriverSourceNoComments()
	BinderPos := InStr(Src, "LLM_Menu_BindProfileHotkeys(")
	PredPattern := "m)^global[ \t]+_LLM_PROFILE_HOTKEY_PRED[ \t]*:="
		. "[ \t]*_LLM_Menu_IsProfileHotkeyActive\.Bind\(\)"
	PredPos := RegExMatch(Src, PredPattern)
	Assert(PredPos > 0,
		"menu_profiles.ahk: _LLM_PROFILE_HOTKEY_PRED must be declared as a module-level stable BoundFunc for HotIf")
	Assert(BinderPos > PredPos
		&& RegExMatch(Src, PredPattern, , PredPos + 1) == 0,
		"the stable predicate must have one owner before the production binder")
	OwnerPattern := "m)^global[ \t]+_LLM_Menu_ProfileHotkeyOwner"
		. "[ \t]*:=[ \t]*0[ \t]*$"
	OwnerPos := RegExMatch(Src, OwnerPattern)
	Assert(OwnerPos > 0 && OwnerPos < BinderPos
		&& RegExMatch(Src, OwnerPattern, , OwnerPos + 1) == 0,
		"profile hotkeys need one unpublished module-level readiness owner")
	LimitPattern := "m)^global[ \t]+LLM_PROFILE_HOTKEY_LIMIT"
		. "[ \t]*:=[ \t]*9[ \t]*$"
	LimitPos := RegExMatch(Src, LimitPattern)
	Assert(LimitPos > 0
		&& RegExMatch(Src, LimitPattern, , LimitPos + 1) == 0,
		"the production profile surface must own exactly Ctrl+1 through Ctrl+9")
	RetryPattern := "m)^global[ \t]+_LLM_PROFILE_HOTKEY_RETRY_LIMIT"
		. "[ \t]*:=[ \t]*([0-9]+)[ \t]*$"
	RetryPos := RegExMatch(Src, RetryPattern, &RetryMatch)
	Assert(RetryPos > 0 && Integer(RetryMatch[1]) >= 2,
		"the bounded profile retry budget must remain an explicit integer >= 2")
	Assert(RegExMatch(Src, RetryPattern, , RetryPos + 1) == 0,
		"the profile retry budget must have one production owner")
}
Test("Profile hotkeys: _LLM_PROFILE_HOTKEY_PRED stable BoundFunc declared (profile-hotkey-stable-pred)", _PHSP_StablePredDeclared)


_PHSP_HotIfUsesStablePred() {
	; Move-resilient: extract the LLM_Menu_BindProfileHotkeys body via the bare-name
	; helper instead of a pinned read + 400-char window (which would false-match the
	; call site in init.ahk under any concat).
	Block := _StripFullLineComments(
		_DriverFuncBody("LLM_Menu_BindProfileHotkeys"))
	Assert(Block != "",
		"menu_profiles.ahk: the profile binder must remain reachable")
	Assert(InStr(Block, "HotIfFn.Call(_LLM_PROFILE_HOTKEY_PRED)") > 0,
		"menu_profiles.ahk: the injected binder must pass the stable predicate to HotIf")
}
Test("Profile hotkeys: HotIf uses stable _LLM_PROFILE_HOTKEY_PRED in LLM_Menu_BindProfileHotkeys (profile-hotkey-stable-pred)", _PHSP_HotIfUsesStablePred)


_PHSP_NoFreshLambdaInHotIf() {
	block := _StripFullLineComments(
		_DriverFuncBody("LLM_Menu_BindProfileHotkeys"))
	Assert(block != "", "the profile binder must remain in the scanned source")
	; An anonymous (*) => lambda inside HotIf(...) would look like HotIf((*) =>
	Assert(InStr(block, 'HotIf((*) =>') = 0,
		"menu_profiles.ahk: LLM_Menu_BindProfileHotkeys() must not pass a fresh lambda to HotIf — use the hoisted _LLM_PROFILE_HOTKEY_PRED")
	Assert(InStr(block, 'HotIfFn.Call((*) =>') = 0,
		"the injected binder must not allocate a fresh HotIf predicate")
}
Test("Profile hotkeys: no fresh lambda passed to HotIf in LLM_Menu_BindProfileHotkeys (profile-hotkey-stable-pred)", _PHSP_NoFreshLambdaInHotIf)

_PHSP_BindersExposeNativeTransactionPorts() {
	for Name in ["LLM_Menu_BindProfileHotkeys", "LLM_Menu_BindNavHotkeys"] {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", Name . " must remain reachable to the class guard")
		Assert(InStr(Body, "HotkeyFn") > 0 && InStr(Body, "HotIfFn") > 0,
			Name . " must expose deterministic native registration ports")
	}
	PromptApply := _StripFullLineComments(
		_DriverFuncBody("_PromptEdWeb_ApplyCommitted"))
	Assert(PromptApply != "",
		"the prompt-editor committed publisher must remain reachable")
	Assert(InStr(PromptApply, "LLM_Menu_BindProfileHotkeys") == 0,
		"profile CRUD must not restart the immutable native registration surface")
}

Test("Profile hotkeys: profile and nav binders expose native transaction ports",
	_PHSP_BindersExposeNativeTransactionPorts)

_PHSP_ProfileCallbackNeverSynthesizesPassThrough() {
	Callback := _StripFullLineComments(
		_DriverFuncBody("_LLM_Menu_OnProfileHotkey"))
	Predicate := _StripFullLineComments(
		_DriverFuncBody("_LLM_Menu_IsProfileHotkeyActive"))
	Receipt := _StripFullLineComments(
		_DriverFuncBody("_LLM_NavEventOwnerApplyProfileReceipt"))
	NativeSelect := _StripFullLineComments(
		_DriverFuncBody("_LLM_Menu_ProfileNativeSelect"))
	Binder := _StripFullLineComments(
		_DriverFuncBody("LLM_Menu_BindProfileHotkeys"))
	Assert(Callback != "",
		"the production profile callback must remain reachable")
	Assert(NativeSelect != "" && Binder != "" && Predicate != ""
		&& Receipt != "",
		"the tested selection seam and its production binder must remain reachable")
	Assert(InStr(Predicate, 'Get("native", false)') > 0
		&& InStr(Callback, 'Get("native", false)') > 0,
		"native profile ownership must disarm both legacy AHK admission stages")
	Assert(InStr(Receipt, "Entry.Order[TargetIdx]") > 0
		&& InStr(Receipt, 'Receipt["profile_effect_done"] := true') > 0,
		"profile receipts must resolve their retained order and separate effect from ACK")
	Assert(InStr(NativeSelect, "LLM_Menu_SetProfile(ProfileId)") > 0
		&& InStr(Binder, "SelectFn := _LLM_Menu_ProfileNativeSelect") > 0
		&& InStr(Binder,
			"_LLM_Menu_BuildProfileHotkeyPlan(SelectFn, KeyResolverFn)") > 0,
		"the behavioral selection seam must preserve the production profile publisher")
	Assert(Trim(RegExReplace(NativeSelect, "\s+", " "))
		== "_LLM_Menu_ProfileNativeSelect(ProfileId) { return LLM_Menu_SetProfile(ProfileId) }",
		"the production selector must remain a transparent profile-publisher adapter")
	; No LLM menu helper may hide the replay behind another function. The
	; directory currently has no legitimate synthetic-key emitter, so scan the
	; complete move-resilient production subtree rather than a hand-picked call
	; chain that a helper extraction could escape.
	MenuSource := _StripFullLineComments(
		_DriverDirConcat("ui/menu/menu_llm"))
	Assert(MenuSource != "", "the production LLM menu subtree must be scanned")
	Normalized := RegExReplace(MenuSource, "\s+", " ")
	for Name in ["Send", "SendInput", "SendEvent", "SendText", "SendPlay",
			"ControlSend", "ControlSendText"] {
		Pattern := "i)(?:^|[^A-Za-z0-9_])" . Name . "(?: |[(])"
		Assert(!RegExMatch(Normalized, Pattern),
			"an out-of-range profile variant must use native HotIf pass-through, never a synthetic Send fallback")
	}
}

Test("Profile hotkeys: callback has no synthetic pass-through fallback (profile-hotkey-stable-pred)",
	_PHSP_ProfileCallbackNeverSynthesizesPassThrough)
