; static/ergopti_plus/windows/tests/unit/test_llm_live_mode.ahk

; ==============================================================================
; MODULE: AI Live Mode (Windows)
; DESCRIPTION:
; Drives the retained llm_live_prompt_toggle and prompt-provider APIs through the
; real code path, with the network (the engine's remote transport) and the
; keyboard (the SendInput primitive) faked as in test_llm_prompt_prediction.ahk,
; whose fixture this file reuses. Toggle -> typing -> live request (prompt,
; sentence, debounce, word floor) -> answer -> tooltip -> accept, then every
; conflict rule with the hotstring tooltips and the explicit AI actions.
;
; ROOT CAUSE ENCODED:
; Live translation must redirect the one automatic typing trigger rather than
; add a second pipeline: a second pipeline would race the ordinary one for the
; tooltip and outlive a pause. Every rule below is the trigger's, not a copy.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ Shared fixture =======
; =================================
; =================================

global LLV_SENTENCE := "on se voit demain"
global LLV_BINDING := "keyboard__live_test"

; The menu of test_llm_prompt_prediction.ahk, and an engine whose debounce and
; minimum word count differ from live.json's so each request shows whose it is.
; Body(Calls, Lines, Builds) runs with live mode off, the bridge active, no
; hotstring tooltip and a menu-build recorder; all of it is put back after.
_LLV_Run(Buffer, Body, Menu := unset) {
	_LPP_Run(IsSet(Menu) ? Menu : _LPP_Menu(), Buffer, _Inner, true)
	_Inner(Calls, Lines) {
		global _LLM_Live, _LLM_Bridge_Active, _LLM_MenuBuildCoordinator, _LLM_Engine
		global _LLM_Bridge_ReadLiveFocus
		global _TooltipActiveSurface, _LLM_AcceptInProgress
		global _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading
		global _Stub_LlmTooltipText, _Stub_LlmPresentedRecord
		global _SR_ActiveTasks
		Saved := {
			Live: _LLM_Live, Active: _LLM_Bridge_Active, Focus: _LLM_Bridge_ReadLiveFocus,
			Coordinator: _LLM_MenuBuildCoordinator, Surface: _TooltipActiveSurface,
			Accepting: _LLM_AcceptInProgress,
			Visible: _Stub_LlmTooltipVisible, Loading: _Stub_LlmTooltipLoading,
			Text: _Stub_LlmTooltipText, Record: _Stub_LlmPresentedRecord,
			Tasks: _SR_ActiveTasks.Count
		}
		Builds := []
		try {
			LLM_Engine_CancelTimer()
			_LLM_Live := Map("active", false, "profile_id", "", "num_predictions", 0)
			_LLM_Bridge_Active := true
			; This scenario owns its typing target; the hosted desktop need not have focus.
			_LLM_Bridge_ReadLiveFocus := () => Map("hwnd", 101, "control", 102)
			_LLM_MenuBuildCoordinator := LLMMenuBuildCoordinator(
				(*) => (Builds.Push(1), 1), (*) => false)
			_TooltipActiveSurface := 0
			_LLM_AcceptInProgress := false
			_Stub_LlmTooltipVisible := false
			_Stub_LlmTooltipLoading := false
			_Stub_LlmTooltipText := ""
			_Stub_LlmPresentedRecord := 0
			_LLM_Engine["debounce_ms"] := 700
			_LLM_Engine["min_words"] := 8
			_LLM_Engine["after_hotstring"] := false
			_LLM_Engine["instant_on_word_end"] := false
			Body(Calls, Lines, Builds)
		} finally {
			LLM_Bridge_CancelPrefixObserver()
			LLM_Engine_CancelTimer()
			_Stub_LlmPresentedRecord := Saved.Record
			_Stub_LlmTooltipText := Saved.Text
			_Stub_LlmTooltipLoading := Saved.Loading
			_Stub_LlmTooltipVisible := Saved.Visible
			_LLM_AcceptInProgress := Saved.Accepting
			_TooltipActiveSurface := Saved.Surface
			_LLM_MenuBuildCoordinator := Saved.Coordinator
			_LLM_Bridge_ReadLiveFocus := Saved.Focus
			_LLM_Bridge_Active := Saved.Active
			_LLM_Live := Saved.Live
		}
		AssertEqual(ObjPtr(Saved.Focus), ObjPtr(_LLM_Bridge_ReadLiveFocus),
			"the live-mode fixture restores the exact foreground probe identity")
		AssertEqual(Saved.Tasks, _SR_ActiveTasks.Count,
			"the live-mode fixture must not launch a native positioning worker")
	}
}

; Stores Value as the live toggle parameter of the test binding and runs it.
; The notice it requested is handed back, then retired before its render timer
; could paint it: a painted notice is a hotstring-style tooltip, which live
; requests wait for.
_LLV_Toggle(Value, &Notice := "") {
	global GestureActionParameters, LLV_BINDING
	GestureActionParameters[GestureActionParameterKey(LLV_BINDING, "llm_live_prompt_toggle")] := Value
	return _LLV_InvokeAndRetireNotice(GestureInvokeAction.Bind("llm_live_prompt_toggle", LLV_BINDING), &Notice)
}

/**
 * Retires this fixture's real notice before releasing its fake typing ports.
 * The caller keeps its exact critical setting and the actual action outcome.
 * @param {Func} Action - Actual gesture or menu callback owned by this scenario.
 * @param {string} Notice - Captured pending notice, including refusal or throw.
 * @returns {Any} The actual action's unchanged return value.
 */
_LLV_InvokeAndRetireNotice(Action, &Notice := "") {
	global _TooltipActiveSurface
	PreviousCritical := Critical("On")
	try {
		try {
			return Action.Call()
		} finally {
			try Notice := _LPP_PendingNotice()
			finally {
				try TooltipHide("LiveModeTest", true)
				finally _TooltipActiveSurface := 0
			}
		}
	} finally Critical(PreviousCritical)
}

/** Exercises real notice cleanup for both refusal and callback interruption. */
_LLV_NoticeRetirementPreservesForeignOwnership() {
	_LLV_Run("", _Body)
	_Body(Calls, Lines, Builds) {
		global _SR_ActiveTasks, _TooltipPendingRequest, _TooltipActiveSurface
		PreviousCritical := Critical(37)
		ForeignId := "live-mode-owned-foreign-receipt"
		Foreign := {OwnedByAnotherFixture: true}
		Installed := false
		try {
			AssertFalse(_SR_ActiveTasks.Has(ForeignId), "the fixture owns a new foreign-task observation slot")
			_SR_ActiveTasks[ForeignId] := Foreign
			Installed := true
			ExpectedTasks := _SR_ActiveTasks.Count
			for Interrupted in [false, true] {
				Observed := []
				Notice := ""
				Failure := ""
				Outcome := true
				try Outcome := _LLV_InvokeAndRetireNotice(_LLV_NoticeBoundaryAction.Bind(Interrupted, Observed), &Notice)
				catch as Err {
					Failure := Err.Message
				}
				AssertEqual(Interrupted ? "owned live-mode notice interruption" : "", Failure,
					"the notice boundary preserves the actual callback exception")
				if !Interrupted
					AssertFalse(Outcome, "a refused callback keeps its actual false result")
				AssertEqual(1, Observed.Length, "the callback publishes one real notice")
				AssertEqual("Owned live-mode notice", Observed[1].Notice,
					"the actual pending request exists while the callback runs")
				Assert(Observed[1].Critical > 0, "notice publication stays inside the owned protected boundary")
				AssertEqual("Owned live-mode notice", Notice, "cleanup preserves the exact observed notice")
				AssertFalse(IsObject(_TooltipPendingRequest), "refusal and throw retire the real pending notice")
				AssertEqual(0, _TooltipActiveSurface, "no notice surface escapes the fixture")
				AssertEqual(37, A_IsCritical, "the exact caller critical setting is restored")
				AssertTrue(_SR_ActiveTasks.Has(ForeignId), "cleanup cannot steal an unrelated task")
				AssertEqual(ObjPtr(Foreign), ObjPtr(_SR_ActiveTasks[ForeignId]),
					"the unrelated task keeps its exact ownership identity")
				AssertEqual(ExpectedTasks, _SR_ActiveTasks.Count,
					"cleanup neither launches a positioning worker nor removes foreign ownership")
			}
		} finally {
			try {
				if Installed && _SR_ActiveTasks.Has(ForeignId)
						&& ObjPtr(_SR_ActiveTasks[ForeignId]) == ObjPtr(Foreign)
					_SR_ActiveTasks.Delete(ForeignId)
			} finally Critical(PreviousCritical)
		}
	}
}

/** Publishes through the actual notice owner; assertions run after it returns. */
_LLV_NoticeBoundaryAction(Interrupted, Observed) {
	_LLM_Menu_ShowNotice("Owned live-mode notice")
	Observed.Push({Notice: _LPP_PendingNotice(), Critical: A_IsCritical})
	if Interrupted
		throw Error("owned live-mode notice interruption")
	return false
}
Test("LLM live mode: notice refusal and throw retain caller and foreign ownership", _LLV_NoticeRetirementPreservesForeignOwnership)

; One keystroke of the automatic trigger: the buffer grows, the engine arms
; its debounce through a recorder instead of a real timer.
; @returns {Map} Map("fn", the armed callback, "period", its SetTimer period).
_LLV_Type(Text) {
	global _LLM_Bridge_Buffer
	Armed := []
	_LLM_Bridge_ApplyBufferEdit(0, Text)
	LLM_Engine_OnKeystroke(_LLM_Bridge_Buffer, "", (Fn, Period) => Armed.Push(Map("fn", Fn, "period", Period)))
	AssertEqual(1, Armed.Length, "one keystroke arms one debounce")
	return Armed[1]
}

; Fires an armed debounce as its timer would, with the rate floor open.
_LLV_Fire(Armed) {
	global _LLM_Engine
	_LLM_Engine["last_request_tick"] := 0
	_LLM_Engine["timer_active"] := false
	Armed["fn"].Call()
}

; The system prompt a profile sends with a count and a minimum word count.
_LLV_System(ProfileId, Count, MinWords) {
	return LLM_ResolveSystemPrompt(LLM_FindProfile(ProfileId), Count, MinWords, 5, "fr")
}

; Runs Action with the SetTimer-armed debounce it leaves captured instead of
; running: Critical keeps the real timer from firing before it is cancelled.
; @returns {Object} { Fn, Active } the pending callback and the armed flag.
_LLV_CaptureRealTimer(Action) {
	global _LLM_Engine, _LLM_Bridge_PrefixObserver
	PreviousCritical := Critical("On")
	try {
		Action.Call()
		; A hotstring now defers ancillary work until its atomic input commit ends.
		; Drive that exact owner before capturing the resulting prediction timer.
		if IsObject(_LLM_Bridge_PrefixObserver) {
			Owner := _LLM_Bridge_PrefixObserver
			TimerSetCallback(Owner.Timer, 0)
			_LLM_Bridge_RunPrefixObserver(Owner)
		}
		Captured := { Fn: _LLM_Engine["pending_timer"], Active: _LLM_Engine["timer_active"] }
		LLM_Engine_CancelTimer()
	} finally {
		Critical(PreviousCritical)
	}
	return Captured
}





; ======================================================
; ======================================================
; ======= 2/ Translation as you type, end to end =======
; ======================================================
; ======================================================

_LLV_TranslatesAsYouType() {
	_LLV_Run("", _Body)
	_Body(Calls, Lines, Builds) {
		global _LLM_Menu, _LLM_Engine, _LLM_Bridge_Buffer, LLV_SENTENCE
		AssertTrue(_LLV_Toggle("translate_en|1", &Notice), "the first trigger turns live mode on")
		AssertTrue(LLM_Engine_LiveIsActive(), "live mode is on")
		AssertEqual(StrReplace(t("llm.live.on"), "{1}", LLM_Menu_GetProfileLabel("translate_en")),
			Notice, "the notice names the prompt as the menu labels it")
		AssertEqual(1, Builds.Length, "the AI menu is rebuilt to check the live row")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "Live mode on with 'translate_en'"),
			"the transition is logged")

		; Typing: every keystroke arms live.json's debounce, not the menu's
		Live := LLM_Live_Config()
		Armed := ""
		loop parse, LLV_SENTENCE {
			Armed := _LLV_Type(A_LoopField)
			AssertEqual(LLM_Option_DebounceTimerPeriod(Live["debounce_ms"]), Armed["period"],
				"live mode arms live.json's debounce")
		}
		AssertFalse(Armed["period"] == LLM_Option_DebounceTimerPeriod(700),
			"precondition: the menu's debounce differs")
		AssertEqual(0, Calls.Length, "nothing is sent before the debounce")
		_LLV_Fire(Armed)
		AssertEqual(1, Calls.Length, "the debounce fires one request")
		Call := Calls[1]
		AssertEqual(_LLV_System("translate_en", 1, Live["min_words"]), Call["system"],
			"the live prompt answers, with the binding's count")
		AssertContains(Call["system"], "Translate TAIL into English", "the translation prompt is sent")
		AssertEqual(LLV_SENTENCE, Call["tail"], "the tail is the current sentence")
		AssertEqual(_LLM_Engine_CallTokenBudget(LLM_Rewrite_MaxTokens(LLV_SENTENCE), 1),
			Call["max_tokens"], "with the rewrite budget")

		; The answer: the tooltip offers the translation, which replaces the sentence
		_LPP_Answer(Call, "REWRITE: See you tomorrow")
		AssertEqual(1, Calls.Length, "a count of one asks nothing more")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the translation reaches the tooltip")
		Slot := Final.slots[1]
		AssertTrue(IsObject(Slot) && Slot.HasOwnProp("Deletes"), "a live rewrite slot carries its erasure")
		AssertEqual("See you tomorrow", Slot.Text, "the slot types the translation")
		AssertEqual(LLV_SENTENCE, Slot.DeletedText, "and erases the typed sentence")

		_LPP_WithKeyboard(_Accept)
		_Accept(Sent) {
			global _LLM_Bridge_Buffer, _LLM_Engine
			Presented := LLM_Tooltip_GetAcceptSnapshot()
			Transaction := _LPP_AcceptTransaction(Presented)
			Results := []
			TextSend(Transaction.Text, _LLM_Bridge_InjectionOptions(Transaction),
				(Ok, ErrorMessage := "") => Results.Push(Ok))
			AssertEqual(1, Sent.Length, "the erasure and the translation are one batch")
			AssertEqual("{Backspace " . Slot.Deletes . "}{Text}See you tomorrow", Sent[1],
				"the sentence is erased, then the translation typed")
			AssertTrue(Results.Length == 1 && Results[1], "the output is reported as emitted")
			AssertEqual("See you tomorrow", _LLM_Bridge_Buffer, "the buffer holds the translation")
			; The accepted sentence is not asked again until the user types
			AssertFalse(_LLM_Engine["timer_active"], "accepting arms no live request")
			AssertEqual(1, Calls.Length, "and sends none")
		}

		; The menu's settings were never touched
		AssertEqual("advanced", _LLM_Menu["profile_id"], "the active profile is untouched")
		AssertEqual(3, _LLM_Menu["n_predictions"], "the menu's count is untouched")
		AssertEqual("advanced", _LLM_Engine["profile_id"], "the engine's profile is untouched")
		AssertEqual(700, _LLM_Engine["debounce_ms"], "the menu's debounce is untouched")
		AssertEqual(8, _LLM_Engine["min_words"], "the menu's minimum word count is untouched")

		; Second trigger: off, and typing is the ordinary prediction again
		AssertTrue(_LLV_Toggle("translate_en|1", &Notice), "the second trigger turns live mode off")
		AssertFalse(LLM_Engine_LiveIsActive(), "live mode is off")
		AssertEqual(t("llm.live.off"), Notice, "with its notice")
		AssertEqual(2, Builds.Length, "the AI menu is rebuilt again")
		Armed := _LLV_Type(" ok")
		AssertEqual(LLM_Option_DebounceTimerPeriod(700), Armed["period"],
			"the menu's debounce applies again")
		_LLV_Fire(Armed)
		AssertEqual(2, Calls.Length, "the ordinary trigger fires")
		AssertEqual(LLM_ResolveSystemPrompt(LLM_GetActiveProfile("advanced", []), 3, 8, 5, "fr"),
			Calls[2]["system"], "with the menu's profile, count and minimum word count")
	}
}
Test("LLM live mode: a translation follows typing and replaces the sentence on accept",
	_LLV_TranslatesAsYouType)

; The typing path itself (the bridge's OnChar) carries the live override.
_LLV_BridgeKeystrokeIsRedirected() {
	_LLV_Run("on se voit demai", _Body)
	_Body(Calls, Lines, Builds) {
		global LLV_SENTENCE
		AssertTrue(_LLV_Toggle("translate_en|1"), "live mode on")
		Captured := _LLV_CaptureRealTimer(() => LLM_Bridge_OnChar("n"))
		AssertTrue(Captured.Active, "a typed character arms the automatic trigger")
		_LLV_Fire(Map("fn", Captured.Fn))
		AssertEqual(1, Calls.Length, "which sends the live request")
		AssertEqual(LLV_SENTENCE, Calls[1]["tail"], "on the sentence typed so far")
		AssertEqual(_LLV_System("translate_en", 1, LLM_Live_Config()["min_words"]), Calls[1]["system"],
			"with the live prompt")
	}
}
Test("LLM live mode: a typed character arms the live request", _LLV_BridgeKeystrokeIsRedirected)

; Live mode's own word floor replaces the menu's, even for a continuation prompt.
_LLV_MinimumWordsAreLiveOnes() {
	_LLV_Run("bonjour", _Body)
	_Body(Calls, Lines, Builds) {
		global _LLM_Menu, _LLM_Engine
		Profile := Map("id", "user_live_1", "label", "Suite",
			"system_single", "Continue with at least {min_words} words: {context}", "batch", false)
		_LLM_Menu["user_profiles"] := [Profile]
		_LLM_Engine["user_profiles"] := [Profile]
		AssertTrue(_LLV_Toggle("user_live_1|1"), "a custom prompt can run live")
		_LLV_Fire(_LLV_Type(" Marc"))
		AssertEqual(1, Calls.Length, "the live request is sent")
		Live := LLM_Live_Config()
		AssertEqual(LLM_ResolveSystemPrompt(Profile, 1, Live["min_words"], 5, "fr"), Calls[1]["system"],
			"the prompt carries live.json's minimum word count")
		AssertFalse(Calls[1]["system"] == LLM_ResolveSystemPrompt(Profile, 1, 8, 5, "fr"),
			"not the menu's")
	}
}
Test("LLM live mode: the minimum word count is live.json's", _LLV_MinimumWordsAreLiveOnes)

; A new keystroke supersedes the live request in flight.
_LLV_SupersededRequestIsIgnored() {
	_LLV_Run("on se voit", _Body)
	_Body(Calls, Lines, Builds) {
		AssertTrue(_LLV_Toggle("translate_en|1"), "live mode on")
		_LLV_Fire(_LLV_Type(" de"))
		AssertEqual(1, Calls.Length, "the first live request is in flight")
		Next := _LLV_Type("m")
		_LPP_Answer(Calls[1], "REWRITE: See you to")
		AssertEqual("", _LPP_LastFinalRender(), "the superseded answer is not shown")
		_LLV_Fire(Next)
		AssertEqual(2, Calls.Length, "the keystroke's own request is sent")
		AssertEqual("on se voit dem", Calls[2]["tail"], "on the newer text")
		_LPP_Answer(Calls[2], "REWRITE: See you tomo")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the current answer is shown")
		AssertEqual("See you tomo", Final.slots[1].Text, "and only it")
	}
}
Test("LLM live mode: a superseded live request is ignored", _LLV_SupersededRequestIsIgnored)





; ========================================
; ========================================
; ======= 3/ Turning it on and off =======
; ========================================
; ========================================

_LLV_UnknownPromptStaysOff() {
	_LLV_Run("hello", _Body)
	_Body(Calls, Lines, Builds) {
		AssertFalse(_LLV_Toggle("user_deleted_42", &Notice), "a prompt that no longer exists is refused")
		AssertFalse(LLM_Engine_LiveIsActive(), "live mode stays off")
		AssertEqual(t("llm.prompt_prediction.unknown_prompt"), Notice,
			"with the unknown-prompt notice")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "user_deleted_42"), "the refusal is logged")
		AssertFalse(_LLV_Toggle("rewrite|11"), "an invalid stored value is refused too")
		AssertFalse(LLM_Engine_LiveIsActive(), "and leaves live mode off")
	}
}
Test("LLM live mode: an unknown prompt is refused and live mode stays off",
	_LLV_UnknownPromptStaysOff)

_LLV_RefusalsKeepItOff() {
	_LLV_Run("hello", _Body, _LPP_Menu(false))
	_Body(Calls, Lines, Builds) {
		AssertFalse(_LLV_Toggle("translate_en", &Notice), "the AI switched off refuses live mode")
		AssertEqual(t("llm.manual_prediction.disabled"), Notice,
			"with the manual prediction's notice")
		AssertFalse(LLM_Engine_LiveIsActive(), "live mode stays off")
	}
	_LLV_Run("", _Empty)
	_Empty(Calls, Lines, Builds) {
		AssertTrue(_LLV_Toggle("translate_en"), "nothing typed yet is no refusal: live mode waits")
		AssertTrue(LLM_Engine_LiveIsActive(), "live mode is on")
		AssertEqual(0, Calls.Length, "and asks nothing yet")
	}
}
Test("LLM live mode: the manual prediction refusals apply, but for an empty buffer",
	_LLV_RefusalsKeepItOff)

; Any toggle binding turns live mode off, whatever it names.
_LLV_AnyBindingTurnsItOff() {
	_LLV_Run("hello", _Body)
	_Body(Calls, Lines, Builds) {
		AssertTrue(_LLV_Toggle("translate_ja"), "live mode on with one binding")
		AssertTrue(_LLV_Toggle("rewrite|11"), "another binding, even with an invalid value, turns it off")
		AssertFalse(LLM_Engine_LiveIsActive(), "live mode is off")
	}
}
Test("LLM live mode: a second trigger of any binding turns it off", _LLV_AnyBindingTurnsItOff)

; Turning the AI off and pausing end live mode, which is never persisted.
_LLV_AiOffAndPauseTurnItOff() {
	_LLV_Run("hello", _Body)
	_Body(Calls, Lines, Builds) {
		global _LLM_Engine
		AssertTrue(_LLV_Toggle("translate_en"), "live mode on")
		_LLV_Type(" x")
		AssertTrue(_LLM_Engine["timer_active"], "precondition: a live request is armed")
		LLM_Engine_SetEnabled(false)
		AssertFalse(LLM_Engine_LiveIsActive(), "turning the AI off ends live mode")
		AssertFalse(_LLM_Engine["timer_active"], "and its armed request")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "Live mode off (the AI was turned off)"),
			"silently, with an INFO line")
		_LLM_Engine["enabled"] := true
		AssertTrue(_LLV_Toggle("translate_en"), "live mode on again")
		AssertTrue(LLM_Engine_LiveStop("Ergopti+ was paused"), "the pause owner turns it off")
		AssertFalse(LLM_Engine_LiveStop("Ergopti+ was paused"), "once")
		AssertFalse(LLM_Engine_LiveIsActive(), "live mode is off after a pause")
	}
	Suspend := _DriverFuncBody("Ergopti_OnSuspendEnter")
	AssertContains(Suspend, '"llm-live-mode"', "pausing runs the live mode owner")
	AssertContains(Suspend, 'LLM_Engine_LiveStop("Ergopti+ was paused")', "which turns live mode off")
	Source := FileRead(A_ScriptDir . "\..\modules\llm\prediction_live.ahk", "UTF-8")
	AssertContains(Source, 'global _LLM_Live := Map("active", false,',
		"live mode starts off and is read from no configuration")
}
Test("LLM live mode: turning the AI off or pausing turns it off", _LLV_AiOffAndPauseTurnItOff)

; The request identity separates live requests; the override validates its flag.
_LLV_LiveIsPartOfTheRequestIdentity() {
	global _SharedDir
	Profile := LLM_FindProfile("translate_en")
	AssertFalse(_LLM_Engine_RequestSemanticSignature("translate_en", Profile, 0, true)
		== _LLM_Engine_RequestSemanticSignature("translate_en", Profile, 0),
		"a live request never shares a cache entry or callback with an ordinary one")
	AssertThrows(() => _LLM_Engine_NormalizePromptOverride(
		Map("profile_id", "basic", "live", "yes")), "the live flag is a Boolean")
	Path := _SharedDir . "\modules\llm\live.json"
	File := JsonParse(FileRead(Path, "UTF-8"))
	AssertEqual(File["debounce_ms"], LLM_Live_Config()["debounce_ms"], "the debounce is live.json's")
	AssertEqual(File["min_words"], LLM_Live_Config()["min_words"], "the word floor is live.json's")
}
Test("LLM live mode: live requests have their own identity and configuration",
	_LLV_LiveIsPartOfTheRequestIdentity)





; ========================================
; ========================================
; ======= 4/ The AI menu's submenu =======
; ========================================
; ========================================

_LLV_MenuListsRewritePrompts() {
	_LLV_Run("hello", _Body)
	_Body(Calls, Lines, Builds) {
		global _LLM_Menu, _LLM_Engine, LLM_PROFILE_BUILTIN_ORDER
		Custom := Map("id", "user_trad_1", "label", "Traduire en allemand",
			"raw_prompt", "Translate TAIL into German. Reply REWRITE: <t>", "batch", false)
		Plain := Map("id", "user_plain_1", "label", "Suite", "system_single", "Continue: {context}",
			"batch", false)
		_LLM_Menu["user_profiles"] := [Custom, Plain]
		_LLM_Engine["user_profiles"] := [Custom, Plain]
		Rows := _LLM_Menu_LiveModeRows()
		AssertEqual(t("menu.llm.live_mode_off"), Rows[1]["label"], "Off comes first")
		AssertTrue(Rows[1]["checked"], "and is checked while live mode is off")
		Expected := []
		for Id in LLM_PROFILE_BUILTIN_ORDER
			if LLM_Rewrite_IsRewriteProfile(LLM_FindProfile(Id))
				Expected.Push(LLM_Menu_GetProfileLabel(Id))
		Expected.Push("Traduire en allemand")
		AssertEqual(Expected.Length + 1, Rows.Length, "then every rewrite prompt, and only those")
		for Index, Label in Expected
			AssertEqual(Label, Rows[Index + 1]["label"], "built-ins in menu order, then custom prompts")
		Labels := ""
		for Row in Rows
			Labels .= Row["label"] . "|"
		AssertContains(Labels, LLM_Menu_GetProfileLabel("translate_en"), "the translations are listed")
		AssertFalse(InStr(Labels, LLM_Menu_GetProfileLabel("basic")) > 0, "continuation prompts are not")
		AssertFalse(InStr(Labels, "Suite|") > 0, "nor a custom continuation prompt")

		; Choosing a prompt turns live mode on with it and the menu's count
		for Row in Rows {
			if (Row["label"] == LLM_Menu_GetProfileLabel("translate_ja")) {
				AssertTrue(_LLV_InvokeAndRetireNotice(Row["action"], &Notice),
					"the actual menu callback returns its live-mode admission")
				AssertEqual(StrReplace(t("llm.live.on"), "{1}", LLM_Menu_GetProfileLabel("translate_ja")), Notice,
					"the protected menu callback retains its actual localized notice")
			}
		}
		AssertTrue(LLM_Engine_LiveIsActive(), "the row turns live mode on")
		Override := LLM_Engine_LiveOverride()
		AssertEqual("translate_ja", Override["profile_id"], "with its prompt")
		AssertEqual(0, Override["num_predictions"], "and the menu's count")
		Rows := _LLM_Menu_LiveModeRows()
		AssertFalse(Rows[1]["checked"], "Off is no longer checked")
		for Row in Rows
			AssertEqual(Row["label"] == LLM_Menu_GetProfileLabel("translate_ja"), Row["checked"] ? true : false,
				"only the live prompt is checked: " . Row["label"])
		; The action and the menu share one state: the menu's Off ends the action's live mode
		AssertTrue(_LLV_InvokeAndRetireNotice(Rows[1]["action"], &Notice),
			"the actual Off callback retains its successful result")
		AssertEqual(t("llm.live.off"), Notice, "Off retains its actual localized notice")
		AssertFalse(LLM_Engine_LiveIsActive(), "Off turns live mode off")
		AssertEqual("advanced", _LLM_Menu["profile_id"], "the active profile never changed")
	}
	Emit := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(!InStr(Emit, 'case "llm_live_mode":', true), "the AI menu has no second live profile selector")
	Assert(!InStr(Emit, 'Map("llm_live_mode", LLM_Menu_BuildLiveModeMenu)', true), "the retired live selector is not bound")
	Assert(_LMNM_GenerationRoute(Emit), "the retained native generation group consumes the same callable and handle through its typed renderer")
}
Test("LLM live mode: retained shortcut provider preserves state without a visible live selector",
	_LLV_MenuListsRewritePrompts)

; The live translations stay out of the Ctrl+<n> profile hotkeys.
_LLV_TranslationsTakeNoHotkey() {
	; The menu index that assigns the limit is not part of the test build.
	global LLM_PROFILE_LIVE_TRANSLATIONS, LLM_PROFILE_HOTKEY_LIMIT
	HadLimit := IsSet(LLM_PROFILE_HOTKEY_LIMIT)
	if HadLimit
		SavedLimit := LLM_PROFILE_HOTKEY_LIMIT
	LLM_PROFILE_HOTKEY_LIMIT := 9
	try {
		Order := LLM_Menu_GetHotkeyProfileOrder(Map("user_profiles", []))
		AssertTrue(Order.Length > 0, "precondition: the built-ins take hotkeys")
		for Id in LLM_PROFILE_LIVE_TRANSLATIONS {
			AssertTrue(LLM_Rewrite_IsRewriteProfile(LLM_FindProfile(Id)),
				"the built-in " . Id . " rewrites the sentence")
			for HotkeyId in Order
				Assert(HotkeyId != Id, Id . " must not take a Ctrl+<n> hotkey")
		}
	} finally {
		LLM_PROFILE_HOTKEY_LIMIT := HadLimit ? SavedLimit : unset
	}
}
Test("LLM live mode: the live translations take no profile hotkey", _LLV_TranslationsTakeNoHotkey)





; =======================================================
; =======================================================
; ======= 5/ Hotstrings, Tab and explicit actions =======
; =======================================================
; =======================================================

; An expansion fires first: the live tooltip is dismissed and the request is
; re-issued on the text after the expansion.
_LLV_ExpansionReissuesTheLiveRequest() {
	global _LLM_Bridge_ReadLiveFocus
	SavedFocus := _LLM_Bridge_ReadLiveFocus
	Unfocused := () => Map("hwnd", 101, "control", 0)
	Restored := false
	try {
		_LLM_Bridge_ReadLiveFocus := Unfocused
		_LLV_Run("on se voit dm", _Body)
		Restored := ObjPtr(_LLM_Bridge_ReadLiveFocus) == ObjPtr(Unfocused)
	} finally {
		_LLM_Bridge_ReadLiveFocus := SavedFocus
	}
	AssertTrue(Restored, "the scenario restores its caller's unknown focused-control probe")
	_Body(Calls, Lines, Builds) {
		global _LLM_Bridge_Buffer, _Stub_LlmTooltipVisible, _Stub_LlmPresentedRecord
		; Outside live mode an expansion arms nothing: next-word prediction is unchanged
		Plain := _LLV_CaptureRealTimer(() => _HSE_MirrorCanonicalEffectToLlm(
			{ DeleteFromEnd: 0, InsertedText: "" }))
		AssertFalse(Plain.Active, "outside live mode an expansion arms nothing")

		AssertTrue(_LLV_Toggle("translate_en|1"), "live mode on")
		LLM_Tooltip_Show(["See you dm"], 1, true, Map("offer_id", 1))
		AssertTrue(_Stub_LlmTooltipVisible, "precondition: a live tooltip is shown")
		Captured := _LLV_CaptureRealTimer(() => _HSE_MirrorCanonicalEffectToLlm(
			{ DeleteFromEnd: 2, InsertedText: "demain" }))
		AssertEqual("on se voit demain", _LLM_Bridge_Buffer, "the expansion reached the buffer")
		AssertTrue(Captured.Active, "the live request is re-armed after the expansion")
		Sleep(30)   ; the tooltip teardown is deferred off the hook thread
		AssertFalse(_Stub_LlmTooltipVisible, "the live tooltip of the replaced text is dismissed")
		_LLV_Fire(Map("fn", Captured.Fn))
		AssertEqual(1, Calls.Length, "the re-issued request is sent")
		AssertEqual("on se voit demain", Calls[1]["tail"], "on the text after the expansion")
	}
}
Test("LLM live mode: a hotstring expansion wins and the live request follows it",
	_LLV_ExpansionReissuesTheLiveRequest)

; A deferred expansion still refuses an unknown or changed typing target.
; These observations run after the actual observer's guarded callback returns.
_LLV_ExpansionObserverRequiresCurrentFocus() {
	_LLV_Run("on se voit dm", _Body)
	_Body(Calls, Lines, Builds) {
		global _LLM_Bridge_ReadLiveFocus, _LLM_Bridge_Buffer
		Focus := Map("hwnd", 101, "control", 0)
		_LLM_Bridge_ReadLiveFocus := () => Focus.Clone()
		AssertTrue(_LLV_Toggle("translate_en|1"), "live mode on")
		Missing := _LLV_CaptureRealTimer(() => _HSE_MirrorCanonicalEffectToLlm(
			{ DeleteFromEnd: 2, InsertedText: "demain" }))
		AssertEqual("on se voit demain", _LLM_Bridge_Buffer,
			"an unknown focus does not discard the committed canonical expansion")
		AssertFalse(Missing.Active, "an unknown focused control refuses the deferred re-arm")
		AssertEqual(0, Calls.Length, "an unverified typing target starts no transport")
		Focus["control"] := 102
		ChangeTarget() {
			_HSE_MirrorCanonicalEffectToLlm({ DeleteFromEnd: 0, InsertedText: "" })
			Focus["control"] := 103
		}
		Changed := _LLV_CaptureRealTimer(ChangeTarget)
		AssertFalse(Changed.Active, "a focused-control change retires the exact deferred owner")
		AssertEqual(0, Calls.Length, "a stale typing target starts no transport")
		Stable := _LLV_CaptureRealTimer(() => _HSE_MirrorCanonicalEffectToLlm(
			{ DeleteFromEnd: 0, InsertedText: "" }))
		AssertTrue(Stable.Active, "a verified unchanged typing target re-arms the live request")
		_LLV_Fire(Map("fn", Stable.Fn))
		AssertEqual(1, Calls.Length, "the verified deferred re-arm starts exactly one transport")
		AssertEqual("on se voit demain", Calls[1]["tail"], "the request uses the canonical expanded text")
	}
}
Test("LLM live mode: expansion observers require an unchanged verified typing target",
	_LLV_ExpansionObserverRequiresCurrentFocus)

; While a hotstring tooltip is shown the live tooltip waits, then comes back.
_LLV_HotstringTooltipIsNotCovered() {
	_LLV_Run("on se voit", _Body)
	_Body(Calls, Lines, Builds) {
		global _TooltipActiveSurface, _LLM_Engine
		AssertTrue(_LLV_Toggle("translate_en|1"), "live mode on")

		; A request armed before the preview appeared waits for it
		Armed := _LLV_Type(" de")
		_TooltipActiveSurface := {}
		AssertTrue(TooltipIsVisible(), "precondition: a hotstring tooltip is shown")
		_LLV_Fire(Armed)
		AssertEqual(0, Calls.Length, "no live request while the hotstring tooltip is shown")
		Captured := _LLV_CaptureRealTimer(() => LLM_Bridge_OnChar("m"))
		AssertFalse(Captured.Active, "typing under a hotstring tooltip arms nothing")

		; The preview's chain re-arms live mode even with after_hotstring off
		AssertFalse(_LLM_Engine["after_hotstring"], "precondition: after_hotstring is off")
		Chain := _LLV_CaptureRealTimer(
			() => LLM_Bridge_ScheduleAfterHotstring([{ Text: "x", DurationSec: 0.2 }]))
		AssertTrue(Chain.Active, "the hotstring chain asks live mode again once the preview closes")
		_TooltipActiveSurface := 0
		_LLV_Fire(Map("fn", Chain.Fn))
		AssertEqual(1, Calls.Length, "the live request is sent once the preview is gone")
		AssertEqual("on se voit dem", Calls[1]["tail"], "on the current text")

		; A preview appearing while the answer is on its way keeps the surface
		_TooltipActiveSurface := {}
		_LPP_Answer(Calls[1], "REWRITE: See you tomo")
		AssertEqual("", _LPP_LastFinalRender(), "the live answer does not cover the preview")
		_TooltipActiveSurface := 0
	}
}
Test("LLM live mode: a hotstring tooltip is never covered by the live tooltip",
	_LLV_HotstringTooltipIsNotCovered)

; Tab accepts only while the live tooltip is visible.
_LLV_TabAcceptsOnlyAVisibleLiveTooltip() {
	_LLV_Run("on se voit demain", _Body)
	_Body(Calls, Lines, Builds) {
		global _Stub_LlmPresentedRecord, LLV_SENTENCE
		AssertTrue(_LLV_Toggle("translate_en|1"), "live mode on")
		Accepted := []
		Input := Map("known", true, "tab_down", true, "ctrl_down", false, "alt_down", false,
			"shift_down", false, "win_down", false, "current_hwnd", 100, "current_control", 1001)
		AssertFalse(LLM_Tooltip_TryAcceptTab(true, [], Input, (Text) => Accepted.Push(Text)),
			"no live tooltip: Tab is left alone")
		_LLV_Fire(_LLV_Type(""))
		_LPP_Answer(Calls[1], "REWRITE: See you tomorrow")
		AssertTrue(IsObject(_LPP_LastFinalRender()), "the live tooltip is shown")
		_Stub_LlmPresentedRecord.Lifecycle.AcceptSource := Map("hwnd", 100, "control", 1001,
			"request_id", _Stub_LlmPresentedRecord.Lifecycle.OfferId)
		AssertTrue(LLM_Tooltip_TryAcceptTab(true, [], Input, (Text) => Accepted.Push(Text)),
			"Tab accepts the visible live rewrite")
		AssertEqual(1, Accepted.Length, "once")
		AssertEqual("See you tomorrow", Accepted[1], "the translation is what Tab accepts")
		AssertFalse(LLM_Tooltip_TryAcceptTab(true, [], Input, (Text) => Accepted.Push(Text)),
			"once accepted and hidden, Tab is left alone again")
	}
}
Test("LLM live mode: Tab accepts only while the live tooltip is visible",
	_LLV_TabAcceptsOnlyAVisibleLiveTooltip)

; Explicit AI actions take over; live mode resumes on the next keystroke.
_LLV_ExplicitActionsTakeOver() {
	_LLV_Run("on se voit", _Body)
	_Body(Calls, Lines, Builds) {
		global _LLM_Engine
		AssertTrue(_LLV_Toggle("translate_en|1"), "live mode on")
		_LLV_Fire(_LLV_Type(" de"))
		AssertEqual(1, Calls.Length, "a live request is in flight")
		_LLM_Engine["last_request_tick"] := 0
		AssertTrue(LLM_Menu_TriggerPredictionWith("basic", 1), "an explicit prompt prediction runs")
		AssertEqual(2, Calls.Length, "with its own request")
		AssertEqual(_LLV_System("basic", 1, 8), Calls[2]["system"],
			"its own prompt, with the menu's word floor")
		_LPP_Answer(Calls[1], "REWRITE: See you to")
		AssertEqual("", _LPP_LastFinalRender(), "the live answer does not replace the explicit one")
		AssertTrue(LLM_Engine_LiveIsActive(), "live mode is still on")
		_LLV_Fire(_LLV_Type("m"))
		AssertEqual(3, Calls.Length, "the next keystroke asks live mode again")
		AssertEqual(_LLV_System("translate_en", 1, LLM_Live_Config()["min_words"]), Calls[3]["system"],
			"with the live prompt")
	}
}
Test("LLM live mode: explicit AI actions take over and live mode resumes on typing",
	_LLV_ExplicitActionsTakeOver)


/** A due renderer must not escape the live-menu fixture into native I/O. */
_LLV_MenuNoticeRetiresBeforeYield() {
	_LLV_Run("hello", _Body)
	_Body(Calls, Lines, Builds) {
		global _TooltipPendingRequest
		State := { Rendered: false }
		Renderer := (*) => State.Rendered := true
		Rows := _LLM_Menu_LiveModeRows()
		AssertTrue(Rows.Length > 1, "the real menu must have a live prompt to invoke")
		Action() {
			Rows[2]["action"].Call()
			Request := _TooltipPendingRequest
			AssertTrue(IsObject(Request), "the real menu action must publish its notice")
			; Substitute only the renderer boundary; a failure cannot touch native UI.
			SetTimer(Request.TimerFn, 0)
			Request.TimerFn := Renderer
			SetTimer(Renderer, -1)
			Sleep(30)
			return true
		}
		try {
			AssertTrue(_LLV_InvokeAndRetireNotice(Action, &Notice))
			AssertTrue(LLM_Engine_LiveIsActive(), "the original action actually changed live mode")
			AssertTrue(Notice != "", "the original notice must be captured")
			AssertFalse(State.Rendered, "the due renderer must be retired before the fixture yields")
			AssertFalse(IsObject(_TooltipPendingRequest), "the native notice owner is retired")
			SetTimer(Renderer, -1)
			Sleep(30)
			AssertTrue(State.Rendered, "the substituted renderer can run when no longer fenced")
		} finally {
			SetTimer(Renderer, 0)
			TooltipHide("LiveModeTest", true)
		}
	}
}
Test("LLM live mode: menu fixture retires due rendering before yielding (live-menu-fixture)",
	_LLV_MenuNoticeRetiresBeforeYield)


/** A failed action must retire its queued renderer before scheduler release. */
_LLV_FailedMenuNoticeRetiresBeforeYield() {
	_LLV_Run("hello", _Body)
	_Body(Calls, Lines, Builds) {
		global _TooltipPendingRequest
		State := { Rendered: false }
		Renderer := (*) => State.Rendered := true
		Rows := _LLM_Menu_LiveModeRows()
		AssertTrue(Rows.Length > 1, "the real menu must provide an action")
		Failure := Error("expected live menu action failure")
		Action() {
			Rows[2]["action"].Call()
			Request := _TooltipPendingRequest
			AssertTrue(IsObject(Request), "the failing action first publishes its actual notice")
			SetTimer(Request.TimerFn, 0)
			Request.TimerFn := Renderer
			SetTimer(Renderer, -1)
			throw Failure
		}
		PreviousCritical := A_IsCritical
		Caught := 0
		try {
			try _LLV_InvokeAndRetireNotice(Action)
			catch as Err
				Caught := Err
			AssertTrue(IsObject(Caught), "the action failure must propagate")
			AssertEqual(ObjPtr(Failure), ObjPtr(Caught), "cleanup must retain the original error")
			AssertEqual(PreviousCritical, A_IsCritical, "failure restores the caller's scheduler")
			Sleep(30)
			AssertFalse(State.Rendered, "the failing action must cancel its due renderer")
			AssertFalse(IsObject(_TooltipPendingRequest), "failure retires the native notice owner")
		} finally {
			SetTimer(Renderer, 0)
			TooltipHide("LiveModeTest", true)
		}
	}
}
Test("LLM live mode: failed menu fixture retires due rendering (live-menu-failure-fixture)",
	_LLV_FailedMenuNoticeRetiresBeforeYield)


; The fixed Off command is declared once; dynamic prompt rows keep their owners.
_LLV_DeclaredOffPolicy() {
	global _SharedDir
	Spec := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\llm_live_off.json", "UTF-8"))
	Declarations := _MR_GetMenuDef(Spec["manifest"])
	AssertEqual(1, Declarations.Length, "only the fixed Off choice belongs to the shared head")
	Entry := Declarations[1]
	AssertEqual("check", Entry["type"])
	AssertEqual(Spec["id"], Entry["id"])
	AssertEqual(Spec["label_key"], Entry["i18n"])
	AssertEqual(Spec["checked_getter"], Entry["checked_when"][1])
	AssertEqual(Spec["ready_getter"], Entry["disabled_when"][1])
	Observed := Map("ready", true, "off", false, "calls", 0)
	Row := MenuRenderer_CheckRow(Spec["manifest"], Spec["id"],
		Map(Spec["id"], _Run), Map(Spec["ready_getter"], (*) => Observed["ready"],
			Spec["checked_getter"], (*) => Observed["off"]))
	_Run(*) {
		Observed["calls"] += 1
		return false
	}
	AssertFalse(Row["checked"])
	for State in Spec["states"] {
		Observed["off"] := !State["live"]
		Projected := MenuRenderer_CheckRow(Spec["manifest"], Spec["id"],
			Map(Spec["id"], _Run), Map(Spec["ready_getter"], (*) => Observed["ready"],
				Spec["checked_getter"], (*) => Observed["off"]))
		AssertEqual(State["checked"], Projected["checked"], "the declared state keeps the actual native tick")
	}
	Observed["ready"] := false
	AssertFalse(Row["action"].Call(), "retained command checks current policy before delivery")
	AssertEqual(0, Observed["calls"])
	Observed["ready"] := true
	AssertFalse(Row["action"].Call(), "native refusal remains the callback result")
	AssertEqual(1, Observed["calls"])
}
Test("LLM live mode: fixed Off command retains shared policy and native receipt", _LLV_DeclaredOffPolicy)


; Drive the actual provider under a shared label edit that collides with a prompt.
_LLV_DeclaredOffLabelOwnsUniqueness() {
	_LLV_Run("hello", _Body)
	_Body(Calls, Lines, Builds) {
		global _MM_MANIFEST_ROOT_CACHE, _LLM_Menu, _LLM_Engine
		SavedCache := _MM_MANIFEST_ROOT_CACHE
		SavedMenuProfiles := _LLM_Menu["user_profiles"]
		SavedEngineProfiles := _LLM_Engine["user_profiles"]
		Observed := Map()
		try {
			Root := _MM_GetManifestRoot().Clone()
			Entry := Root["llm_live_controls"][1].Clone()
			Entry["i18n"] := "button.ok"
			Root["llm_live_controls"] := [Entry]
			_MM_MANIFEST_ROOT_CACHE := Root
			Label := t("button.ok")
			Custom := Map("id", "user_off_collision", "label", Label,
				"system_single", "Rewrite TAIL. Reply REWRITE: <text>", "system_multi", "", "batch", false)
			_LLM_Menu["user_profiles"] := [Custom]
			_LLM_Engine["user_profiles"] := [Custom]
			Rows := _LLM_Menu_LiveModeRows()
			Observed["off_label"] := Rows[1]["label"]
			Seen := Map()
			Duplicates := 0
			for Row in Rows {
				if Seen.Has(Row["label"])
					Duplicates++
				Seen[Row["label"]] := true
			}
			Observed["duplicates"] := Duplicates
			Observed["renamed_prompt"] := Seen.Has(Label . " #2")
			Entry["type"] := "command"
			Observed["refused_rows"] := _LLM_Menu_LiveModeRows().Length
		} finally {
			_MM_MANIFEST_ROOT_CACHE := SavedCache
			_LLM_Menu["user_profiles"] := SavedMenuProfiles
			_LLM_Engine["user_profiles"] := SavedEngineProfiles
		}
		AssertEqual(t("button.ok"), Observed["off_label"], "the actual shared label is admitted")
		AssertEqual(0, Observed["duplicates"], "the provider owns uniqueness for the admitted label")
		AssertTrue(Observed["renamed_prompt"], "the existing prompt suffix owner resolves the collision")
		AssertEqual(0, Observed["refused_rows"], "a refused shared Off row never serves a guessed fallback")
		AssertTrue(_MM_MANIFEST_ROOT_CACHE == SavedCache, "the exact prior manifest owner is restored")
		AssertTrue(_LLM_Menu["user_profiles"] == SavedMenuProfiles, "the exact prior menu profiles are restored")
		AssertTrue(_LLM_Engine["user_profiles"] == SavedEngineProfiles, "the exact prior engine profiles are restored")
	}
}
Test("LLM live mode: shared Off label edits preserve actual native prompt uniqueness",
	_LLV_DeclaredOffLabelOwnsUniqueness)

; A durable menu profile choice retires its temporary shortcut override.
_LLV_ManualProfileRetiresOverride() {
	_LLV_Run(LLV_SENTENCE, (Calls, Lines, Builds) => _Check())
	_Check() {
		global _LLM_Menu, _LLM_Engine
		LLM_Engine_LiveStart("translate_ja", 0)
		AssertTrue(LLM_Engine_LiveIsActive(), "precondition: the shortcut override is active")
		_LLM_Menu["profile_id"] := "advanced"
		AssertTrue(_LLM_Menu_ApplyProfileCommitted(), "the actual post-commit owner applies the chosen profile")
		AssertFalse(LLM_Engine_LiveIsActive(), "manual selection cannot retain the temporary override")
		AssertEqual("advanced", _LLM_Engine["profile_id"], "the chosen normal profile reaches the real engine")
		Setter := _DriverFuncBody("LLM_Menu_SetProfile")
		AssertContains(Setter, "_LLM_Menu_ApplyProfileCommitted", "the genuine manual transaction consumes this owner")
	}
}
Test("LLM live mode: manual profile publication retires the temporary shortcut override", _LLV_ManualProfileRetiresOverride)
