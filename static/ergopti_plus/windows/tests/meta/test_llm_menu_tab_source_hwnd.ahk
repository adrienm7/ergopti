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
	; The claim and the single injection call live in one helper shared by the
	; Tab and validation-chord primitives, so the two cannot drift apart
	; (llm-val-chord-inserts).
	ClaimBody := _DriverFuncBody("_LLM_Accept_ClaimAndDispatch")
	FocusBody := _DriverFuncBody("_LLM_Accept_FocusMatchesSource")
	SlotBody := _DriverFuncBody("LLM_Tooltip_TryAcceptSlot")
	; Each policy has one implementation, the refusal that names its failing
	; gate; the predicates only compare it with "" (llm-accept-inserts).
	SlotPolicyBody := _DriverFuncBody("_LLM_Accept_SlotRefusal")
	BarePolicyBody := _DriverFuncBody("_LLM_Accept_BareTabRefusal")
	ProbeBody := _DriverFuncBody("_LLM_Accept_ReadInputSnapshot")

	Assert(InStr(AcceptBody, "LLM_Tooltip_GetAcceptSnapshot()") > 0
		and InStr(AcceptBody, "Presented.AcceptSource") > 0,
		"canonical acceptance must consume the source from one presented-record snapshot")
	NormalizedClaim := RegExReplace(ClaimBody, "\s+", " ")
	Assert(InStr(NormalizedClaim,
		"LLM_Tooltip_ClaimAcceptance( Presented.Record, Presented.Surface, Presented.ActiveIdx)") > 0,
		"canonical acceptance must atomically claim the exact record, surface, and immutable index it validated")
	Assert(InStr(ClaimBody, "if _LLM_AcceptInProgress") > 0,
		"the shared claim must refuse while another acceptance owns the latch")
	Assert(InStr(AcceptBody, "_LLM_Accept_IsAllowed(") > 0,
		"canonical acceptance must delegate its complete decision to one policy predicate")
	Assert(InStr(AcceptBody, "_LLM_Accept_ClaimAndDispatch(Presented") > 0,
		"Tab acceptance must claim and inject only through the shared helper")
	Assert(InStr(ClaimBody, "LLM_Bridge_OnAccept(") > 0,
		"the shared claim helper must be the sole gateway to prediction injection")
	Assert(InStr(SlotBody, "_LLM_Accept_SlotIsAllowed(") > 0
		and InStr(SlotBody, "_LLM_Accept_ClaimAndDispatch(Presented") > 0,
		"the validation-chord primitive must apply its own policy, then the shared claim")
	Assert(InStr(_DriverFuncBody("_LLM_Accept_SlotIsAllowed"),
			"_LLM_Accept_SlotRefusal(") > 0
		and InStr(_DriverFuncBody("_LLM_Accept_IsBareUserTabEvent"),
			"_LLM_Accept_BareTabRefusal(") > 0,
		"each policy predicate must delegate to its single refusal implementation")
	for Needle in ["ObjPtr(Presented.Record) != ObjPtr(ExpectedRecord)",
			"ObjPtr(Presented.Surface) != ObjPtr(ExpectedSurface)",
			"Presented.ActiveIdx != SlotIdx",
			"_LLM_Accept_AnyModifierDown(InputSnapshot)",
			"_LLM_Accept_FocusMatchesSource(InputSnapshot, Presented.AcceptSource)"] {
		Assert(InStr(SlotPolicyBody, Needle) > 0,
			"validation-chord policy is missing required term: " . Needle)
	}
	Assert(InStr(AcceptBody, "if _LLM_AcceptInProgress") > 0
		and InStr(AcceptBody, "_LLM_Accept_IsBareUserTabEvent(") > 0,
		"HotIf/InputHook callbacks may share a claim only after repeating bare user-Tab validation")

	; The user's Tab is the physical Tab while it is down, or a tap-hold's Tab
	; tap while the dispatcher still runs that very tap (llm-accept-inserts).
	for Needle in ["TabProvenance", "ctrl_down", "alt_down", "shift_down",
			"win_down", "tab_down", "TapHoldTapInDispatch() != TapKey"] {
		Assert(InStr(BarePolicyBody, Needle) > 0,
			"canonical bare-Tab event policy is missing required term: " . Needle)
	}
	Assert(InStr(PolicyBody, "_LLM_Accept_FocusMatchesSource(") > 0,
		"the Tab policy must use the shared rendered-focus predicate")
	for Needle in ["SourceHwnd == CurrentHwnd", "SourceControl == CurrentControl"] {
		Assert(InStr(FocusBody, Needle) > 0,
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
	; The third bound argument is live mode's prompt override (or 0)
	Assert(InStr(OnKeyBody, "LLM_Engine_FirePrediction.Bind(buffer, AcceptSource,") > 0,
		"per-keystroke debounce must bind the source snapshot into its timer closure")
	Assert(InStr(StartBody, "LLM_Engine_FirePrediction.Bind(buffer, AcceptSource,") > 0,
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
			'LLM_Engine_OnResults(preview_slots, state["ctx"], active_idx, false, state["request_id"], state["semantic_signature"], state.Get("rewrite_edits", ""))',
		"_LLM_Engine_OnStreamPartial",
			'LLM_Engine_OnResults(preview, state["ctx"], slot_idx, false, state["request_id"], state["semantic_signature"])',
		"_LLM_Engine_OnVariantSuccess",
			'LLM_Engine_OnResults(state["slots"], state["ctx"], active_idx, false, state["request_id"], state["semantic_signature"], state.Get("rewrite_edits", ""))',
		"_LLM_Engine_FinalizeRequest",
			'LLM_Engine_OnResults(state["slots"], state["ctx"], 1, true, state["request_id"], state["semantic_signature"], state.Get("rewrite_edits", ""))'
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
		"LLM_Engine_FirePrediction.Bind(buffer, AcceptSource")
	AssertEqual(4, BoundTimers,
		"all four FirePrediction timer/retry bindings must carry AcceptSource; a newly added raw Bind is an unowned-control regression")
	; The warmup and rate-limit re-arms replay a prompt action's own request.
	AssertEqual(2, _TLTSH_Count(DriverSrc,
		"LLM_Engine_FirePrediction.Bind(buffer, AcceptSource, Override)"),
		"both FirePrediction retry bindings must carry the prompt override, or a retried prompt action runs the menu's prompt")
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
	Assert(InStr(FireTabBody, "LLM_Tooltip_TryAcceptTab(TabProvenance, Modifiers)") > 0,
		"gesture/tap-hold/menu Tab output must delegate event provenance and modifiers to canonical acceptance")
	Assert(InStr(FireTabBody, "TabProvenance := false") > 0,
		"the shared wrapper must fail closed unless a user Tab producer passes its provenance")
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

	TabPressBody := _DriverFuncBody("_TabAcceptVisiblePrediction")
	Assert(TabPressBody != "",
		"the physical Tab tap-hold press acceptance must be scanned")
	Assert(InStr(TabPressBody, "LLM_Tooltip_TryAcceptTab(true, [])") > 0,
		"the physical SC00F press is a real bare Tab event and must use canonical acceptance")

	DirectRefs := _TLTSH_Count(DriverSrc, "LLM_Tooltip_TryAcceptTab(")
	AssertEqual(4, DirectRefs,
		"LLM_Tooltip_TryAcceptTab must have exactly one definition plus the three enumerated production callers (bridge feed, Tab-accept wrapper, physical Tab tap-hold press); inspect every new occurrence before updating this count")
	OnAcceptRefs := _TLTSH_Count(DriverSrc, "LLM_Bridge_OnAccept(")
	AssertEqual(2, OnAcceptRefs,
		"LLM_Bridge_OnAccept must have exactly one definition and one call from the shared claim helper; any extra call bypasses policy")
	AssertEqual(4, _TLTSH_Count(DriverSrc, "_LLM_Accept_ClaimAndDispatch("),
		"the shared claim helper must have one definition plus exactly the Tab, validation-chord and automation primitives as callers")
	; Third canonical primitive (llm-automation-accepts): defined once and driven
	; only by the registered message an external program posts, never by a key,
	; gesture, macro or text send of the driver.
	AssertEqual(2, _TLTSH_Count(DriverSrc, "LLM_Tooltip_TryAcceptAutomation("),
		"LLM_Tooltip_TryAcceptAutomation must have one definition plus the single message-driven caller")
	Assert(InStr(_DriverFuncBody("_LLM_Automation_Accept"),
		"LLM_Tooltip_TryAcceptAutomation()") > 0,
		"the automation request must insert through the canonical automation primitive")
	for HandlerName in ["_LLM_Automation_OnAcceptMessage", "_LLM_Automation_Accept"] {
		Assert(InStr(_DriverFuncBody(HandlerName), "A_IsSuspended || !_LLM_Bridge_Active") > 0,
			HandlerName . " must ignore requests while suspended or while the bridge is inactive")
	}
	AssertEqual(4, _TLTSH_Count(DriverSrc, "_LLM_Automation_Listen("),
		"the automation listener must have one definition plus the two bridge activations and the stop")
	; Second canonical primitive (llm-val-chord-inserts): defined once and driven
	; only by the release wait armed from the native jump-receipt drain.
	AssertEqual(2, _TLTSH_Count(DriverSrc, "LLM_Tooltip_TryAcceptSlot("),
		"LLM_Tooltip_TryAcceptSlot must have one definition plus the single release-wait caller")
	Assert(InStr(_DriverFuncBody("_LLM_SlotAccept_Insert"),
		"LLM_Tooltip_TryAcceptSlot(") > 0,
		"the release wait must insert through the canonical slot primitive")
	Assert(InStr(_DriverFuncBody("_LLM_NavEventOwnerDrain"),
		"LLM_Tooltip_ScheduleSlotAcceptance") > 0,
		"the native jump-receipt drain must arm the validation-chord insertion")
}

Test("LLM accept meta: every direct injection/accept call site is enumerated (AHK-05)",
	_TLTSH_EveryDirectAcceptCallIsCanonical)

_TLTSH_EveryTabProducerUsesTheGuardedWrapper() {
	DriverSrc := _DriverSourceNoComments()
	GestureSrc := _DriverDirConcat("modules/gestures")
	RemapSrc := _DriverDirConcat("platform/remap")

	; The physical Tab accepts only through the SC00F handlers, which declare
	; their provenance to the policy directly (_TabAcceptVisiblePrediction)
	; (llm-tab-accepts-visible-prediction). A tap-hold's Tab tap is the user's own
	; Tab key: it passes the dispatcher's provenance, which the policy trusts
	; only while that tap is dispatched. A gesture passes none and must fail
	; (llm-accept-inserts).
	Assert(InStr(GestureSrc, "LLM_Tooltip_FireTabOrAccept([])") > 0,
		"gesture Tab must pass through the same wrapper and fail user-Tab validation")
	Assert(InStr(RemapSrc,
			"return LLM_Tooltip_FireTabOrAccept(Modifiers, TapHoldTapProvenance())") > 0,
		"the tap-hold keystroke tap must send a Tab through canonical user-Tab validation with its dispatch provenance")
	DispatchBody := RegExReplace(_DriverFuncBody("TapHoldDispatchTap"), "\s+", " ")
	MarkAt := InStr(DispatchBody, "_TapHoldTapInDispatch := KeyId try TapFn.Call()")
	Assert(MarkAt > 0,
		"the dispatcher must name the tapped key for exactly the duration of its tap callback")
	Assert(InStr(DispatchBody, "finally _TapHoldTapInDispatch := PreviousTap", true, MarkAt) > 0,
		"the dispatcher must restore the outer provenance even when the tap callback throws")
	AssertEqual(3, _TLTSH_Count(DriverSrc, "_TapHoldTapInDispatch := "),
		"only the dispatcher may set the tap provenance: the global initialiser, the dispatch and its restore")
	AssertEqual(2, _TLTSH_Count(DriverSrc, "TapHoldTapProvenance()"),
		"the tap provenance must have one definition and the single keystroke-tap caller")
	Assert(InStr(RemapSrc, 'TapHoldDispatchTap("left_alt", TapHoldEmitKeyTap.Bind("Tab"))') > 0,
		"LAlt Tab remap must pass through canonical physical-Tab validation")
	Assert(InStr(RemapSrc, 'TapHoldDispatchTap("right_ctrl", TapHoldEmitKeyTap.Bind("Tab"))') > 0,
		"RCtrl Tab remap must pass through canonical physical-Tab validation")

	WrapperRefs := _TLTSH_Count(DriverSrc, "LLM_Tooltip_FireTabOrAccept")
	AssertEqual(3, WrapperRefs,
		"the guarded Tab wrapper must have one definition plus exactly the two enumerated gesture/tap-hold references; inspect every new reference before updating this count")
	AssertEqual(0, RegExMatch(DriverSrc, "LLM_Tooltip_FireTabOrAccept\([^)\r\n]*,\s*true\)"),
		"no caller may opt the shared wrapper into physical-event acceptance: the physical Tab accepts through its SC00F handlers")
	AssertEqual(4, _TLTSH_Count(DriverSrc, "LLM_Bridge_FeedKeyDownIfActive("),
		"the bridge feed must have one definition plus two PrefixWatcher branches and one dispatcher caller")
}

Test("LLM accept meta: every menu, gesture and tap-hold Tab producer is enumerated (AHK-05)",
	_TLTSH_EveryTabProducerUsesTheGuardedWrapper)

; A scan-code hotkey on SC00F shadows any hotkey named by the Tab key, so a
; tap-hold on the physical Tab key used to run its tap action (alt_tab_monitor,
; a layer...) over a visible prediction. Acceptance also needs Tab physically
; down, so it must happen on the press, before any tap/hold resolution
; (llm-tab-taphold-accept). The fifth handler owns the press when no tap-hold
; does (llm-tab-accepts-visible-prediction).
_TLTSH_EveryPhysicalTabTapHoldAcceptsFirst() {
	SplitPath(A_ScriptDir, , &Root)
	; FileRead throws if the module moves, so the scan can never go vacuous.
	Src := _StripFullLineComments(FileRead(Root . "\platform\remap\tab.ahk", "UTF-8"))
	Assert(Src != "", "platform/remap/tab.ahk must be scanned")
	Handlers := 0
	Pos := 1
	while (Pos := RegExMatch(Src, "m)^\$?SC00F::\s*(\{|_TabDispatch)", &Match, Pos)) {
		Handlers += 1
		Assert(Match[1] == "{",
			"every physical Tab handler must be a block that can accept first (line: " . Match[0] . ")")
		Body := SubStr(Src, Pos + StrLen(Match[0]), 200)
		Assert(RegExMatch(Body, "^\s*if _TabAcceptVisiblePrediction\(\)\s*return") > 0,
			"physical Tab handler #" . Handlers . " must accept a visible prediction before any tap-hold logic")
		Pos += StrLen(Match[0])
	}
	AssertEqual(5, Handlers,
		"the four tap-hold variants of SC00F (alt_tab_monitor, hold-modifier, hold-layer, tap-only) and the no-tap-hold acceptance variant must all be covered")
}

Test("LLM accept meta: physical Tab tap-holds accept a visible prediction on press (llm-tab-taphold-accept)",
	_TLTSH_EveryPhysicalTabTapHoldAcceptsFirst)
