; tests/unit/modules/hotstrings/prefix/test_prefix_bridge_idle_fragment.ahk

; ==============================================================================
; MODULE: Bridge-Only Idle Fragment Regressions
; DESCRIPTION:
; Actual prefix callbacks must not join a bridge fragment across an idle reset
; while Hotstrings is disabled. Complete bridge words keep their existing policy.
; ==============================================================================

#Requires AutoHotkey v2.0

_PBIF_Sequence(Mode, State, Schedule, Focus) {
	global CategoryEnabled, Features, ScriptInformation
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_IdleResetSeconds, HSE_Suppressed
	global _PrefixBuffer, _PrefixContentGeneration, _PrefixInputContextGeneration
	global _PrefixFocusedControlToken, _PrefixLastKeyTick, _PrefixPrivateResidue
	global _PrefixWatcherSuppressed, _PrefixVisibleFireDecisions, _KLLastShownSuggestion
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_AgentBuffer
	global _LLM_Bridge_AgentFeeding, _LLM_Bridge_PrefixObserver
	global _PrefixRenderTimer, _PrefixRenderScheduledGeneration, _PrefixRenderQueuedWallMs
	Saved := { Categories: CategoryEnabled, Features: Features, Information: ScriptInformation,
		Idle: HSE_IdleResetSeconds, Suppressed: HSE_Suppressed,
		Prefix: _PrefixBuffer, Content: _PrefixContentGeneration, Context: _PrefixInputContextGeneration,
		Focus: _PrefixFocusedControlToken, Tick: _PrefixLastKeyTick, Private: _PrefixPrivateResidue,
		PrefixSuppressed: _PrefixWatcherSuppressed, Decisions: _PrefixVisibleFireDecisions,
		Suggestion: _KLLastShownSuggestion, Render: _PrefixRenderTimer,
		RenderGeneration: _PrefixRenderScheduledGeneration, Queued: _PrefixRenderQueuedWallMs }
	AgentOnly := Mode == "agent-fragment"
	Face := Chr(0x1F600), High := Chr(0xD83D), Low := Chr(0xDE00)
	Mirror(Raw) => LLM_Bridge_FeedCharForPrefix(Raw, Schedule, Focus, (*) => AgentOnly)
	Context() => _PrefixEnsureInputContext(State.Focus["control"])
	Feed(Raw) => _OnPrefixChar(0, Raw, Mirror, Context)
	try {
		HSE_TestReset()
		CategoryEnabled := Map("Hotstrings", false)
		Features := Map()
		ScriptInformation := Map("MagicKey", "★")
		_PrefixBuffer := "", _PrefixFocusedControlToken := State.Focus["control"]
		_PrefixPrivateResidue := false, _PrefixVisibleFireDecisions := [], _KLLastShownSuggestion := ""
		_PrefixRenderTimer := 0, _PrefixRenderScheduledGeneration := -1
		HSE_IdleResetSeconds := Mode == "idle-disabled" ? 0 : 1
		_LLM_Bridge_Active := !AgentOnly
		_LLM_Bridge_AgentFeeding := AgentOnly
		_LLM_Bridge_Buffer := AgentOnly ? "" : "word"
		_LLM_Bridge_AgentBuffer := AgentOnly ? "word" : ""
		Feed(Mode == "complete-context" ? "a" : High)
		Before := State.Scheduled.Length
		AssertEqual("", HSE_Buffer, "the disabled engine has no text to make the idle guard nonempty")
		AssertEqual("", _PrefixBuffer)
		AssertTrue(HSE_StartIsWordBoundary)
		if Mode != "complete-context" {
			AssertEqual("word" . High, AgentOnly ? _LLM_Bridge_AgentBuffer : _LLM_Bridge_Buffer)
			AssertEqual(0, Before, "a high half never arms an observer")
		}
		; Deterministic elapsed time at the real callback's idle decision; no wait.
		_PrefixLastKeyTick := A_TickCount - 2000
		Feed(Mode == "complete-context" ? "b" : Low)
		Buffer := AgentOnly ? _LLM_Bridge_AgentBuffer : _LLM_Bridge_Buffer
		if Mode == "idle-disabled" {
			AssertEqual("word" . Face, Buffer, "disabled idle reset keeps the contiguous scalar")
			AssertEqual(Before + 1, State.Scheduled.Length)
			AssertEqual(Face, _LLM_Bridge_PrefixObserver.Char)
		} else if Mode == "complete-context" {
			AssertEqual("wordab", Buffer, "ordinary complete prediction context keeps the existing idle policy")
			AssertEqual(Before + 1, State.Scheduled.Length)
			AssertEqual("b", _LLM_Bridge_PrefixObserver.Char)
		} else {
			AssertEqual(Low, Buffer, "the orphan low cannot borrow the bridge's retired high or old word")
			AssertEqual(Before, State.Scheduled.Length, "idle-revoked fragments cannot notify a completed scalar")
			AssertFalse(IsObject(_LLM_Bridge_PrefixObserver))
		}
	} finally {
		_PrefixCancelRender()
		HSE_TestReset()
		CategoryEnabled := Saved.Categories, Features := Saved.Features, ScriptInformation := Saved.Information
		HSE_IdleResetSeconds := Saved.Idle, HSE_Suppressed := Saved.Suppressed
		_PrefixBuffer := Saved.Prefix, _PrefixContentGeneration := Saved.Content
		_PrefixInputContextGeneration := Saved.Context, _PrefixFocusedControlToken := Saved.Focus
		_PrefixLastKeyTick := Saved.Tick, _PrefixPrivateResidue := Saved.Private
		_PrefixWatcherSuppressed := Saved.PrefixSuppressed, _PrefixVisibleFireDecisions := Saved.Decisions
		_KLLastShownSuggestion := Saved.Suggestion, _PrefixRenderTimer := Saved.Render
		_PrefixRenderScheduledGeneration := Saved.RenderGeneration, _PrefixRenderQueuedWallMs := Saved.Queued
	}
}

_PBIF_Case(Mode) {
	global _LLM_Bridge_PrefixObserver
	PreviousCritical := Critical("On")
	SavedObserver := _LLM_Bridge_PrefixObserver
	try {
		; Park the exact existing timer owner until every nested port is restored.
		_LLM_Bridge_PrefixObserver := 0
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_PBIF_Sequence.Bind(Mode))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras", false), _LTN_Screen(""), Body)
	} finally {
		_LLM_Bridge_PrefixObserver := SavedObserver
		Critical(PreviousCritical)
	}
}

for _PBIF_Mode in ["prediction-fragment", "agent-fragment", "idle-disabled", "complete-context"]
	Test("Prefix bridge idle: " . _PBIF_Mode . " preserves the input boundary (prefix-bridge-idle-fragment)",
		_PBIF_Case.Bind(_PBIF_Mode))
