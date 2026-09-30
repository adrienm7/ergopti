; tests/unit/test_llm_tab_accepts_visible_prediction.ahk

; ==============================================================================
; MODULE: Physical Tab and navigation keys over a visible AI prediction
; DESCRIPTION:
; Regression coverage for a report on a Windows build of 2026-09-30: Tab typed a
; Tab into the application instead of inserting the prediction on screen.
;
; ROOT CAUSE ENCODED (llm-tab-accepts-visible-prediction): the acceptance hotkey
; was `Tab::` under `#HotIf LLM_Tooltip_GetText() != ""`. platform/remap/tab.ahk
; declares static SC00F hotkeys, and AutoHotkey's hook then resolves every
; physical Tab through the scan code alone (hook.cpp: ChangeHookState sets
; ksc[sc].sc_takes_precedence for an explicit scan-code hotkey; LowLevelCommon
; looks up only Kscm and lets the key through when no variant is eligible). The
; `Tab::` hotkey therefore never fired. Acceptance survived only inside the Tab
; tap-hold variants, and the neutral configuration (category_enabled.tap_holds
; false since 2026-09-28) leaves them all ineligible: the Tab reached the
; application, and the prefix InputHook's late attempt ran after it had moved
; the focus. The press is now owned by an SC00F variant declared after every
; tap-hold variant, eligible whenever the tooltip offers text.
;
; The behavioural half drives the real render commit, the native-owner bridge
; (through the deterministic port of the navigation owner tests), the real
; accept snapshot and the canonical policy. Runs after test_llm_nav_event_owner,
; whose fixtures it reuses; test_llm_tooltip_nav_consumed reuses its helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ Shared helpers =======
; =================================
; =================================

_LTAV_Input(Hwnd := 100, Control := 1001, CtrlDown := false, TabDown := true) {
	return Map(
		"known", true, "tab_down", TabDown, "ctrl_down", CtrlDown,
		"alt_down", false, "shift_down", false, "win_down", false,
		"current_hwnd", Hwnd, "current_control", Control)
}

_LTAV_ParenBalance(Line) {
	return StrLen(Line) - StrLen(StrReplace(Line, "("))
		- (StrLen(Line) - StrLen(StrReplace(Line, ")")))
}

; Every static hotkey label whose key part matches KeyPattern, in source order,
; with the #HotIf governing it (a multi-line #HotIf joined on one line) and the
; lines that follow the label.
_LTAV_Variants(Src, KeyPattern) {
	Variants := []
	HotIf := ""
	Depth := 0
	Lines := StrSplit(Src, "`n", "`r")
	for Index, Raw in Lines {
		Line := Trim(Raw)
		if (Depth > 0) {
			HotIf .= " " . Line
			Depth += _LTAV_ParenBalance(Line)
			continue
		}
		if (SubStr(Line, 1, 6) = "#HotIf") {
			HotIf := Line
			Depth := _LTAV_ParenBalance(Line)
			continue
		}
		if !RegExMatch(Line, "i)^([~$*#!^+<>]*)(" . KeyPattern . ")(?: Up)?::", &Label)
			continue
		Next := ""
		Loop 4 {
			if Lines.Has(Index + A_Index)
				Next .= " " . Trim(Lines[Index + A_Index])
		}
		Variants.Push({ Label: Label[0], Prefix: Label[1], HotIf: HotIf,
			Body: Line . Next })
	}
	return Variants
}

; A tap-hold variant is one whose criterion asks the Tab key's configuration.
_LTAV_IsTapHoldVariant(Variant) {
	for Accessor in ["TapHoldTapAction(", "TapHoldHoldModifier(", "TapHoldHoldLayer("] {
		if InStr(Variant.HotIf, Accessor)
			return true
	}
	return false
}





; ==================================================
; ==================================================
; ======= 2/ The physical Tab's hotkey owner =======
; ==================================================
; ==================================================

_LTAV_NoHotkeyIsNamedByTheTabKey() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")
	ScanCodeLabels := _LTAV_Variants(Src, "SC00F")
	Assert(ScanCodeLabels.Length >= 5,
		"the SC00F hotkeys that give the scan code precedence must be scanned, got "
		. ScanCodeLabels.Length)
	Named := ""
	for Variant in _LTAV_Variants(Src, "Tab|vk0?9")
		Named .= (Named = "" ? "" : ", ") . Variant.Label
	AssertEqual("", Named,
		"a hotkey named by the Tab key never fires while SC00F hotkeys exist: AutoHotkey resolves the physical Tab by its scan code only")
	AssertEqual(0, RegExMatch(Src, 'i)\bHotkey\(\s*"[~$*#!^+<>]*(?:Tab|vk0?9)"'),
		"no runtime hotkey may be named by the Tab key either")
}

Test("LLM accept: no hotkey is named by the Tab key while SC00F hotkeys exist (llm-tab-accepts-visible-prediction)",
	_LTAV_NoHotkeyIsNamedByTheTabKey)

_LTAV_AcceptanceVariantOwnsTheKeyWithoutTapHold() {
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Variants := _LTAV_Variants(Src, "SC00F")
	Exact := []
	for Variant in Variants {
		if (Variant.Prefix == "" || Variant.Prefix == "$")
			Exact.Push(Variant)
	}
	Assert(Exact.Length >= 5, "every exact SC00F variant must be scanned, got " . Exact.Length)
	AcceptIndex := 0
	LastTapHoldIndex := 0
	for Index, Variant in Exact {
		if InStr(Variant.HotIf, 'LLM_Tooltip_GetText() != ""') {
			AssertEqual(0, AcceptIndex,
				"exactly one SC00F variant may own the press for a visible prediction")
			AcceptIndex := Index
		}
		if _LTAV_IsTapHoldVariant(Variant)
			LastTapHoldIndex := Index
	}
	Assert(AcceptIndex > 0,
		"an SC00F variant must accept the visible prediction when no Tab tap-hold is eligible")
	Variant := Exact[AcceptIndex]
	AssertFalse(_LTAV_IsTapHoldVariant(Variant),
		"the acceptance variant must not depend on the Tab tap-hold, which the neutral configuration disables")
	AssertContains(Variant.HotIf, "not LayerEnabled",
		"the navigation layer keeps the key while it is held")
	AssertContains(Variant.HotIf, "not TapHoldKanaAltGrHeld()",
		"AltGr+Tab on a Kana layout is a chord, never an acceptance")
	Assert(AcceptIndex > LastTapHoldIndex,
		"the earliest-created eligible variant fires: the acceptance variant must follow every tap-hold variant so a configured tap-hold keeps the press")
	Assert(RegExMatch(Variant.Body,
			'^SC00F::\s*\{\s*if _TabAcceptVisiblePrediction\(\)\s*return\s*TapHoldEmitKeyTap\("Tab"\)\s*\}') > 0,
		"the variant must accept through the canonical physical-press helper, and type the native Tab when refused: " . Variant.Body)
}

Test("LLM accept: an SC00F variant accepts a visible prediction with the Tab tap-hold off (llm-tab-accepts-visible-prediction)",
	_LTAV_AcceptanceVariantOwnsTheKeyWithoutTapHold)





; ==================================================
; ==================================================
; ======= 3/ Render, snapshot, policy, claim =======
; ==================================================
; ==================================================

; Publishes one prediction the way LLM_TooltipShow does: the real render commit
; attaches the record to a detached surface, then the one active-surface
; assignment is fenced by the native owner like _TooltipPresentStack fences it.
_LTAV_RenderPrediction(Slots, ActiveIdx, IsFinal) {
	global _TooltipGeneration, _TooltipActiveSurface
	Generation := _TooltipGeneration + 1
	_TooltipGeneration := Generation
	Surface := {
		LlmPresented: 0, Generation: Generation, RenderedActiveIdx: 0,
		Rows: [], Border: 0, ContentHwnds: [], BorderHwnds: []
	}
	; Each render is its own offer: a shared offer id would reuse the retired
	; surface's lifecycle, which is the navigation repaint's contract, not this one.
	Meta := Map(
		"offer_id", Generation,
		"accept_source", Map("hwnd", 100, "control", 1001,
			"request_id", Generation),
		"app_name", "editor.exe",
		"is_final", IsFinal)
	Retired := _TooltipActiveSurface
	AssertTrue(_LLM_TooltipCommitSurfaceState(Slots, ActiveIdx, Generation,
		Meta, Surface, Retired), "the render commit must attach the prediction to its surface")
	Swap := LLM_NavEventOwner_BeginSurfaceSwap(Retired, Surface)
	AssertTrue(Swap is Map && !Swap["retry"],
		"the native owner must fence the publication of the rendered surface")
	_TooltipActiveSurface := Surface
	AssertTrue(LLM_NavEventOwner_CommitSurfaceSwap(Swap),
		"the native owner must adopt the rendered prediction")
	return Surface
}

_LTAV_RenderedPredictionIsAcceptedByAPhysicalTab() {
	global _TooltipGeneration
	SavedGeneration := _TooltipGeneration
	Scenarios := [
		{ Label: "final multi-slot render", Slots: ["alpha", "beta", "gamma"],
			Active: 2, Final: true, Text: "beta" },
		{ Label: "streaming single-slot render", Slots: ["alpha be"],
			Active: 1, Final: false, Text: "alpha be" }
	]
	Checked := 0
	for Scenario in Scenarios {
		State := _LNEO_Setup()
		try {
			_LTAV_RenderPrediction(Scenario.Slots, Scenario.Active, Scenario.Final)
			; LLM_Tooltip_GetText() is the 8.5 variant's criterion.
			AssertEqual(Scenario.Text, LLM_TooltipGetText(),
				Scenario.Label . ": the painted prediction must make the Tab variant eligible")
			Snapshot := LLM_TooltipGetAcceptSnapshot()
			AssertTrue(IsObject(Snapshot),
				Scenario.Label . ": a visible prediction must offer an accept snapshot")
			AssertEqual(Scenario.Text, Snapshot.Text,
				Scenario.Label . ": the snapshot must carry the active slot")
			AssertEqual(100, Snapshot.AcceptSource["hwnd"],
				Scenario.Label . ": the render must publish its request's window")
			AssertEqual(1001, Snapshot.AcceptSource["control"],
				Scenario.Label . ": the render must publish its request's control")
			AssertTrue(_LLM_Accept_IsAllowed(true, [], _LTAV_Input(),
				Snapshot.AcceptSource),
				Scenario.Label . ": a bare physical Tab in the rendered control must be admitted")
			AssertFalse(_LLM_Accept_IsAllowed(true, [], _LTAV_Input(100, 1002),
				Snapshot.AcceptSource),
				Scenario.Label . ": a Tab typed in another control must never inject")
			AssertFalse(_LLM_Accept_IsAllowed(false, [], _LTAV_Input(),
				Snapshot.AcceptSource),
				Scenario.Label . ": a synthetic Tab must never inject")
			AssertFalse(_LLM_Accept_IsAllowed(true, [], _LTAV_Input(100, 1001, true),
				Snapshot.AcceptSource),
				Scenario.Label . ": a chord must never inject")
			Lifecycle := LLM_TooltipClaimAcceptance(Snapshot.Record,
				Snapshot.Surface, Snapshot.ActiveIdx)
			AssertTrue(IsObject(Lifecycle) && Lifecycle.Outcome == "claimed",
				Scenario.Label . ": the admitted press must claim the exact rendered record")
			AssertEqual(1, State.ClaimCalls.Length,
				Scenario.Label . ": the claim must detach the native owner once")
			Checked++
		} finally {
			_LNEO_Teardown()
			_TooltipGeneration := SavedGeneration
		}
	}
	AssertEqual(2, Checked, "every render shape must be checked")
}

Test("LLM accept: a rendered prediction is accepted by a bare physical Tab in its control (llm-tab-accepts-visible-prediction)",
	_LTAV_RenderedPredictionIsAcceptedByAPhysicalTab)





; ========================================
; ========================================
; ======= 4/ Refused Tab is traced =======
; ========================================
; ========================================

_LTAV_RefusalGateNamesEachCondition() {
	Source := Map("hwnd", 100, "control", 1001)
	Vectors := [
		[false, [], _LTAV_Input(), "the Tab is neither the physical Tab nor a tap-hold's tap"],
		[true, ["Ctrl"], _LTAV_Input(), "the Tab declares modifiers"],
		[true, [], _LTAV_Input(100, 1001, false, false), "Tab is not physically down"],
		[true, [], _LTAV_Input(100, 1001, true), "a modifier is physically held"],
		[true, [], _LTAV_Input(200, 1001), "the focus is not the control the prediction was rendered for"],
		[true, [], _LTAV_Input(), ""]
	]
	for Vector in Vectors {
		Gate := _LLM_Accept_RefusalGate(Vector[1], Vector[2], Vector[3], Source)
		AssertEqual(Vector[4], Gate, "the refusal must name the condition that failed")
		AssertEqual(Gate == "", _LLM_Accept_IsAllowed(Vector[1], Vector[2],
			Vector[3], Source) ? true : false,
			"the gate and the policy must agree on every vector: " . Vector[4])
	}
	Unknown := _LTAV_Input()
	Unknown["known"] := false
	AssertEqual("the focus could not be verified",
		_LLM_Accept_RefusalGate(true, [], Unknown, Source),
		"an unverifiable focus must be named")
}

Test("LLM accept: the refusal gate names the policy condition that failed (llm-tab-accepts-visible-prediction)",
	_LTAV_RefusalGateNamesEachCondition)

_LTAV_RefusedPhysicalTabIsTracedOnlyOverAPrediction() {
	global _LOGGER_DEBUG_ENABLED, _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading
	SavedDebug := _LOGGER_DEBUG_ENABLED
	SavedVisible := _Stub_LlmTooltipVisible
	SavedLoading := _Stub_LlmTooltipLoading
	Captured := []
	_LOGGER_DEBUG_ENABLED := true
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		_Stub_LlmTooltipVisible := true
		_Stub_LlmTooltipLoading := false
		AssertTrue(LLM_Tooltip_ReportTabRefusal("Tab is not physically down"),
			"a physical Tab refused over a shown prediction must be traced")
		Traced := 0
		for Line in Captured {
			if InStr(Line, "[WARNING]") && InStr(Line, "Tab is not physically down")
				Traced++
		}
		; A refused Tab leaves the user with a Tab typed and no prediction, so it
		; is a warning the errors-first logs keep (llm-accept-inserts).
		AssertEqual(1, Traced, "the trace must be one WARNING line naming the gate")
		Captured.Length := 0
		_Stub_LlmTooltipVisible := false
		AssertFalse(LLM_Tooltip_ReportTabRefusal("the shown prediction offers no acceptable snapshot"),
			"an ordinary Tab with no tooltip must not be traced")
		_Stub_LlmTooltipVisible := true
		_Stub_LlmTooltipLoading := true
		AssertFalse(LLM_Tooltip_ReportTabRefusal("the shown prediction offers no acceptable snapshot"),
			"a Tab over the loading indicator must not be traced")
		AssertEqual(0, Captured.Length, "neither untraced case may log")
		AssertThrows(() => LLM_Tooltip_ReportTabRefusal(""),
			"a refusal without a gate name is a caller bug")
	} finally {
		LoggerClearTestSink()
		_LOGGER_DEBUG_ENABLED := SavedDebug
		_Stub_LlmTooltipVisible := SavedVisible
		_Stub_LlmTooltipLoading := SavedLoading
	}
}

Test("LLM accept: a refused physical Tab is traced only over a shown prediction (llm-tab-accepts-visible-prediction)",
	_LTAV_RefusedPhysicalTabIsTracedOnlyOverAPrediction)
