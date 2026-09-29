; static/ergopti_plus/windows/tests/unit/test_llm_tone.ahk

; ==============================================================================
; MODULE: Tone Ladder Actions (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/tone_vectors.json, which the shared Lua
; module (macOS, Linux) replays too, through modules/llm/tone.ahk, then drives
; the four tone actions through the real code path with only the outer
; boundaries faked: the selection reader, the focus probe, the network (the
; engine's remote transport, answered with an OpenAI-dialect body the real
; classifier reads) and the keyboard (the SendInput primitive TextSender emits
; through). Selection -> action -> request (ladder prompt, the ORIGINAL text as
; PREFIX and TAIL, budget) -> answer -> text typed over the selection -> the
; same text selected again -> memory.
;
; The network, keyboard and log fixtures are those of
; test_llm_prompt_prediction.ahk (_LPP_Run, _LPP_WithKeyboard, _LPP_Answer).
;
; ROOT CAUSE ENCODED:
; Changing the register of a text meant copying it into a chat and back. The
; tone actions rewrite the selection in place, one register per step, always
; from the original text so repeated steps never drift from what was written.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= 1/ Shared corpus (tone_vectors) =======
; ===============================================
; ===============================================

_LTN_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\tone_vectors.json"
	AssertTrue(FileExist(Path) != "", "the tone corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_LTN_StepVectors() {
	Checked := 0
	for Vector in _LTN_Corpus()["step_vectors"] {
		AssertEqual(Vector.Get("expected", 0),
			LLM_Tone_Step(Vector["level"], Vector["direction"], Vector["cycle"] ? true : false),
			Vector["id"] . ": next level")
		Checked += 1
	}
	AssertTrue(Checked >= 7, "expected at least 7 step vectors, found " . Checked)
}
Test("LLM tone: the ladder step replays the shared corpus", _LTN_StepVectors)

_LTN_PlanVectors() {
	Checked := 0
	for Vector in _LTN_Corpus()["plan_vectors"] {
		Plan := LLM_Tone_Plan(Vector["selection"], Vector.Get("memory", ""),
			Vector["direction"], Vector["cycle"] ? true : false, &Reason)
		if Vector.Has("expected") {
			Expected := Vector["expected"]
			AssertTrue(Plan is Map, Vector["id"] . ": a plan is made")
			AssertEqual(Expected["source"], Plan["source"], Vector["id"] . ": source")
			AssertEqual(Expected["level"], Plan["level"], Vector["id"] . ": level")
			AssertEqual(Expected["profile_id"], Plan["profile_id"], Vector["id"] . ": profile")
			AssertEqual("", Reason, Vector["id"] . ": no reason")
		} else {
			AssertEqual("", Plan, Vector["id"] . ": nothing to do")
			AssertEqual(Vector["reason"], Reason, Vector["id"] . ": reason")
		}
		Checked += 1
	}
	AssertTrue(Checked >= 8, "expected at least 8 plan vectors, found " . Checked)
}
Test("LLM tone: the step plan replays the shared corpus", _LTN_PlanVectors)

_LTN_ExtractVectors() {
	Checked := 0
	for Vector in _LTN_Corpus()["extract_vectors"] {
		AssertEqual(Vector.Get("expected", ""), LLM_Tone_Extract(Vector["block"]),
			Vector["id"] . ": extracted rewrite")
		Checked += 1
	}
	AssertTrue(Checked >= 10, "expected at least 10 extract vectors, found " . Checked)
}
Test("LLM tone: reading the answer replays the shared corpus", _LTN_ExtractVectors)

_LTN_LadderIsBuiltIn() {
	global LLM_TONE_LADDER
	for Id in LLM_TONE_LADDER {
		AssertTrue(LLM_Option_IsBuiltinProfileId(Id), Id . " must be a built-in profile id")
		AssertTrue(LLM_Rewrite_IsRewriteProfile(LLM_FindProfile(Id)), Id . " must be a rewrite profile")
	}
	AssertThrows(() => LLM_Tone_Step(5, LLM_TONE_MORE_FORMAL, false), "a level past the ladder is a caller bug")
	AssertThrows(() => LLM_Tone_Step(2, 2, false), "a direction is one step")
}
Test("LLM tone: the ladder names the shipped rewrite built-ins", _LTN_LadderIsBuiltIn)





; ===================================================
; ===================================================
; ======= 2/ Fixture: selection, focus, state =======
; ===================================================
; ===================================================

; The fake screen: the text a copy of the selection returns, and the window
; identity the focus probe reports.
_LTN_Screen(Selection) {
	return { Selection: Selection, Focus: "window-1", Reads: 0 }
}

; The fake selection reader: GetSelectionAsync's contract, answered at once.
_LTN_ReadSelection(Screen, OnReady) {
	Screen.Reads += 1
	OnReady.Call(Screen.Selection)
	return true
}

; Runs Body(Calls, Lines, Sent) with the prompt-prediction fixture, the fake
; screen as selection and focus, and a fresh tone memory; everything is put
; back afterwards.
_LTN_Run(Menu, Screen, Body) {
	global _LLM_Tone_ReadSelection, _LLM_Tone_FocusProbe, _LLM_Tone_Memory, _LLM_Tone_Generation
	Saved := {
		Reader: _LLM_Tone_ReadSelection, Probe: _LLM_Tone_FocusProbe,
		Memory: _LLM_Tone_Memory, Generation: _LLM_Tone_Generation
	}
	try {
		_LLM_Tone_ReadSelection := _LTN_ReadSelection.Bind(Screen)
		_LLM_Tone_FocusProbe := () => Screen.Focus
		_LLM_Tone_Memory := ""
		_LPP_Run(Menu, "", _WithNetwork)
	} finally {
		_LLM_Tone_ReadSelection := Saved.Reader
		_LLM_Tone_FocusProbe := Saved.Probe
		_LLM_Tone_Memory := Saved.Memory
		_LLM_Tone_Generation := Saved.Generation
	}
	_WithNetwork(Calls, Lines) {
		_LPP_WithKeyboard(_WithKeyboard)
		_WithKeyboard(Sent) {
			Body.Call(Calls, Lines, Sent)
		}
	}
}

; Asserts that a recorded request rewrites Source with the ladder profile.
_LTN_AssertRequest(Call, ProfileId, Source) {
	AssertEqual(LLM_ResolveSystemPrompt(LLM_FindProfile(ProfileId), 1, 1, 5, "fr"), Call["system"],
		"the request runs " . ProfileId)
	AssertEqual(Source, Call["ctx"], "the PREFIX is the text to rewrite")
	AssertEqual(Source, Call["tail"], "the TAIL is the text to rewrite")
	AssertEqual(LLM_Rewrite_MaxTokens(Source), Call["max_tokens"], "the budget is the rewrite budget")
	Request := _LLMRemote_BuildRequestContext(Call["system"], Call["ctx"], Call["tail"])
	AssertEqual('PREFIX: "' . Source . '"`nTAIL: "' . Source . '"', Request["user"],
		"the user turn names the text as PREFIX and TAIL")
}





; =========================================================
; =========================================================
; ======= 3/ The ladder, end to end, on a selection =======
; =========================================================
; =========================================================

_LTN_LadderEndToEnd() {
	Screen := _LTN_Screen("merci pour ton aide")
	_LTN_Run(_LPP_Menu(), Screen, _Body)
	_Body(Calls, Lines, Sent) {
		global _LLM_Tone_Memory, _LLM_Menu
		Original := "merci pour ton aide"
		Formal := "Merci pour votre aide."
		VeryFormal := "Je vous remercie vivement pour votre aide."

		; 1. More formal: neutral -> formal, from the selection itself.
		AssertTrue(GestureInvokeAction("llm_tone_more_formal"), "the action reads the selection")
		AssertEqual(1, Screen.Reads, "the selection is read once")
		AssertEqual(1, Calls.Length, "one request is sent")
		_LTN_AssertRequest(Calls[1], "tone_formal", Original)
		_LPP_Answer(Calls[1], "REWRITE: " . Formal)
		AssertEqual(2, Sent.Length, "the text, then the selection")
		AssertEqual("{Text}" . Formal, Sent[1], "the rewrite is typed over the selection")
		AssertEqual("+{Left " . StrLen(Formal) . "}", Sent[2], "exactly the typed text is selected again")
		AssertTrue(_LLM_Tone_Memory is Map, "the rewrite is remembered")
		AssertEqual(Original, _LLM_Tone_Memory["source"], "with its original")
		AssertEqual(Formal, _LLM_Tone_Memory["output"], "and the text now selected")
		AssertEqual(3, _LLM_Tone_Memory["level"], "at the formal level")

		; 2. More formal again, on the re-selected rewrite: the ORIGINAL is rewritten.
		Screen.Selection := Formal
		AssertTrue(GestureInvokeAction("llm_tone_more_formal"), "the second step runs")
		AssertEqual(2, Calls.Length, "a second request is sent")
		_LTN_AssertRequest(Calls[2], "tone_very_formal", Original)
		_LPP_Answer(Calls[2], "REWRITE: " . VeryFormal)
		AssertEqual("{Text}" . VeryFormal, Sent[3], "the very formal rewrite replaces the formal one")
		AssertEqual("+{Left " . StrLen(VeryFormal) . "}", Sent[4], "and is selected again")
		AssertEqual(4, _LLM_Tone_Memory["level"], "at the very formal level")
		AssertEqual(Original, _LLM_Tone_Memory["source"], "still tied to the original")

		; 3. Past the top without cycling: a notice, no request.
		Screen.Selection := VeryFormal
		GestureInvokeAction("llm_tone_more_formal")
		AssertEqual(2, Calls.Length, "the end of the ladder sends nothing")
		AssertEqual(4, Sent.Length, "and types nothing")
		AssertEqual(t("llm.tone.most_formal"), _LPP_PendingNotice(), "the user is told it is the top")

		; 4. Past the top with cycling: back to familiar, from the original.
		AssertTrue(GestureInvokeAction("llm_tone_more_formal_cycle"), "the cycling step runs")
		AssertEqual(3, Calls.Length, "the cycle sends a request")
		_LTN_AssertRequest(Calls[3], "tone_familiar", Original)

		AssertEqual("advanced", _LLM_Menu["profile_id"], "the active profile is untouched")
	}
}
Test("LLM tone: the ladder rewrites the original, replaces and re-selects the selection",
	_LTN_LadderEndToEnd)

; One Left arrow moves over a whole emoji: the re-selection counts codepoints.
_LTN_ReselectCountsCodepoints() {
	_LTN_Run(_LPP_Menu(), _LTN_Screen("merci"), _Body)
	_Body(Calls, Lines, Sent) {
		Rewrite := "Merci " . Chr(0x1F600)
		AssertEqual(8, StrLen(Rewrite), "precondition: the emoji is two UTF-16 units")
		GestureInvokeAction("llm_tone_more_familiar")
		_LTN_AssertRequest(Calls[1], "tone_familiar", "merci")
		_LPP_Answer(Calls[1], "REWRITE: " . Rewrite)
		AssertEqual("+{Left 7}", Sent[2], "seven characters, the emoji counted once")
	}
}
Test("LLM tone: the re-selection counts characters, not UTF-16 units",
	_LTN_ReselectCountsCodepoints)





; ===================================================
; ===================================================
; ======= 4/ Refusals, focus and supersession =======
; ===================================================
; ===================================================

_LTN_EmptySelectionDoesNothing() {
	_LTN_Run(_LPP_Menu(), _LTN_Screen("  `n"), _Body)
	_Body(Calls, Lines, Sent) {
		GestureInvokeAction("llm_tone_more_formal_cycle")
		AssertEqual(0, Calls.Length, "a blank selection sends nothing")
		AssertEqual(0, Sent.Length, "and types nothing")
	}
}
Test("LLM tone: nothing selected, nothing happens", _LTN_EmptySelectionDoesNothing)

_LTN_AiOffIsRefused() {
	_LTN_Run(_LPP_Menu(false), _LTN_Screen("merci pour ton aide"), _Body)
	_Body(Calls, Lines, Sent) {
		GestureInvokeAction("llm_tone_more_formal")
		AssertEqual(0, Calls.Length, "an AI switched off sends nothing")
		AssertEqual(t("llm.manual_prediction.disabled"), _LPP_PendingNotice(),
			"with the notice llm_generate_prediction shows")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "Manual prediction refused (disabled)"),
			"the refusal is logged with its reason")
	}
}
Test("LLM tone: the manual-prediction refusals apply", _LTN_AiOffIsRefused)

_LTN_FocusChangeDropsTheAnswer() {
	Screen := _LTN_Screen("merci pour ton aide")
	_LTN_Run(_LPP_Menu(), Screen, _Body)
	_Body(Calls, Lines, Sent) {
		global _LLM_Tone_Memory
		GestureInvokeAction("llm_tone_more_formal")
		AssertEqual(1, Calls.Length, "the request is sent")
		Screen.Focus := "window-2"
		_LPP_Answer(Calls[1], "REWRITE: Merci pour votre aide.")
		AssertEqual(0, Sent.Length, "nothing is typed into another window")
		AssertEqual("", _LLM_Tone_Memory, "and nothing is remembered")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "focus moved"), "the drop is logged")
		AssertFalse(_LLM_Tone_FocusUnchanged(""), "an unknown focus never admits the output")
	}
}
Test("LLM tone: an answer is never typed after the focus moved", _LTN_FocusChangeDropsTheAnswer)

_LTN_NewStepSupersedesTheOld() {
	Screen := _LTN_Screen("merci pour ton aide")
	_LTN_Run(_LPP_Menu(), Screen, _Body)
	_Body(Calls, Lines, Sent) {
		GestureInvokeAction("llm_tone_more_formal")
		GestureInvokeAction("llm_tone_more_familiar")
		AssertEqual(2, Calls.Length, "both steps sent a request")
		_LTN_AssertRequest(Calls[2], "tone_familiar", "merci pour ton aide")
		_LPP_Answer(Calls[1], "REWRITE: Merci pour votre aide.")
		AssertEqual(0, Sent.Length, "the superseded answer is ignored")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "superseded"), "and the drop is logged")
		_LPP_Answer(Calls[2], "REWRITE: Merci pour ton aide !")
		AssertEqual("{Text}Merci pour ton aide !", Sent[1], "the newest answer is typed")
	}
}
Test("LLM tone: a new step supersedes the one in flight", _LTN_NewStepSupersedesTheOld)

_LTN_AnswerWithoutRewriteIsDropped() {
	_LTN_Run(_LPP_Menu(), _LTN_Screen("merci pour ton aide"), _Body)
	_Body(Calls, Lines, Sent) {
		GestureInvokeAction("llm_tone_more_formal")
		_LPP_Answer(Calls[1], "Merci pour votre aide.")
		AssertEqual(0, Sent.Length, "an answer without the rewrite tag is not typed")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "holds no rewrite"), "the drop is logged")
	}
}
Test("LLM tone: an answer without a rewrite is dropped", _LTN_AnswerWithoutRewriteIsDropped)

_LTN_HotkeysSkipTheLadder() {
	UserProfiles := []
	loop 5
		UserProfiles.Push(Map("id", "user_mine_" . A_Index))
	Order := LLM_Menu_GetHotkeyProfileOrder(Map("user_profiles", UserProfiles))
	for ToneId in LLM_TONE_LADDER {
		for Id in Order
			Assert(Id != ToneId, "the tone profile " . ToneId . " must not take a Ctrl+<n> hotkey")
	}
	AssertEqual(LLM_PROFILE_HOTKEY_LIMIT, Order.Length, "the hotkeys still fill the number row")
	AssertEqual("user_mine_1", Order[LLM_PROFILE_BUILTIN_ORDER.Length - LLM_TONE_LADDER.Length + 1],
		"the first custom profile follows the prediction built-ins")
}
Test("LLM tone: the ladder profiles leave the Ctrl+<n> hotkeys to prediction prompts",
	_LTN_HotkeysSkipTheLadder)
