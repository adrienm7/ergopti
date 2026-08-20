; tests/unit/test_llm_tab_accept_policy.ahk

; ==============================================================================
; MODULE: Canonical LLM Tab-Accept Policy Unit Tests
; DESCRIPTION:
; Behavioural regression coverage for AHK-05. Every LLM acceptance path now
; delegates to LLM_Tooltip_TryAcceptTab, which accepts exactly one visible
; prediction only for an unmodified physical Tab in the HWND/control that owns
; the rendered tooltip. The rendered source is intentionally distinct from the
; mutable source of the newest pending keystroke.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Deterministic seams =======
; ======================================
; ======================================

global _LTAP_AcceptCount := 0
global _LTAP_LastAcceptedText := ""
global _LTAP_ReentrySnapshot := ""
global _LTAP_ReentryResult := false
global _LTAP_ReentryRemapResult := true
global _LTAP_ReentryCtrlResult := true

_LTAP_Input(TabDown := true, CtrlDown := false, AltDown := false,
		ShiftDown := false, WinDown := false, Hwnd := 100, Control := 1001,
		Known := true) {
	return Map(
		"known", Known,
		"tab_down", TabDown,
		"ctrl_down", CtrlDown,
		"alt_down", AltDown,
		"shift_down", ShiftDown,
		"win_down", WinDown,
		"current_hwnd", Hwnd,
		"current_control", Control
	)
}

_LTAP_Setup(SourceHwnd := 100, SourceControl := 1001) {
	global _LLM_Engine, _LLM_AcceptInProgress
	global _Stub_LlmTooltipVisible, _Stub_LlmTooltipText
	global _Stub_LlmPresentedRecord
	global _LTAP_AcceptCount, _LTAP_LastAcceptedText, _LTAP_ReentryResult
	global _LTAP_ReentryRemapResult, _LTAP_ReentryCtrlResult
	_Stub_LlmTooltipVisible := true
	_Stub_LlmTooltipText := "predicted text"
	_LLM_AcceptInProgress := false
	_LTAP_AcceptCount := 0
	_LTAP_LastAcceptedText := ""
	_LTAP_ReentryResult := false
	_LTAP_ReentryRemapResult := true
	_LTAP_ReentryCtrlResult := true
	_LLM_Engine["request_id"] := 41
	Source := Map(
		"hwnd", SourceHwnd,
		"control", SourceControl,
		"request_id", 41
	)
	_LLM_Engine["request_accept_source"] := Source.Clone()
	Lifecycle := {
		OfferId: 41, AcceptSource: Source.Clone(), AppName: "source.exe",
		Slots: ["predicted text"], Suggested: true, Outcome: ""
	}
	_Stub_LlmPresentedRecord := {
		Kind: "prediction", Slots: ["predicted text"], ActiveIdx: 1,
		Lifecycle: Lifecycle, IsFinal: true, Generation: 1,
		ShownAt: A_TickCount
	}
}

_LTAP_Teardown() {
	global _LLM_Engine, _LLM_AcceptInProgress
	global _Stub_LlmTooltipVisible, _Stub_LlmTooltipText
	global _Stub_LlmPresentedRecord
	_Stub_LlmTooltipVisible := false
	_Stub_LlmTooltipText := ""
	_LLM_AcceptInProgress := false
	_LLM_Engine["request_accept_source"] := ""
	_Stub_LlmPresentedRecord := 0
}

_LTAP_RecordAccept(Text) {
	global _LTAP_AcceptCount, _LTAP_LastAcceptedText
	_LTAP_AcceptCount += 1
	_LTAP_LastAcceptedText := Text
}

_LTAP_RecordAcceptAndReenter(Text) {
	global _LTAP_ReentrySnapshot, _LTAP_ReentryResult
	global _LTAP_ReentryRemapResult, _LTAP_ReentryCtrlResult
	_LTAP_RecordAccept(Text)
	_LTAP_ReentryRemapResult := LLM_Tooltip_TryAcceptTab(
		false, [], _LTAP_ReentrySnapshot, _LTAP_RecordAccept)
	_LTAP_ReentryCtrlResult := LLM_Tooltip_TryAcceptTab(
		true, [], _LTAP_Input(true, true), _LTAP_RecordAccept)
	_LTAP_ReentryResult := LLM_Tooltip_TryAcceptTab(
		true, [], _LTAP_ReentrySnapshot, _LTAP_RecordAccept)
}





; ===========================================
; ===========================================
; ======= 2/ Modifier and focus table =======
; ===========================================
; ===========================================

_LTAP_BareTabModifierAndFocusTable() {
	global _LTAP_AcceptCount, _LTAP_LastAcceptedText
	Vectors := [
		Map("label", "bare Tab, originating control", "input", _LTAP_Input(), "accept", true),
		Map("label", "Ctrl+Tab", "input", _LTAP_Input(true, true), "accept", false),
		Map("label", "Alt+Tab", "input", _LTAP_Input(true, false, true), "accept", false),
		Map("label", "Shift+Tab", "input", _LTAP_Input(true, false, false, true), "accept", false),
		Map("label", "Win+Tab", "input", _LTAP_Input(true, false, false, false, true), "accept", false),
		Map("label", "remap while physical Tab is also down", "input", _LTAP_Input(),
			"physical_event", false, "accept", false),
		Map("label", "declared physical event with Tab up", "input", _LTAP_Input(false), "accept", false),
		Map("label", "declared remap modifier", "input", _LTAP_Input(),
			"modifiers", ["Ctrl"], "accept", false),
		Map("label", "stale top-level HWND", "input", _LTAP_Input(true, false, false, false, false, 200, 1001), "accept", false),
		Map("label", "stale control in same HWND", "input", _LTAP_Input(true, false, false, false, false, 100, 1002), "accept", false),
		Map("label", "unverifiable focus", "input", _LTAP_Input(true, false, false, false, false, 0, 0, false), "accept", false)
	]
	for TestVector in Vectors {
		_LTAP_Setup()
		try {
			IsPhysicalTabEvent := TestVector.Get("physical_event", true)
			Modifiers := TestVector.Get("modifiers", [])
			Accepted := LLM_Tooltip_TryAcceptTab(
				IsPhysicalTabEvent, Modifiers, TestVector["input"], _LTAP_RecordAccept)
			ExpectedCount := TestVector["accept"] ? 1 : 0
			AssertEqual(TestVector["accept"], Accepted,
				TestVector["label"] . ": acceptance result must follow the canonical bare-physical-Tab policy")
			AssertEqual(ExpectedCount, _LTAP_AcceptCount,
				TestVector["label"] . ": prediction injection callback count must be exactly " . ExpectedCount)
			if TestVector["accept"]
				AssertEqual("predicted text", _LTAP_LastAcceptedText,
					"the accepted callback must receive the active tooltip text exactly once")
		} finally {
			_LTAP_Teardown()
		}
	}
}

Test("LLM accept: only bare physical Tab in the rendered HWND/control injects once (AHK-05)",
	_LTAP_BareTabModifierAndFocusTable)





; ======================================================
; ======================================================
; ======= 3/ Rendered generation owns acceptance =======
; ======================================================
; ======================================================

_LTAP_VisibleAIsNotReattributedToNewEngineStateB() {
	global _LLM_Engine, _LTAP_AcceptCount, _Stub_LlmPresentedRecord
	_LTAP_Setup(100, 1001)
	try {
		; Tooltip A remains visible during its grace window. A physical character in
		; control B updates the pending engine source, but it must not mutate the
		; source already published by A's render.
		_LLM_Engine["request_id"] := 42
		_LLM_Engine["request_accept_source"] := Map(
			"hwnd", 200, "control", 2001, "request_id", 42)
		Accepted := LLM_Tooltip_TryAcceptTab(
			true, [], _LTAP_Input(true, false, false, false, false, 200, 2001),
			_LTAP_RecordAccept)
		AssertFalse(Accepted,
			"a still-visible tooltip rendered for control A must never inject into newly focused control B")
		AssertEqual(0, _LTAP_AcceptCount,
			"rewriting pending engine focus to B must not re-attribute A's visible prediction")
		Rendered := _Stub_LlmPresentedRecord.Lifecycle.AcceptSource
		AssertEqual(100, Rendered["hwnd"], "A's rendered HWND must remain immutable")
		AssertEqual(1001, Rendered["control"], "A's rendered control token must remain immutable")
	} finally {
		_LTAP_Teardown()
	}
}

Test("LLM accept: a visible A tooltip is not re-attributed when pending input moves to B (AHK-05)",
	_LTAP_VisibleAIsNotReattributedToNewEngineStateB)

_LTAP_RenderSourceRequiresExactRequestIdentity() {
	global _LLM_Engine
	_LTAP_Setup()
	try {
		Source := _LLM_Engine_RequestAcceptSourceForRender(41)
		AssertTrue(Source is Map,
			"the request that owns the render must resolve a detached accept source")
		AssertEqual(100, Source["hwnd"], "the matching request must preserve its HWND")
		AssertEqual(1001, Source["control"],
			"the matching request must preserve its focused-control token")
		AssertEqual("", _LLM_Engine_RequestAcceptSourceForRender(42),
			"a superseded request id must not borrow the current request's focus")
		AssertEqual("", _LLM_Engine_RequestAcceptSourceForRender(),
			"a render with no request identity must fail closed")
		Source["hwnd"] := 999
		AssertEqual(100, _LLM_Engine["request_accept_source"]["hwnd"],
			"the render-owned source must be detached from mutable request state")
	} finally {
		_LTAP_Teardown()
	}
}

Test("LLM accept: rendered focus source requires an exact request identity (AHK-05)",
	_LTAP_RenderSourceRequiresExactRequestIdentity)

_LTAP_ReentrantRawCallerInjectsOnce() {
	global _LLM_AcceptInProgress
	global _LTAP_AcceptCount, _LTAP_ReentrySnapshot, _LTAP_ReentryResult
	global _LTAP_ReentryRemapResult, _LTAP_ReentryCtrlResult
	_LTAP_Setup()
	try {
		_LTAP_ReentrySnapshot := _LTAP_Input()
		Accepted := LLM_Tooltip_TryAcceptTab(
			true, [], _LTAP_ReentrySnapshot, _LTAP_RecordAcceptAndReenter)
		AssertTrue(Accepted, "the outer bare-Tab acceptance must succeed")
		AssertTrue(_LTAP_ReentryResult,
			"a sibling callback for the same physical Tab must consume the existing acceptance claim")
		AssertFalse(_LTAP_ReentryRemapResult,
			"a remap must not join an unrelated physical-Tab acceptance claim")
		AssertFalse(_LTAP_ReentryCtrlResult,
			"Ctrl+Tab must not join a bare-Tab acceptance claim")
		AssertEqual(1, _LTAP_AcceptCount,
			"HotIf/InputHook re-entry must dispatch exactly one injection callback")
		AssertFalse(_LLM_AcceptInProgress,
			"the deterministic callback seam must release its acceptance claim on return")
	} finally {
		_LTAP_Teardown()
	}
}

Test("LLM accept: concurrent raw caller joins one claim without double-injecting (AHK-05)",
	_LTAP_ReentrantRawCallerInjectsOnce)





; ======================================================
; ======================================================
; ======= 4/ Deferred output admission epochs ==========
; ======================================================
; ======================================================

_LTAP_AdmissionState(Hwnd := 100, Control := 1001, Physical := 500,
		Content := 20, Context := 30, Request := 40, Suspended := false) {
	return Map(
		"hwnd", Hwnd,
		"control", Control,
		"physical_generation", Physical,
		"content_generation", Content,
		"context_generation", Context,
		"request_id", Request,
		"suspended", Suspended
	)
}

_LTAP_DeferredAdmissionRejectsEveryStaleDimension() {
	Expected := _LTAP_AdmissionState()
	Vectors := [
		Map("label", "exact state", "live", _LTAP_AdmissionState(), "allowed", true),
		Map("label", "new HWND", "live", _LTAP_AdmissionState(101), "allowed", false),
		Map("label", "new control", "live", _LTAP_AdmissionState(100, 1002), "allowed", false),
		Map("label", "new physical input", "live", _LTAP_AdmissionState(100, 1001, 501), "allowed", false),
		Map("label", "content ABA", "live", _LTAP_AdmissionState(100, 1001, 500, 21), "allowed", false),
		Map("label", "caret/navigation reset", "live", _LTAP_AdmissionState(100, 1001, 500, 20, 31), "allowed", false),
		Map("label", "new engine request", "live", _LTAP_AdmissionState(100, 1001, 500, 20, 30, 41), "allowed", false),
		Map("label", "driver suspended", "live", _LTAP_AdmissionState(100, 1001, 500, 20, 30, 40, true), "allowed", false),
		Map("label", "zero target", "live", _LTAP_AdmissionState(0, 0), "allowed", false)
	]
	for Vector in Vectors {
		AssertEqual(Vector["allowed"],
			_LLM_Bridge_TextAdmissionMatches(Expected, Vector["live"]),
			Vector["label"] . ": deferred output admission verdict")
	}
	Malformed := Expected.Clone()
	Malformed.Delete("content_generation")
	AssertFalse(_LLM_Bridge_TextAdmissionMatches(Expected, Malformed),
		"a missing admission dimension must fail closed")
	StringZero := _LTAP_AdmissionState()
	StringZero["request_id"] := "40"
	AssertFalse(_LLM_Bridge_TextAdmissionMatches(Expected, StringZero),
		"numeric-looking strings must not pass the strictly typed admission contract")
}

Test("LLM accept: deferred output rechecks target and every ABA epoch (llm-output-atomicity)",
	_LTAP_DeferredAdmissionRejectsEveryStaleDimension)
