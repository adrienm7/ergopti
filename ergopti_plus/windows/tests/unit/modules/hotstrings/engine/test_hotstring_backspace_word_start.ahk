; tests/unit/modules/hotstrings/engine/test_hotstring_backspace_word_start.ahk

; ==============================================================================
; MODULE: Backspace Word-Start Tests
; DESCRIPTION:
; Word-start hotstrings (« c★ » -> « c’est », « j★ » -> « j’ai »,
; « ct★ » -> « c’était ») stayed silent after the user erased what they had
; typed. Four fixed rules, the same on the three drivers:
; 1. The Backspace that erases the last character typed since the buffer
;    started puts the caret back at a word start: « ab », Backspace,
;    Backspace, « c★ » expands. A correction that leaves characters keeps the
;    word open, and a Backspace past the buffer start still makes it unknown.
; 2. Ctrl+Backspace deletes the previous word and always starts a new one;
;    Alt+Backspace and an AltGr Backspace do not.
; 3. A pause before a Backspace keeps the word that Backspace edits.
; 4. A bare Enter in a terminal leaves an empty prompt: a Backspace there
;    deletes nothing and keeps the word start. The typing ledger of 2026-10-21
;    shows the failure this replays in Windows Terminal (Claude Code): Enter,
;    a pause, « c★ » fired, six Backspaces over its five characters, « C »
;    offered nothing. Ctrl+L in a browser and Ctrl+A leave an empty field too.
; ==============================================================================

#Requires AutoHotkey v2.0

global _HBWS_Entries := [["c★", "c’est"], ["j★", "j’ai"], ["ct★", "c’était"]]





; ==================================
; ==================================
; ======= 1/ Field scenarios =======
; ==================================
; ==================================

; Registers the three word-start magic-key entries as their TOML flags do
; (is_word, auto_expand, case conform), and turns the repeat key off: its
; « x★ » doubling would otherwise answer every magic key.
_HBWS_Register() {
	global _HBWS_Entries, HSE_RepeatEnabled, HSE_PersonalInfoCombosEnabled
	HSE_RepeatEnabled := false
	HSE_PersonalInfoCombosEnabled := false
	for _, Entry in _HBWS_Entries
		HSE_RegisterFromTomlFlags(false, "*", Entry[1], Entry[2], Map("OnlyText", true,
			"Category", "magickey", "Section", "replace", "TimeActivationSeconds", 0))
}

; Restores the two engine fallbacks _HBWS_Register turned off.
_HBWS_RestoreFallbacks(Repeat, Combos) {
	global HSE_RepeatEnabled, HSE_PersonalInfoCombosEnabled
	HSE_RepeatEnabled := Repeat
	HSE_PersonalInfoCombosEnabled := Combos
}

; A physical key going down under the modifiers Down (key names).
_HBWS_Key(VK, SC, Down*) {
	global _PrefixModifierIsDown
	Held := Map()
	for _, Name in Down
		Held[Name] := true
	_PrefixModifierIsDown := (Name) => Held.Has(Name)
	try _OnPrefixKeyDown(0, VK, SC)
	finally _PrefixModifierIsDown := (*) => false
}

; Plays one step: a character, or a named key or event.
; @param Step {String} "?" unknown start, "pause", "BS", "^BS", "!BS",
;        "altgrBS", "synBS" (a remap's Backspace), "enter", "^A", "^L",
;        or the character to type.
_HBWS_Play(Step, NoPrefeed) {
	global _PrefixLastKeyTick, _PrefixFocusedControlToken
	switch Step, true {
		case "?": _PrefixInvalidateInputContext(_PrefixFocusedControlToken, false)
		case "pause": _PrefixLastKeyTick := A_TickCount - 60000
		case "BS": _HBWS_Key(0x08, 0x0E)
		case "^BS": _HBWS_Key(0x08, 0x0E, "LControl")
		case "^+BS": _HBWS_Key(0x08, 0x0E, "LControl", "LShift")
		case "!BS": _HBWS_Key(0x08, 0x0E, "LAlt")
		case "altgrBS": _HBWS_Key(0x08, 0x0E, "LControl", "RAlt")
		case "synBS": HS_RunSyntheticInputTransaction("{BackSpace}", () => true)
		case "enter":
			_HBWS_Key(0x0D, 0x1C)
			_OnPrefixChar(0, "`n", NoPrefeed, (*) => true)
		case "^A": _HBWS_Key(0x41, 0x1E, "LControl")
		case "^L": _PrefixHandleCtrlContextChord(0x4C, true, false)
		default: _OnPrefixChar(0, Step, NoPrefeed, (*) => true)
	}
}

; Runs Steps in a text field of Host, then types Probe (a trigger ending in
; ★) and reports whether the magic key was offered and would fire.
; @returns {Object} { Offered, Fired, Trigger }
_HBWS_Field(Steps, Probe, Host := "test.exe") {
	global CategoryEnabled, Features, ScriptInformation, _PrefixFocusedControlToken
	global _PrefixModifierIsDown, _PrefixVisibleFireDecisions, _KLLastShownSuggestion
	global _LLM_Bridge_Active, _LLM_Bridge_AgentFeeding, _HSResolveCache, _HSResolveGen
	global HSE_Buffer, HSE_RepeatEnabled, HSE_PersonalInfoCombosEnabled
	Saved := { Repeat: HSE_RepeatEnabled, Combos: HSE_PersonalInfoCombosEnabled, Categories: CategoryEnabled, Features: Features, Script: ScriptInformation,
		Token: _PrefixFocusedControlToken, Mods: _PrefixModifierIsDown,
		Decisions: _PrefixVisibleFireDecisions, Suggestion: _KLLastShownSuggestion,
		Active: _LLM_Bridge_Active, Agent: _LLM_Bridge_AgentFeeding, Cache: _HSResolveCache }
	NoPrefeed(*) {
	}
	try {
		HSE_TestReset()
		KLHook.prev_app := Host
		KLHook.prev_title := "Field"
		_Stub_SetOutputHost(Host, "Field")
		CategoryEnabled := Map("Hotstrings", true)
		Features := Map()
		ScriptInformation := Map("MagicKey", "★")
		_LLM_Bridge_Active := false
		_LLM_Bridge_AgentFeeding := false
		_PrefixVisibleFireDecisions := []
		_KLLastShownSuggestion := ""
		_HSResolveCache := Map("magickey|replace", { gen: _HSResolveGen, val: { ShowTooltip: false } })
		_PrefixFocusedControlToken := 1
		_PrefixModifierIsDown := (*) => false
		_PrefixSetBuffer("")
		_HBWS_Register()
		for _, Step in Steps
			_HBWS_Play(Step, NoPrefeed)
		Body := SubStr(Probe, 1, StrLen(Probe) - 1)
		Magic := SubStr(Probe, -1)
		loop parse Body
			_HBWS_Play(A_LoopField, NoPrefeed)
		Offered := IsObject(HSE_PreviewNextDecision(HSE_Buffer, Magic))
		Match := HSE_FeedChar(Magic, true)
		return { Offered: Offered, Fired: IsObject(Match), Trigger: IsObject(Match) ? Match.Trigger : "" }
	} finally {
		_PrefixInvalidateDeferredEffects()
		CategoryEnabled := Saved.Categories, Features := Saved.Features
		ScriptInformation := Saved.Script, _PrefixFocusedControlToken := Saved.Token
		_PrefixModifierIsDown := Saved.Mods, _PrefixVisibleFireDecisions := Saved.Decisions
		_KLLastShownSuggestion := Saved.Suggestion, _LLM_Bridge_Active := Saved.Active
		_LLM_Bridge_AgentFeeding := Saved.Agent, _HSResolveCache := Saved.Cache
		_HBWS_RestoreFallbacks(Saved.Repeat, Saved.Combos)
		HSE_TestReset()
		SimulateRegularApp()
		_PrefixSetBuffer("")
	}
}

; Asserts that Probe is both offered and fired after Steps.
_HBWS_Expands(Name, Steps, Probe, Host := "test.exe") {
	Result := _HBWS_Field(Steps, Probe, Host)
	AssertTrue(Result.Offered, Name . ": « " . Probe . " » must be offered")
	AssertTrue(Result.Fired, Name . ": « " . Probe . " » must expand")
}

; Asserts that Probe neither shows nor fires after Steps.
_HBWS_Silent(Name, Steps, Probe, Host := "test.exe") {
	Result := _HBWS_Field(Steps, Probe, Host)
	AssertFalse(Result.Offered, Name . ": « " . Probe . " » must not be offered")
	AssertFalse(Result.Fired, Name . ": « " . Probe . " » must not expand")
}

; Every trigger and its capitalized form, typed with Shift (conform case).
_HBWS_Probes() => ["c★", "C★", "j★", "J★", "ct★", "Ct★"]

_HBWS_EraseAllStartsWord() {
	for _, Probe in _HBWS_Probes() {
		_HBWS_Expands("unknown start, « ab » erased", ["?", "a", "b", "BS", "BS"], Probe)
		_HBWS_Expands("known start, « ab » erased", ["a", "b", "BS", "BS"], Probe)
		_HBWS_Expands("one letter erased", ["?", "x", "BS"], Probe)
		_HBWS_Expands("a remap's Backspaces", ["?", "a", "b", "synBS", "synBS"], Probe)
		_HBWS_Expands("after a word, its letters erased", ["?", "w", " ", "a", "b", "BS", "BS"], Probe)
	}
}

_HBWS_CorrectionKeepsWord() {
	for _, Probe in _HBWS_Probes() {
		_HBWS_Silent("one of two letters erased", ["a", "b", "BS"], Probe)
		_HBWS_Silent("one Backspace past the typed letters", ["a", "b", "BS", "BS", "BS"], Probe)
		_HBWS_Silent("a Backspace with nothing typed", ["BS"], Probe)
	}
}

_HBWS_PauseKeepsTheErasedWord() {
	for _, Probe in _HBWS_Probes() {
		_HBWS_Expands("« ab », a pause, both erased", ["?", "a", "b", "pause", "BS", "BS"], Probe)
		_HBWS_Silent("« ab », a pause, one erased", ["a", "b", "pause", "BS"], Probe)
	}
}

; Ctrl+Backspace on all three layout families; Alt+Backspace and an AltGr
; Backspace (the fake LCtrl with the right Alt) are not the word-delete chord.
_HBWS_CtrlBackspaceOnLayout(Family) {
	for _, Probe in ["c★", "C★", "j★", "Ct★"] {
		_HBWS_Expands(Family . ": Ctrl+Backspace", ["?", "a", "b", "^BS"], Probe)
		_HBWS_Expands(Family . ": Ctrl+Shift+Backspace", ["?", "a", "b", "^+BS"], Probe)
		_HBWS_Silent(Family . ": Alt+Backspace", ["a", "b", "!BS"], Probe)
	}
}

_HBWS_CtrlBackspaceStartsWord() {
	for _, Family in ["altgr", "kana", "qwerty"]
		_HBWS_WithLayout(Family, _HBWS_CtrlBackspaceOnLayout.Bind(Family))
	; AltGr+Backspace types a Backspace on an AltGr layout: one letter goes.
	_HBWS_WithLayout("altgr", () => _HBWS_Silent("altgr: AltGr+Backspace", ["a", "b", "altgrBS"], "c★"))
	_HBWS_WithLayout("altgr", () => _HBWS_Expands("altgr: AltGr+Backspace twice",
		["?", "a", "b", "altgrBS", "altgrBS"], "c★"))
}

; Runs Body under a layout family: "altgr" (AZERTY-style AltGr, a fake LCtrl
; with the right Alt), "kana" (AltGr is VK_OEM_8) or "qwerty" (no AltGr).
_HBWS_WithLayout(Family, Body) {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
	SavedKana := _ALTGR_KANA_FIXUP
	HadProbe := IsSet(_ALTGR_LAYOUT_PROBE)
	if HadProbe
		SavedProbe := _ALTGR_LAYOUT_PROBE
	try {
		_ALTGR_KANA_FIXUP := (Family == "kana")
		_ALTGR_LAYOUT_PROBE := Map("altgr_level", Family == "altgr")
		Body()
	} finally {
		_ALTGR_KANA_FIXUP := SavedKana
		if HadProbe
			_ALTGR_LAYOUT_PROBE := SavedProbe
	}
}

; A browser address bar after Ctrl+L, and any field after Ctrl+A: the field
; is empty once its selection is gone, so one Backspace too many deletes
; nothing. A plain field gives no such promise.
_HBWS_EmptyFieldAfterSelection() {
	for _, Probe in ["c★", "C★", "J★"] {
		_HBWS_Expands("address bar, Ctrl+L, Backspace", ["^L", "BS"], Probe, "firefox.exe")
		_HBWS_Expands("address bar, Ctrl+L, « ab », three Backspaces",
			["^L", "a", "b", "BS", "BS", "BS"], Probe, "chrome.exe")
		_HBWS_Expands("Ctrl+A, Backspace, Backspace", ["^A", "BS", "BS"], Probe)
		_HBWS_Silent("a click-free field, three Backspaces", ["a", "b", "BS", "BS", "BS"], Probe, "firefox.exe")
	}
}

Test("backspace word start: erasing every typed letter starts a word (bs-word-start)", _HBWS_EraseAllStartsWord)
Test("backspace word start: a correction keeps the word (bs-word-start)", _HBWS_CorrectionKeepsWord)
Test("backspace word start: a pause keeps the word the Backspace edits (bs-word-start)", _HBWS_PauseKeepsTheErasedWord)
Test("backspace word start: Ctrl+Backspace starts a word on every layout (bs-word-start)", _HBWS_CtrlBackspaceStartsWord)
Test("backspace word start: Ctrl+L and Ctrl+A leave an empty field (bs-word-start)", _HBWS_EmptyFieldAfterSelection)





; =====================================
; =====================================
; ======= 2/ Terminal scenarios =======
; =====================================
; =====================================

; Plays Steps in Windows Terminal (Claude Code) through the production
; callbacks and the paced terminal output owner, then returns the screen.
; Steps as for _HBWS_Play; "★" completes a trigger, whose paced expansion is
; awaited before the next step.
_HBWS_Terminal(Steps) {
	global CategoryEnabled, Features, ScriptInformation, _SendHook
	global _PrefixBuffer, _PrefixFocusedControlToken, _PrefixVisibleFireDecisions
	global _LLM_Bridge_Active, _LLM_Bridge_AgentFeeding, _KLLastShownSuggestion
	global HSE_Buffer, _HSE_TerminalOwner, _HSE_TerminalReplayPending, _PrefixModifierIsDown
	global _HSResolveCache, _HSResolveGen, HSE_RepeatEnabled, HSE_PersonalInfoCombosEnabled
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerPort, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerPendingStopRecovery, _LLM_NavEventOwnerLifecycleQuiesced
	Saved := { Repeat: HSE_RepeatEnabled, Combos: HSE_PersonalInfoCombosEnabled,
		Categories: CategoryEnabled, Features: Features, Script: ScriptInformation,
		Send: _SendHook, Active: _LLM_Bridge_Active, Agent: _LLM_Bridge_AgentFeeding,
		Decisions: _PrefixVisibleFireDecisions, Suggestion: _KLLastShownSuggestion,
		ResolverCache: _HSResolveCache, NavStarted: _LLM_NavEventOwnerStarted,
		Token: _PrefixFocusedControlToken, Mods: _PrefixModifierIsDown,
		NavPort: _LLM_NavEventOwnerPort, NavFlags: [_LLM_NavEventOwnerQuarantined,
			_LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStartRollbackPending,
			_LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending,
			_LLM_NavEventOwnerPendingStopRecovery, _LLM_NavEventOwnerLifecycleQuiesced] }
	State := { Screen: "", Sends: 0, Done: false, Offers: [] }
	NoPrefeed(*) {
	}
	Capture(Name, Args*) {
		AssertEqual("SendTerminalResult", Name, "the terminal uses the paced owner")
		Payload := Args[1]
		Erased := 0
		while SubStr(Payload, 1, 11) == "{BackSpace}" {
			Erased += 1
			Payload := SubStr(Payload, 12)
		}
		AssertEqual("{Text}", SubStr(Payload, 1, 6), "the replacement is literal text")
		State.Screen := SubStr(State.Screen, 1, Max(0, StrLen(State.Screen) - Erased))
			. SubStr(Payload, 7)
		State.Sends += 1
		return true
	}
	Begin(Token) => 1
	Release(Committed, Token) {
		SetTimer(() => State.Done := true, -5)
		return 1
	}
	Snapshot(Token) => Map("token", Token, "phase", 0, "queued", 0,
		"replayed", 0, "last_os_error", 0, "release_kind", 0)
	try {
		HSE_TestReset()
		KLHook.prev_app := "WindowsTerminal.exe"
		KLHook.prev_title := "Claude Code"
		_Stub_SetOutputHost("WindowsTerminal.exe", "Claude Code")
		CategoryEnabled := Map("Hotstrings", true)
		Features := Map()
		ScriptInformation := Map("MagicKey", "★")
		_LLM_Bridge_Active := false
		_LLM_Bridge_AgentFeeding := false
		_PrefixBuffer := ""
		_PrefixFocusedControlToken := 1
		_PrefixModifierIsDown := (*) => false
		_PrefixVisibleFireDecisions := []
		_KLLastShownSuggestion := ""
		_HSResolveCache := Map("magickey|replace", { gen: _HSResolveGen, val: { ShowTooltip: false } })
		_SendHook := Capture
		_LLM_NavEventOwnerStarted := true
		_LLM_NavEventOwnerQuarantined := false, _LLM_NavEventOwnerStarting := false
		_LLM_NavEventOwnerStartRollbackPending := false, _LLM_NavEventOwnerStopping := false
		_LLM_NavEventOwnerStopPending := false, _LLM_NavEventOwnerPendingStopRecovery := false
		_LLM_NavEventOwnerLifecycleQuiesced := false
		_LLM_NavEventOwnerPort := Map("begin_terminal", Begin,
			"commit_terminal", Release.Bind(true), "abort_terminal", Release.Bind(false),
			"get_terminal", Snapshot)
		_HBWS_Register()
		for _, Step in Steps {
			if (Step == "★") {
				; What the bubble offers for the magic key on the current buffer.
				State.Offers.Push(IsObject(HSE_PreviewNextDecision(HSE_Buffer, "★")))
				State.Done := false
				SendsBefore := State.Sends
				State.Screen .= "★"
				_OnPrefixChar(0, "★", NoPrefeed, (*) => true)
				if (_HSE_TerminalOwner is Map) {
					Started := A_TickCount
					while !State.Done && ((A_TickCount - Started) & 0xFFFFFFFF) < 1000
						Sleep(-1)
				}
				continue
			}
			if (Step == "BS" or Step == "^BS") {
				Removed := (Step == "BS") ? 1 : StrLen(State.Screen)
				State.Screen := SubStr(State.Screen, 1, Max(0, StrLen(State.Screen) - Removed))
			} else if (Step == "enter") {
				State.Screen := ""
			} else if (StrLen(Step) == 1 and Step != "?") {
				State.Screen .= Step
			}
			_HBWS_Play(Step, NoPrefeed)
		}
		return State
	} finally {
		_PrefixInvalidateDeferredEffects()
		_HSE_TerminalOwner := 0
		_HSE_TerminalReplayPending := 0
		_HBWS_RestoreFallbacks(Saved.Repeat, Saved.Combos)
		HSE_TestReset()
		CategoryEnabled := Saved.Categories, Features := Saved.Features
		ScriptInformation := Saved.Script, _SendHook := Saved.Send
		_LLM_Bridge_Active := Saved.Active, _LLM_Bridge_AgentFeeding := Saved.Agent
		_PrefixVisibleFireDecisions := Saved.Decisions, _KLLastShownSuggestion := Saved.Suggestion
		_HSResolveCache := Saved.ResolverCache, _LLM_NavEventOwnerStarted := Saved.NavStarted
		_LLM_NavEventOwnerPort := Saved.NavPort, _PrefixFocusedControlToken := Saved.Token
		_PrefixModifierIsDown := Saved.Mods
		_LLM_NavEventOwnerQuarantined := Saved.NavFlags[1]
		_LLM_NavEventOwnerStarting := Saved.NavFlags[2]
		_LLM_NavEventOwnerStartRollbackPending := Saved.NavFlags[3]
		_LLM_NavEventOwnerStopping := Saved.NavFlags[4]
		_LLM_NavEventOwnerStopPending := Saved.NavFlags[5]
		_LLM_NavEventOwnerPendingStopRecovery := Saved.NavFlags[6]
		_LLM_NavEventOwnerLifecycleQuiesced := Saved.NavFlags[7]
		SimulateRegularApp()
		_PrefixSetBuffer("")
	}
}

; The ledger of 2026-10-21, key classes only: Enter submitted the prompt, a
; long pause, « c★ » expanded, Backspace over every character and one more,
; then « C★ ». The extra Backspace hit the empty prompt and deleted nothing.
_HBWS_TerminalLedgerReplay() {
	Steps := ["enter", "pause", "c", "★"]
	loop 6
		Steps.Push("BS")
	Steps.Push("C", "★")
	State := _HBWS_Terminal(Steps)
	AssertEqual(2, State.Offers.Length)
	AssertTrue(State.Offers[1], "the first « c★ » is offered")
	AssertTrue(State.Offers[2], "« C★ » after the over-long erase must be offered")
	AssertEqual("C’est", State.Screen, "« C★ » must expand at the start of the empty prompt")
}

; The scenario as the maintainer typed it, for each trigger and its capital.
_HBWS_TerminalEraseAll() {
	for _, Entry in [["c", "c’est"], ["C", "C’est"], ["j", "j’ai"], ["J", "J’ai"],
			["ct", "c’était"], ["Ct", "C’était"]] {
		Steps := ["enter", "a", "b", "BS", "BS"]
		loop parse Entry[1]
			Steps.Push(A_LoopField)
		Steps.Push("★")
		State := _HBWS_Terminal(Steps)
		AssertTrue(State.Offers[1], Entry[1] . "★ is offered after « ab » was erased")
		AssertEqual(Entry[2], State.Screen, Entry[1] . "★ expands after « ab » was erased")
		Steps := ["enter", "a", "b", "^BS"]
		loop parse Entry[1]
			Steps.Push(A_LoopField)
		Steps.Push("★")
		State := _HBWS_Terminal(Steps)
		AssertEqual(Entry[2], State.Screen, Entry[1] . "★ expands after Ctrl+Backspace")
	}
}

; A correction in the terminal keeps the word: « ab », Backspace, « c★ »
; stays « ac★ ». Shift+Enter (a newline in the TUI) promises no empty line.
_HBWS_TerminalCorrectionKeepsWord() {
	State := _HBWS_Terminal(["enter", "a", "b", "BS", "c", "★"])
	AssertFalse(State.Offers[1], "« ac★ » is mid-word")
	AssertEqual("ac★", State.Screen, "nothing expands inside a word")
}

Test("backspace word start: terminal ledger replay of 2026-10-21 (bs-word-start)", _HBWS_TerminalLedgerReplay)
Test("backspace word start: terminal, every trigger after an erase (bs-word-start)", _HBWS_TerminalEraseAll)
Test("backspace word start: terminal correction keeps the word (bs-word-start)", _HBWS_TerminalCorrectionKeepsWord)
