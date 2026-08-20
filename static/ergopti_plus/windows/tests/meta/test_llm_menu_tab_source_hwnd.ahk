; tests/meta/test_llm_menu_tab_source_hwnd.ahk

; ==============================================================================
; MODULE: Canonical LLM Tab-Accept Call-Site Guard
; DESCRIPTION:
; Structural regression coverage for AHK-05. The old focus policy existed only
; in the menu hotkey wrapper; InputHook, bridge, gesture and tap-hold paths could
; call the raw primitive without it. This test proves that one canonical
; primitive owns physical-modifier + rendered HWND/control validation, that the
; rendered prediction keeps its own request-bound source, and that every
; production acceptance path is enumerated rather than sampled.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Counting helpers =========
; ======================================
; ======================================

_TLTSH_Count(Haystack, Needle) {
	Count := 0
	Pos := 1
	while (Pos := InStr(Haystack, Needle, true, Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}





; ===============================================
; ===============================================
; ======= 2/ Canonical policy owns checks =======
; ===============================================
; ===============================================

_TLTSH_CanonicalPrimitiveOwnsWholePolicy() {
	AcceptBody := _DriverFuncBody("LLM_Tooltip_TryAcceptTab")
	PolicyBody := _DriverFuncBody("_LLM_Accept_IsAllowed")
	BarePolicyBody := _DriverFuncBody("_LLM_Accept_IsBarePhysicalTabEvent")
	ProbeBody := _DriverFuncBody("_LLM_Accept_ReadInputSnapshot")

	Assert(InStr(AcceptBody, "LLM_Tooltip_GetAcceptSnapshot()") > 0
		and InStr(AcceptBody, "Presented.AcceptSource") > 0,
		"canonical acceptance must consume the source from one presented-record snapshot")
	Assert(InStr(AcceptBody,
		"LLM_Tooltip_ClaimAcceptance(Presented.Record)") > 0,
		"canonical acceptance must atomically claim the exact record it validated")
	Assert(InStr(AcceptBody, "_LLM_Accept_IsAllowed(") > 0,
		"canonical acceptance must delegate its complete decision to one policy predicate")
	Assert(InStr(AcceptBody, "LLM_Bridge_OnAccept(") > 0,
		"the canonical primitive must be the sole gateway to prediction injection")
	Assert(InStr(AcceptBody, "if _LLM_AcceptInProgress") > 0
		and InStr(AcceptBody, "_LLM_Accept_IsBarePhysicalTabEvent(") > 0,
		"HotIf/InputHook callbacks may share a claim only after repeating bare-physical-Tab validation")

	for Needle in ["IsPhysicalTabEvent", "ctrl_down", "alt_down", "shift_down", "win_down", "tab_down"] {
		Assert(InStr(BarePolicyBody, Needle) > 0,
			"canonical bare-Tab event policy is missing required term: " . Needle)
	}
	for Needle in ["SourceHwnd == CurrentHwnd", "SourceControl == CurrentControl"] {
		Assert(InStr(PolicyBody, Needle) > 0,
			"canonical rendered-focus policy is missing required term: " . Needle)
	}
	for Needle in ['GetKeyState("Tab", "P")', 'GetKeyState("Ctrl", "P")',
			'GetKeyState("Alt", "P")', 'GetKeyState("Shift", "P")',
			'GetKeyState("LWin", "P")', 'GetKeyState("RWin", "P")',
			"WIGetFocusedControlToken()"] {
		Assert(InStr(ProbeBody, Needle) > 0,
			"physical/focus snapshot must fail closed through the canonical probe: " . Needle)
	}
	Assert(InStr(ProbeBody, "catch") > 0 and InStr(ProbeBody, '"known", false') > 0,
		"an OS key/focus probe failure must preserve known=false instead of accepting fail-open")
}

Test("LLM accept meta: canonical primitive owns bare-Tab and rendered-focus policy (AHK-05)",
	_TLTSH_CanonicalPrimitiveOwnsWholePolicy)





; ====================================================
; ====================================================
; ======= 3/ Request source follows the render =======
; ====================================================
; ====================================================

_TLTSH_RequestSourceIsBoundAndPublished() {
	CaptureBody := _DriverFuncBody("_LLM_Engine_CaptureAcceptSource")
	OnKeyBody := _DriverFuncBody("LLM_Engine_OnKeystroke")
	StartBody := _DriverFuncBody("LLM_Engine_StartTimer")
	FireBody := _DriverFuncBody("LLM_Engine_FirePrediction")
	SourceForRenderBody := _DriverFuncBody("_LLM_Engine_RequestAcceptSourceForRender")
	RenderBody := _DriverFuncBody("LLM_Engine_OnResults")
	RenderWrapperBody := _DriverFuncBody("LLM_Tooltip_Show")
	RendererBody := _DriverFuncBody("LLM_TooltipShow")
	SurfaceCommitBody := _DriverFuncBody("_LLM_TooltipCommitSurfaceState")
	PresentBody := _DriverFuncBody("_TooltipPresentStack")

	Assert(InStr(CaptureBody, 'Map("hwnd", 0, "control", 0)') > 0,
		"source capture must produce one fail-closed HWND/focused-control snapshot")
	Assert(InStr(CaptureBody, "WIGetFocusedControlToken()") > 0,
		"source capture must use focused-control identity, not top-level HWND alone")
	Assert(InStr(OnKeyBody, "LLM_Engine_FirePrediction.Bind(buffer, AcceptSource)") > 0,
		"per-keystroke debounce must bind the source snapshot into its timer closure")
	Assert(InStr(StartBody, "LLM_Engine_FirePrediction.Bind(buffer, AcceptSource)") > 0,
		"hotstring-chain timer must bind its own source snapshot too")
	Assert(InStr(FireBody, '"request_accept_source"') > 0,
		"FirePrediction must attach the bound source to the current request id")
	Assert(InStr(SourceForRenderBody, 'RequestId == ""') > 0
		and InStr(SourceForRenderBody, 'Source.Get("request_id", -1) != RequestId') > 0,
		"a render without an exact request identity match must fail closed")
	AssertEqual(2, _TLTSH_Count(FireBody, "LLM_Engine_OnResults("),
		"FirePrediction must keep exactly the enumerated exact-cache and prefix-cache render sites")
	NormalizedFireBody := RegExReplace(FireBody, "\s+", " ")
	Assert(InStr(NormalizedFireBody,
		'LLM_Engine_OnResults(_LLM_Engine["last_results"], ctx, 1, true, this_request_id, request_semantic_signature)') > 0,
		"the exact-cache render must carry the request and semantic identities that own its captured source")
	Assert(InStr(NormalizedFireBody,
		"LLM_Engine_OnResults(sliced, ctx, 1, true, this_request_id, request_semantic_signature)") > 0,
		"the prefix-cache render must carry the request and semantic identities that own its captured source")
	ExpectedCallbackCalls := Map(
		"_LLM_Engine_DispatchVariant",
			'LLM_Engine_OnResults(preview_slots, state["ctx"], active_idx, false, state["request_id"], state["semantic_signature"])',
		"_LLM_Engine_OnStreamPartial",
			'LLM_Engine_OnResults(preview, state["ctx"], slot_idx, false, state["request_id"], state["semantic_signature"])',
		"_LLM_Engine_OnVariantSuccess",
			'LLM_Engine_OnResults(state["slots"], state["ctx"], active_idx, false, state["request_id"], state["semantic_signature"])',
		"_LLM_Engine_FinalizeRequest",
			'LLM_Engine_OnResults(state["slots"], state["ctx"], 1, true, state["request_id"], state["semantic_signature"])'
	)
	for CallbackName, ExpectedCall in ExpectedCallbackCalls {
		CallbackBody := _DriverFuncBody(CallbackName)
		Assert(InStr(RegExReplace(CallbackBody, "\s+", " "), ExpectedCall) > 0,
			CallbackName . " must pass its own request id into every render")
	}
	Assert(InStr(RenderWrapperBody, "return LLM_TooltipShow(") > 0,
		"the public tooltip wrapper must return the generation of its exact render")
	Assert(InStr(RendererBody, "return RenderGeneration") > 0
		and InStr(RendererBody, "return false") > 0,
		"the renderer must distinguish the committed generation from suspend/empty/superseded/build-failure exits")
	NormalizedRender := RegExReplace(RenderBody, "\s+", " ")
	Assert(InStr(NormalizedRender,
		'"accept_source", RenderAcceptSource') > 0
		and InStr(NormalizedRender,
		"LLM_Tooltip_Show(display_slots, active, is_final, PresentationMeta)") > 0,
		"the render must carry its immutable source inside the candidate presentation tuple")
	Assert(InStr(SurfaceCommitBody,
		"SurfaceToken.LlmPresented := Record") > 0,
		"the candidate surface must own the exact slots/index/source lifecycle record")
	CommitPos := InStr(PresentBody,
		'CommitFn.Call(PreparedSurface, RetiredSurface)')
	SwapPos := InStr(PresentBody,
		"_TooltipActiveSurface := PreparedSurface")
	Assert(CommitPos > 0 and SwapPos > CommitPos,
		"candidate semantics must attach before the single active-surface publication")

	DriverSrc := _DriverSourceNoComments()
	Assert(InStr(DriverSrc, '"rendered_accept_source"') == 0,
		"the engine must not retain a second mutable owner for visible acceptance source")
	EngineSrc := _DriverDirConcat("modules/llm")
	Assert(InStr(EngineSrc, '"source_hwnd"') == 0
		and InStr(EngineSrc, '"source_control_token"') == 0,
		"legacy mutable engine focus fields must not coexist with request/presentation-owned source snapshots")
	BoundTimers := _TLTSH_Count(DriverSrc,
		"LLM_Engine_FirePrediction.Bind(buffer, AcceptSource)")
	AssertEqual(4, BoundTimers,
		"all four FirePrediction timer/retry bindings must carry AcceptSource; a newly added raw Bind is an unowned-control regression")
	AssertEqual(7, _TLTSH_Count(DriverSrc, "LLM_Engine_OnResults("),
		"OnResults must have one definition plus exactly the six enumerated request-owned render call sites")
}

Test("LLM accept meta: request-bound HWND/control is published by the actual render (AHK-05)",
	_TLTSH_RequestSourceIsBoundAndPublished)





; ===================================================
; ===================================================
; ======= 4/ Every acceptance site enumerated =======
; ===================================================
; ===================================================

_TLTSH_EveryDirectAcceptCallIsCanonical() {
	DriverSrc := _DriverSourceNoComments()
	FeedBody := _DriverFuncBody("LLM_Bridge_FeedKeyDownIfActive")
	DispatcherBody := _DriverFuncBody("_LLM_Bridge_OnDispatcherKey")
	FireTabBody := _DriverFuncBody("LLM_Tooltip_FireTabOrAccept")
	InjectCompleteBody := _DriverFuncBody("_LLM_Bridge_OnInjectComplete")
	PrefixBody := _DriverFuncBody("_OnPrefixKeyDown")
	PrefixStartBody := _DriverFuncBody("_StartInputHook")

	Assert(InStr(FeedBody, "LLM_Tooltip_TryAcceptTab(IsPhysicalEvent, [])") > 0,
		"the bridge must pass its raw-event provenance into canonical acceptance")
	Assert(InStr(FeedBody, "IsPhysicalEvent := false") > 0,
		"the bridge must default unknown/dispatcher events to non-physical provenance")
	Assert(InStr(FireTabBody, "LLM_Tooltip_TryAcceptTab(IsPhysicalTabEvent, Modifiers)") > 0,
		"gesture/tap-hold/menu Tab output must delegate event provenance and modifiers to canonical acceptance")
	Assert(InStr(FireTabBody, "IsPhysicalTabEvent := false") > 0,
		"the shared wrapper must fail closed unless a physical Tab producer opts in explicitly")
	Assert(InStr(FireTabBody, 'TextPressKey("Tab", Modifiers)') > 0,
		"a rejected acceptance must still emit the caller's configured Tab navigation")
	AssertEqual(2, _TLTSH_Count(PrefixBody, "LLM_Bridge_FeedKeyDownIfActive(VK, true)"),
		"the Backspace and unified non-Space reset branches must preserve physical-event provenance")
	Assert(InStr(PrefixStartBody, 'InputHook("V L0 I1")') > 0,
		"PrefixWatcher may declare physical provenance only while I1 excludes synthetic events")
	Assert(InStr(DispatcherBody, "LLM_Bridge_FeedKeyDownIfActive(vk)") > 0,
		"the synthetic-visible dispatcher fallback must retain fail-closed default provenance")
	Assert(InStr(PrefixBody, "LLM_Tooltip_TryAcceptTab(") == 0,
		"PrefixWatcher must not grow a second raw acceptance path beside the bridge")
	NormalizedComplete := RegExReplace(InjectCompleteBody, "\s+", " ")
	Assert(InStr(NormalizedComplete,
		"LLM_Bridge_DeferTooltipHide(true, Transaction.PresentedRecord)") > 0
		and InStr(NormalizedComplete,
			"LLM_Tooltip_FinalizeAcceptance( Transaction.PresentedLifecycle, true)") > 0
		and InStr(InjectCompleteBody, "_LLM_Accept_DeferClaimRelease()") > 0,
		"successful injection must finalize and defer-hide the exact consumed record before releasing the shared claim")
	Assert(InStr(InjectCompleteBody, "if !HideQueued") > 0,
		"sender failure must also defer claim release when no tooltip hide is queued")

	DirectRefs := _TLTSH_Count(DriverSrc, "LLM_Tooltip_TryAcceptTab(")
	AssertEqual(3, DirectRefs,
		"LLM_Tooltip_TryAcceptTab must have exactly one definition plus the two enumerated production callers; inspect every new occurrence before updating this count")
	OnAcceptRefs := _TLTSH_Count(DriverSrc, "LLM_Bridge_OnAccept(")
	AssertEqual(2, OnAcceptRefs,
		"LLM_Bridge_OnAccept must have exactly one definition and one call from the canonical primitive; any extra call bypasses policy")
}

Test("LLM accept meta: every direct injection/accept call site is enumerated (AHK-05)",
	_TLTSH_EveryDirectAcceptCallIsCanonical)

_TLTSH_EveryTabProducerUsesTheGuardedWrapper() {
	DriverSrc := _DriverSourceNoComments()
	MenuSrc := _DriverDirConcat("ui/menu/menu_llm")
	GestureSrc := _DriverDirConcat("modules/gestures")
	RemapSrc := _DriverDirConcat("platform/remap")

	Assert(InStr(MenuSrc, "LLM_Tooltip_FireTabOrAccept([], true)") > 0,
		"physical Tab HotIf must be the sole wrapper caller that declares physical provenance")
	Assert(InStr(GestureSrc, "LLM_Tooltip_FireTabOrAccept([])") > 0,
		"gesture Tab must pass through the same wrapper and fail physical-Tab validation")
	Assert(InStr(RemapSrc, 'TapHoldDispatchTap("left_alt", LLM_Tooltip_FireTabOrAccept.Bind(""))') > 0,
		"LAlt Tab remap must pass through canonical physical-Tab validation")
	Assert(InStr(RemapSrc, 'TapHoldDispatchTap("right_ctrl", LLM_Tooltip_FireTabOrAccept.Bind(""))') > 0,
		"RCtrl Tab remap must pass through canonical physical-Tab validation")

	WrapperRefs := _TLTSH_Count(DriverSrc, "LLM_Tooltip_FireTabOrAccept")
	AssertEqual(5, WrapperRefs,
		"the guarded Tab wrapper must have one definition plus exactly the four enumerated menu/gesture/LAlt/RCtrl references; inspect every new reference before updating this count")
	AssertEqual(1, _TLTSH_Count(DriverSrc, "LLM_Tooltip_FireTabOrAccept([], true)"),
		"only the physical Tab HotIf may opt the shared wrapper into physical-event acceptance")
	AssertEqual(4, _TLTSH_Count(DriverSrc, "LLM_Bridge_FeedKeyDownIfActive("),
		"the bridge feed must have one definition plus two PrefixWatcher branches and one dispatcher caller")
}

Test("LLM accept meta: every menu, gesture and tap-hold Tab producer is enumerated (AHK-05)",
	_TLTSH_EveryTabProducerUsesTheGuardedWrapper)
