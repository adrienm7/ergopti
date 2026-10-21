; tests/unit/modules/hotstrings/prefix/test_prefix_bridge_shortcut_fragment.ahk

; ==============================================================================
; MODULE: Dispatcher Shortcut Fragment Regressions
; DESCRIPTION:
; Drives the real early-dispatcher key callback and bridge character worker.
; Unknown shortcut edits cannot join surrogate halves across the caret boundary.
; ==============================================================================

#Requires AutoHotkey v2.0

_PBSF_Sequence(Mode, State, Schedule, Focus) {
	global _PrefixInputHook, _PrefixModifierIsDown, _PrefixFocusedControlToken
	global _PrefixBuffer, _PrefixWatcherSuppressed, _PrefixLastKeyTick
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE, HSE_Suppressed
	global _LLM_Bridge_Buffer, _LLM_Agent_Auto, _LLM_Bridge_LastLogTick
	Saved := { LogTick: _LLM_Bridge_LastLogTick, Hook: _PrefixInputHook, Dispatcher: HookDispatcher._ih,
		Modifiers: _PrefixModifierIsDown, Focus: _PrefixFocusedControlToken,
		Prefix: _PrefixBuffer, PrefixSuppressed: _PrefixWatcherSuppressed,
		Tick: _PrefixLastKeyTick, Kana: _ALTGR_KANA_FIXUP,
		Layout: _ALTGR_LAYOUT_PROBE, Suppressed: HSE_Suppressed }
	Current := {}, Retired := {}, Face := Chr(0x1F600)
	High := Chr(0xD83D), Low := Chr(0xDE00)
	Modifiers := Map()
	if Mode != "plain-packet"
		Modifiers["LControl"] := true
	if Mode == "altgr-text"
		Modifiers["RAlt"] := true
	try {
		HSE_TestReset()
		_PrefixInputHook := 0, HookDispatcher._ih := Current
		_PrefixBuffer := "", _PrefixFocusedControlToken := State.Focus["control"]
		_PrefixModifierIsDown := (Name) => Modifiers.Get(Name, false)
		_ALTGR_KANA_FIXUP := false
		_ALTGR_LAYOUT_PROBE := Map("altgr_level", true)
		_LLM_Bridge_Buffer := "word"
		if Mode != "complete-context" {
			LLM_Bridge_OnChar(High)
			AssertEqual("word" . High, _LLM_Bridge_Buffer, "the real character worker retains its raw high once")
			AssertEqual(0, _LLM_Agent_Auto["timer"], "a high fragment cannot notify the agent")
		}
		VK := Mode == "ctrl-backspace" ? 0x08 : (Mode == "plain-packet" ? 0xE7
			: (Mode == "modifier-only" ? 0xA2 : 0x56))
		_LLM_Bridge_OnDispatcherKey(Mode == "retired-hook" ? Retired : Current, VK, 0)
		Revoked := Mode == "ctrl-paste" || Mode == "ctrl-backspace"
		if Revoked
			AssertEqual("", _LLM_Bridge_Buffer, "the current shortcut retires the incomplete edit context")
		else
			AssertEqual(Mode == "complete-context" ? "word" : "word" . High, _LLM_Bridge_Buffer,
				"ordinary typing, modifiers, retired hooks and complete context retain their existing policy")
		LLM_Bridge_OnChar(Mode == "complete-context" ? "a" : Low)
		if Revoked {
			AssertEqual(Low, _LLM_Bridge_Buffer, "a later orphan cannot borrow the high from before the shortcut")
			AssertEqual(0, _LLM_Agent_Auto["timer"], "no completed scalar is published across the unknown edit")
		} else {
			AssertEqual(Mode == "complete-context" ? "worda" : "word" . Face, _LLM_Bridge_Buffer)
			AssertTrue(IsObject(_LLM_Agent_Auto["timer"]), "the valid complete context still reaches the real agent pause")
		}
	} finally {
		HSE_TestReset()
		_PrefixInputHook := Saved.Hook, HookDispatcher._ih := Saved.Dispatcher
		_PrefixModifierIsDown := Saved.Modifiers, _PrefixFocusedControlToken := Saved.Focus
		_PrefixBuffer := Saved.Prefix, _PrefixWatcherSuppressed := Saved.PrefixSuppressed
		_PrefixLastKeyTick := Saved.Tick, _ALTGR_KANA_FIXUP := Saved.Kana
		_ALTGR_LAYOUT_PROBE := Saved.Layout, HSE_Suppressed := Saved.Suppressed
		_LLM_Bridge_LastLogTick := Saved.LogTick
	}
}

_PBSF_Case(Mode) {
	global _LLM_Bridge_PrefixObserver
	PreviousCritical := Critical("On")
	SavedObserver := _LLM_Bridge_PrefixObserver
	try {
		_LLM_Bridge_PrefixObserver := 0
		Body(Fx, Lines, Sent) => _PCA_WithObserverFixture(_PBSF_Sequence.Bind(Mode))
		_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras", false), _LTN_Screen(""), Body)
	} finally {
		_LLM_Bridge_PrefixObserver := SavedObserver
		Critical(PreviousCritical)
	}
}

for _PBSF_Mode in ["ctrl-paste", "ctrl-backspace", "plain-packet", "altgr-text",
	"modifier-only", "complete-context", "retired-hook"]
	Test("Dispatcher fragment boundary: " . _PBSF_Mode . " preserves shortcut ownership (bridge-shortcut-fragment)",
		_PBSF_Case.Bind(_PBSF_Mode))
