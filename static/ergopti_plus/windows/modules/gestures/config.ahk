; modules/gestures/config.ahk

; ==============================================================================
; MODULE: Gesture Configuration & Touchpad Setup (AHK)
; DESCRIPTION:
; Reads/writes gesture slot assignments, applies the PrecisionTouchPad gesture
; mapping to the Windows registry, restarts the touchpad device to reload it,
; and renders the manual-setup tutorial. Extracted from modules/gestures.ahk so
; the touchpad-config and onboarding logic lives on its own, away from the
; gesture catalog, dispatch and action implementations.
;
; STATE & LIFECYCLE:
; These are plain functions in the global namespace. The on-load setup that
; calls them (GesturesReadConfig(), the AutoConfigureOnNextStart consumer and
; its deferred SetTimer) stays at the top level of gestures.ahk; AHK resolves
; the calls across includes at load time.
; ==============================================================================

#Requires AutoHotkey v2.0

; Reads gesture assignments from the v2 [gestures] section.
GesturesReadConfig() {
		global GestureAssignments, GestureActionParameters, _IniCache, GESTURE_ACTIONS

		for _, Slot in GESTURE_SLOTS {
				Value := IniCacheGet(_IniCache, "gestures", Slot)
				if (Value == "_")
						continue
				; Validate exactly as the keyboard-shortcut sibling does. Without this,
				; an action id that no longer exists (renamed, or from a newer config)
				; loaded verbatim and was dispatched — where GestureInvokeAction's own
				; guard dropped it silently. The gesture fired, produced nothing, and
				; logged nothing, which is indistinguishable from the gesture not being
				; recognised at all.
				if (Value == "none" or GESTURE_ACTIONS.Has(Value)) {
						GestureAssignments[Slot] := Value
				} else {
						try LoggerWarn("gestures", "Slot '{1}' is bound to unknown action '{2}' — keeping the default.", Slot, Value)
				}
		}
		; Rebuild this map on every read: a reload must reflect the user TOML
		; exactly and must not retain a value deleted from disk in this process.
		GestureActionParameters := Map()
		if _IniCache.Has("action_parameters") {
				for BindingAction, Value in _IniCache["action_parameters"]
						GestureActionParameters[BindingAction] := Value
		}
}

; Saves a single gesture assignment to the v2 [gestures] section.
GestureSaveAssignment(slot, action, WriterFn := 0, NotifyFn := 0) {
		global GestureAssignments, GestureActionParameters
		return _GestureCommitAssignment(&GestureAssignments, &GestureActionParameters,
				"gestures", slot, action, Map("has_value", false), WriterFn, NotifyFn)
}

; Parameters are scoped to an action binding, so one gesture, tap-hold or
; shortcut never overwrites the configured value of another binding.
GestureBindingId(Scope, Slot) {
		return Scope . "__" . Slot
}

GestureActionParameterKey(BindingId, ActionName) {
		return BindingId . "__" . ActionName
}

GestureGetActionParameter(BindingId, ActionName) {
		global GestureActionParameters
		Key := GestureActionParameterKey(BindingId, ActionName)
		return GestureActionParameters.Has(Key) ? GestureActionParameters[Key] : ""
}

GestureSetActionParameter(BindingId, ActionName, Value, WriterFn := 0, NotifyFn := 0) {
		if IsSet(ProgramActions_Stop) && ProgramActions_Stop() != true
				return false
		global GestureActionParameters, ConfigurationFile
		Key := GestureActionParameterKey(BindingId, ActionName)
		CandidateParameters := GestureActionParameters.Clone()
		CandidateParameters[Key] := Value
		Updates := [{ Section: "action_parameters", Key: Key, Value: Value }]
		if !ConfigCommitUpdates(ConfigurationFile, Updates,
				"the parameter for action '" . ActionName . "'", WriterFn, NotifyFn)
				return false
		GestureActionParameters := CandidateParameters
		return true
}

; The parameter kind the generated catalogue declares for an action ("url",
; "search_url", "wrap_pair", "text", "key", "shortcut", "llm_prompt",
; "llm_vision", "llm_language", "app"), or "" when it takes none.
GestureActionParameterSpec(ActionName) {
		global GESTURE_ACTION_CATALOGUE
		return GESTURE_ACTION_CATALOGUE.Actions.Has(ActionName)
				? GESTURE_ACTION_CATALOGUE.Actions[ActionName].Parameter : ""
}

GestureValidateActionParameter(ActionName, Value, &ErrorText := "") {
		Spec := GestureActionParameterSpec(ActionName)
		if Spec == "program" {
				if IsSet(ProgramParameterParse) && (ProgramParameterParse(Value) is Map)
						return true
				ErrorText := t("dialog.gestures.param_err_program")
				return false
		}
		if (Spec = "")
				return true
		; Checked before the trim below: the spaces of a text to type are part of it,
		; and the key and shortcut rules trim for themselves.
		if (Spec = "text" || Spec = "key" || Spec = "shortcut") {
				if (SendInputParse(Spec, Value) is Map)
						return true
				ErrorText := GestureSendInputErrorText(Spec)
				return false
		}
		; Syntax only, before the trim too: a padded value is not the one the
		; shared rules accept. Whether the prompt still exists is checked when the
		; action runs, so deleting a prompt never invalidates the configuration.
		if (Spec = "llm_prompt") {
				if (LLM_PromptAction_Parse(Value) is Map)
						return true
				ErrorText := t("dialog.gestures.param_err_llm_prompt")
				return false
		}
		; Syntax only as well: whether the provider has a key is checked at run time.
		if (Spec = "llm_vision") {
				if LLM_Vision_IsValid(Value)
						return true
				ErrorText := t("dialog.gestures.param_err_llm_vision")
				return false
		}
		; Syntax only, before the trim too: the shared rule refuses a padded value.
		; Whether the application exists is checked when it opens.
		if (Spec = "app") {
				if GestureAppParameterIsValid(Value)
						return true
				ErrorText := t("dialog.gestures.param_err_app")
				return false
		}
		; A closed list: "ui" or a shipped locale code, compared exactly.
		if (Spec = "llm_language") {
				if LLM_Translate_IsValid(Value)
						return true
				ErrorText := t("dialog.gestures.param_err_llm_language")
				return false
		}
		Value := Trim(Value)
		if (Spec = "wrap_pair") {
				if (GestureWrapPairFor(Value) is Map)
						return true
				ErrorText := t("dialog.gestures.param_err_wrap_pair")
				return false
		}
		if (Spec != "url" && Spec != "search_url")
				throw ValueError("No validator for parameter kind '" . Spec . "'.")
		if !RegExMatch(Value, "i)^https?://[^\s]+$") {
				ErrorText := t("dialog.gestures.param_err_url")
				return false
		}
		PlaceholderAt := InStr(Value, "%s")
		if (Spec = "search_url" && PlaceholderAt = 0) {
				ErrorText := t("dialog.gestures.param_err_no_placeholder")
				return false
		}
		if (Spec = "search_url" && InStr(Value, "%s",, PlaceholderAt + 2) != 0) {
				ErrorText := t("dialog.gestures.param_err_many_placeholders")
				return false
		}
		return true
}

; The text a binding editor shows to ask for an action's parameter. The %s
; inside the search-URL prompt is LITERAL — it is the placeholder the user has
; to type — so no prompt is run through a formatter; the title and the
; wrap-pair list use {1} so the two can never be confused.
; @param {String} ActionName An action that takes a parameter.
; @returns {String}
GestureActionParameterPrompt(ActionName) {
		global _WS_BUILTIN_PAIRS
		switch GestureActionParameterSpec(ActionName) {
				case "program":
						return t("dialog.gestures.param_program")
				case "search_url":
						return t("dialog.gestures.param_search_url")
				case "url":
						return t("dialog.gestures.param_link")
				case "app":
						return t("dialog.gestures.param_app")
				case "wrap_pair":
						return StrReplace(t("dialog.gestures.param_wrap_pair"), "{1}",
								WrapPairDescribe(_WS_BUILTIN_PAIRS))
				case "text":
						return StrReplace(t("dialog.gestures.param_text"), "{1}",
								SendInputVocabulary()["text_max_code_points"])
				case "key", "shortcut":
						return StrReplace(t("dialog.gestures.param_" . GestureActionParameterSpec(ActionName)),
								"{1}", SendInputDescribeKeys())
				case "llm_prompt":
						return StrReplace(t("dialog.gestures.param_llm_prompt"), "{1}",
								LLM_Menu_PromptChoicesText())
				case "llm_vision":
						return StrReplace(t("dialog.gestures.param_llm_vision"), "{1}",
								LLM_Vision_BackendChoicesText())
				case "llm_language":
						return StrReplace(t("dialog.gestures.param_llm_language"), "{1}",
								LLM_Translate_ChoicesText())
		}
		throw ValueError("No prompt for the parameter of action '" . ActionName . "'.")
}

; A value the action picker's own editor collected for the action it just
; confirmed (send_text, send_key, send_shortcut), held for the next parameter
; prompt of that action only: the picker's confirm callback runs the same
; assignment as a native pick, and this is how its value reaches it.
global _GesturePickedParameter := ""

; @param {String} ActionName The action the picker confirmed.
; @param {String} Value The value its editor collected.
GestureOfferPickedParameter(ActionName, Value) {
		global _GesturePickedParameter
		_GesturePickedParameter := Map("action", ActionName, "value", Value)
}

GestureClearPickedParameter() {
		global _GesturePickedParameter
		_GesturePickedParameter := ""
}

; The refusal of a send_text, send_key or send_shortcut value. The action
; picker's own editor shows the same text as the native prompt.
; @param {String} Spec "text", "key" or "shortcut".
; @returns {String}
GestureSendInputErrorText(Spec) {
		return StrReplace(t("dialog.gestures.param_err_" . Spec), "{1}",
				SendInputVocabulary()["text_max_code_points"])
}

; Builds a detached action-parameter candidate. Cancel is represented by false;
; a Map always means the user accepted and no persistence happened yet. A value
; the picker's editor collected for this action is used without a prompt when it
; validates, and prefills the prompt when it does not.
GesturePromptActionParameter(BindingId, ActionName) {
		global _GesturePickedParameter
		Spec := GestureActionParameterSpec(ActionName)
		if (Spec = "")
				return Map("has_value", false)
		Existing := GestureGetActionParameter(BindingId, ActionName)
		if (_GesturePickedParameter is Map) && (_GesturePickedParameter["action"] == ActionName) {
				Picked := _GesturePickedParameter["value"]
				GestureClearPickedParameter()
				if GestureValidateActionParameter(ActionName, Picked)
						return Map("has_value", true,
								"key", GestureActionParameterKey(BindingId, ActionName),
								"value", Picked)
				LoggerWarn("gestures", "The picker's value for '{1}' was refused — asking again.", ActionName)
				Existing := Picked
		}
		Prompt := GestureActionParameterPrompt(ActionName)
		Title  := StrReplace(t("dialog.gestures.param_title"), "{1}", _GestureActionLabel(ActionName))
		if Spec == "program"
				return _GesturePickProgram(BindingId, ActionName, Title, Existing)
		if (Spec = "app")
				return _GesturePickApplication(BindingId, ActionName, Prompt)
		loop {
				; The wrap-pair, shortcut and prompt-choice prompts list a catalogue under their text.
				Listed := (Spec = "wrap_pair" || Spec = "shortcut" || Spec = "llm_prompt" || Spec = "llm_vision")
				Size := Listed ? "w680 h300" : (Spec = "key") ? "w680 h220" : "w680 h160"
				; One line per shipped locale: the language list needs the height of 22 rows
				if (Spec = "llm_language")
						Size := "w680 h560"
				Result := Ui_InputBox(Prompt, Title, Size, Existing)
				if (Result.Result != "OK")
						return false
				; A text to type keeps its spaces; every other kind is trimmed.
				Value := (Spec = "text") ? Result.Value : Trim(Result.Value)
				ErrorText := ""
				if GestureValidateActionParameter(ActionName, Value, &ErrorText)
						return Map("has_value", true,
								"key", GestureActionParameterKey(BindingId, ActionName),
								"value", Value)
				Ui_MsgBox(ErrorText, t("dialog.gestures.param_error_title"), "Icon!")
				Existing := Value
		}
}

; The shared app rule (_shared/tests/corpus/action_parameters/app_vectors.json):
; not empty, no leading or trailing whitespace, no control character.
; @param {Any} Value
; @returns {Boolean}
GestureAppParameterIsValid(Value) {
		return (Value is String) && (Value != "") && !RegExMatch(Value, "^\s|\s$|[\x00-\x1F\x7F]")
}

; FileSelect: the file and its path must exist, and a Start-menu shortcut is
; kept as the shortcut rather than resolved to its target.
global GESTURE_APP_CHOOSER_OPTIONS := 1 + 2 + 32

; Picks the application an open_app binding launches, starting in the
; Start menu, instead of asking for a name to type.
; @returns {Map|false} The parameter candidate, false when cancelled or refused.
_GesturePickApplication(BindingId, ActionName, Prompt) {
		global GESTURE_APP_CHOOSER_OPTIONS
		Picked := Ui_FileSelect(GESTURE_APP_CHOOSER_OPTIONS, A_ProgramsCommon, Prompt,
				t("dialog.gestures.param_app_filter") . " (*.exe; *.lnk)")
		if (Picked = "")
				return false
		ErrorText := ""
		if GestureValidateActionParameter(ActionName, Picked, &ErrorText)
				return Map("has_value", true,
						"key", GestureActionParameterKey(BindingId, ActionName),
						"value", Picked)
		Ui_MsgBox(ErrorText, t("dialog.gestures.param_error_title"), "Icon!")
		return false
}

; Commits an assignment and its optional parameter as one logical TOML batch,
; then atomically publishes detached assignment/parameter Maps.
_GestureCommitAssignment(&AssignmentsTarget, &ParametersTarget, AssignmentSection, Slot, ActionName, ParameterCandidate, WriterFn := 0, NotifyFn := 0) {
		global ConfigurationFile
		if !(ParameterCandidate is Map)
				return false
		if !GestureActionIsAssignable(ActionName) {
				try LoggerWarn("gestures", "Refusing unknown action '{1}' for slot '{2}'.", ActionName, Slot)
				return false
		}
		if IsSet(ProgramActions_Stop) && ProgramActions_Stop() != true
				return false
		CandidateAssignments := AssignmentsTarget.Clone()
		CandidateParameters := ParametersTarget.Clone()
		CandidateAssignments[Slot] := ActionName
		Updates := [{ Section: AssignmentSection, Key: Slot, Value: ActionName }]
		if ParameterCandidate.Get("has_value", false) {
				if !ParameterCandidate.Has("key") or !ParameterCandidate.Has("value")
						throw ValueError("Parameterized action candidate is incomplete.")
				ParameterKey := ParameterCandidate["key"]
				ParameterValue := ParameterCandidate["value"]
				CandidateParameters[ParameterKey] := ParameterValue
				Updates.Push({ Section: "action_parameters", Key: ParameterKey, Value: ParameterValue })
		}
		if !ConfigCommitUpdates(ConfigurationFile, Updates,
				"the action assignment for '" . Slot . "'", WriterFn, NotifyFn)
				return false
		PreviousCritical := Critical("On")
		try {
				AssignmentsTarget := CandidateAssignments
				ParametersTarget := CandidateParameters
		} finally {
				Critical(PreviousCritical)
		}
		return true
}

; Prompts when needed, then commits the related parameter + assignment once.
GestureAssignConfiguredAction(&AssignmentsTarget, Scope, AssignmentSection, Slot, ActionName, WriterFn := 0, NotifyFn := 0) {
		if ActionName == "run_program" && (!IsSet(ProgramActions_BindingSupported)
				|| !ProgramActions_BindingSupported(GestureBindingId(Scope, Slot)))
				return false
		global GestureActionParameters
		if !GestureActionIsAssignable(ActionName) {
				try LoggerWarn("gestures", "Refusing unknown action '{1}' for slot '{2}'.", ActionName, Slot)
				return false
		}
		ParameterCandidate := GesturePromptActionParameter(
				GestureBindingId(Scope, Slot), ActionName)
		if !(ParameterCandidate is Map)
				return false
		return _GestureCommitAssignment(&AssignmentsTarget, &GestureActionParameters,
				AssignmentSection, Slot, ActionName, ParameterCandidate, WriterFn, NotifyFn)
}

; Compatibility entry point used by the tap-hold writer, whose assignment lives
; in a separate file and therefore cannot join the config.toml batch.
GestureEnsureActionParameter(BindingId, ActionName, WriterFn := 0, NotifyFn := 0) {
		ParameterCandidate := GesturePromptActionParameter(BindingId, ActionName)
		if !(ParameterCandidate is Map)
				return false
		if !ParameterCandidate.Get("has_value", false)
				return true
		return GestureSetActionParameter(BindingId, ActionName,
				ParameterCandidate["value"], WriterFn, NotifyFn)
}

GestureActionDisplayLabel(ActionName, BindingId := "") {
		Label := _GestureActionLabel(ActionName)
		if GestureActionParameterSpec(ActionName) == "program"
				return Label
		if (BindingId = "")
				return Label
		Value := GestureGetActionParameter(BindingId, ActionName)
		if (Value = "")
				return Label
		if !RegExMatch(Label, "\[[^\[\]]*\]$", &Marker)
				throw ValueError("Parameterized action label has no configurable marker: " . ActionName)
		return SubStr(Label, 1, Marker.Pos - 1) . "[" . Value . "]"
}

; Preserve the zero-argument contract for ordinary actions (including user
; extensions) while passing binding context only to actions that declare it.
; An action the catalogue declares `confirm = true` (empty_trash,
; unblock_file_selection, force_quit_frontmost) only asks here, off the hotkey
; thread; it runs from the answer. Sys is the SystemControl adapter, a recording double in tests.
GestureInvokeAction(ActionName, BindingId := "", Sys := 0) {
		Target := 0
		Scheduled := false
		try {
			global GESTURE_ACTIONS, GESTURE_ACTIONS_ON_ACTIVE_WINDOW
			if !GESTURE_ACTIONS.Has(ActionName)
					return
			if GestureActionNeedsConfirm(ActionName) {
					Sys := IsObject(Sys) ? Sys : SystemControl()
					Target := _GestureCopyWindowSnapshot(Sys.ActiveWindow())
					if GESTURE_ACTIONS_ON_ACTIVE_WINDOW.Has(ActionName) {
							if !_GestureConfirmedTargetIsLive(Target, Sys) {
									LoggerWarn("gestures", "'{1}' was refused before confirmation: no original window target is owned.", ActionName)
									return false
							}
							if ActionName == "force_quit_frontmost" {
									Resolved := GestureSysForceQuitTarget(Target, Sys)
									if Resolved.Refusal != "" {
											LoggerWarn("gestures", "'{1}' was refused before confirmation: {2}.", ActionName, Resolved.Refusal)
											return false
									}
									Target.TargetPid := Resolved.Pid
									Target.ProcessLease := Sys.AcquireProcessTarget(Resolved.Pid)
									if !_GestureConfirmedTargetIsLive(Target, Sys) {
											LoggerWarn("gestures", "'{1}' was refused before confirmation: its acquired process target is no longer owned.", ActionName)
											return false
									}
							}
					}
					Sys.Defer(_GestureConfirmThenInvoke.Bind(ActionName, BindingId, Target, Sys))
					Scheduled := true
					return
			}
			return _GestureRunAction(ActionName, BindingId)
		} catch as Err {
				LoggerError("gestures", "Action '{1}' failed during confirmation preflight: {2}.", ActionName, Err.Message)
				return false
		} finally {
				if !Scheduled
						_GestureReleaseProcessTarget(Target, Sys)
		}
}

; The actions that read the active window only once they run: its process
; (quit, force quit) or its Explorer selection. Confirmed, each runs only when
; the window the question was asked from got its focus back; an action outside
; this set runs whichever window is active.
global GESTURE_ACTIONS_ON_ACTIVE_WINDOW := Map("quit_frontmost_app", true, "force_quit_frontmost", true,
		"unblock_file_selection", true)

; Whether the generated catalogue asks to confirm an action before it runs.
GestureActionNeedsConfirm(ActionName) {
		global GESTURE_ACTION_CATALOGUE
		return IsSet(GESTURE_ACTION_CATALOGUE) && GESTURE_ACTION_CATALOGUE.Actions.Has(ActionName)
				&& GESTURE_ACTION_CATALOGUE.Actions[ActionName].Confirm
}

; Asks whether a destructive action may run (Cancel is the default button),
; then gives the window the user acted on its focus back and runs it. The
; question can outlive a Suspend, which disarms hotkeys and not this thread.
; Native reads remain contained here because this timer is outside the
; registered action runner's containment.
; When that window cannot get its focus back, an action that reads the active
; window does not run: the active window is then another one, which
; force_quit_frontmost would kill. Any other action (empty_trash) still runs.
; Detaches the admitted window from an adapter or extension's mutable state.
_GestureCopyWindowSnapshot(Window) {
	if !IsObject(Window)
		return ""
	if !Window.HasOwnProp("Hwnd") || !Window.HasOwnProp("Pid") || !Window.HasOwnProp("Class")
		throw TypeError("A confirmed window target requires HWND, PID and class.")
	if !(Window.Hwnd is Integer) || !Window.Hwnd || !(Window.Pid is Integer) || Window.Pid <= 0
		return ""
	if !(Window.Class is String) || Window.Class == ""
		return ""
	return { Hwnd: Window.Hwnd, Pid: Window.Pid, Class: Window.Class }
}

; Validates the original window receipt, never whichever window is foreground
; now. A packaged app also retains the PID behind its original shared frame.
_GestureConfirmedTargetIsLive(Target, Sys) {
	if !IsObject(Target)
		return false
	Current := Sys.WindowSnapshot(Target.Hwnd)
	if !IsObject(Current) || Current.Hwnd != Target.Hwnd || Current.Pid != Target.Pid || !(Current.Class == Target.Class)
		return false
	if Target.HasOwnProp("TargetPid") {
		if !Target.HasOwnProp("ProcessLease") || !IsObject(Target.ProcessLease)
			|| !Target.ProcessLease.HasOwnProp("Pid") || Target.ProcessLease.Pid != Target.TargetPid
			|| !Sys.ProcessTargetIsLive(Target.ProcessLease)
			return false
		Resolved := GestureSysForceQuitTarget(Target, Sys)
		if Resolved.Refusal != "" || Resolved.Pid != Target.TargetPid
			return false
	}
	return true
}
; Claims the release debt before native cleanup so reentrant cancellation cannot
; close an already-released handle or a handle later reused by another owner.
_GestureReleaseProcessTarget(Target, Sys) {
	if !IsObject(Target)
		return
	PreviousCritical := Critical("On")
	try {
		if !Target.HasOwnProp("ProcessLease")
			return
		Lease := Target.ProcessLease
		Target.DeleteProp("ProcessLease")
		if Target.HasOwnProp("ProcessLeaseDeferred")
			Target.DeleteProp("ProcessLeaseDeferred")
	} finally Critical(PreviousCritical)
	try Sys.ReleaseProcessTarget(Lease)
	catch as Err {
		LoggerError("gestures", "The confirmed process target could not be released: {1}.", Err.Message)
	}
}

_GestureConfirmThenInvoke(ActionName, BindingId, Target, Sys) {
		try {
			global GESTURE_ACTIONS_ON_ACTIVE_WINDOW
			if A_IsSuspended {
					LoggerInfo("gestures", "'{1}' was cancelled before its confirmation: the script is suspended.", ActionName)
					return false
			}
			if GESTURE_ACTIONS_ON_ACTIVE_WINDOW.Has(ActionName) && !_GestureConfirmedTargetIsLive(Target, Sys) {
					LoggerWarn("gestures", "'{1}' was refused before its question: its original window target is no longer owned.", ActionName)
					return false
			}
			if A_IsSuspended {
				LoggerInfo("gestures", "Confirmed action '{1}' was cancelled before its question: the script is suspended.", ActionName)
				return false
			}
			Label := _GestureActionLabel(ActionName)
			Answer := Sys.Ask(StrReplace(t("dialog.confirm_action.message"), "{1}", Label), t("dialog.confirm_action.title"))
			if (Answer != "OK") {
					LoggerInfo("gestures", "'{1}' was cancelled at its confirmation.", ActionName)
					return
			}
			if A_IsSuspended {
					LoggerInfo("gestures", "'{1}' was confirmed while the script was suspended — not run.", ActionName)
					return
			}
			LoggerInfo("gestures", "'{1}' was confirmed.", ActionName)
			if GESTURE_ACTIONS_ON_ACTIVE_WINDOW.Has(ActionName) && !_GestureConfirmedTargetIsLive(Target, Sys) {
					LoggerWarn("gestures", "'{1}' was refused after its question: its original window target is no longer owned.", ActionName)
					return false
			}
			if A_IsSuspended {
				LoggerInfo("gestures", "Confirmed action '{1}' was cancelled before focus restoration: the script is suspended.", ActionName)
				return false
			}
			if (IsObject(Target) && !Sys.Activate(Target.Hwnd)) {
					if GESTURE_ACTIONS_ON_ACTIVE_WINDOW.Has(ActionName) {
							LoggerWarn("gestures", "'{1}': the window it was asked from could not be reactivated — not run.", ActionName)
							return
					}
					LoggerWarn("gestures", "'{1}': the window it was asked from could not be reactivated.", ActionName)
			}
			if A_IsSuspended {
					LoggerInfo("gestures", "'{1}' was cancelled after focus restoration: the script is suspended.", ActionName)
					return false
			}
			if GESTURE_ACTIONS_ON_ACTIVE_WINDOW.Has(ActionName) && !_GestureConfirmedTargetIsLive(Target, Sys) {
					LoggerWarn("gestures", "'{1}' was refused after focus restoration: its original window target is no longer owned.", ActionName)
					return false
			}
			if A_IsSuspended {
				LoggerInfo("gestures", "Confirmed action '{1}' was cancelled before dispatch: the script is suspended.", ActionName)
				return false
			}
			_GestureRunAction(ActionName, BindingId, Target, Sys)
		} catch as Err {
				LoggerError("gestures", "Action '{1}' failed during confirmation callback: {2}.", ActionName, Err.Message)
				return false
		} finally {
				if !IsObject(Target) || !Target.HasOwnProp("ProcessLeaseDeferred")
						_GestureReleaseProcessTarget(Target, Sys)
		}
}

; Runs one registered action, contained and timed.
_GestureRunAction(ActionName, BindingId, ConfirmedTarget := 0, Sys := 0) {
		global GESTURE_ACTIONS
		; The single choke point all three dispatchers share (gesture, keyboard-shortcut
		; slot, tap-hold), so one segment here covers every user-triggered action.
		; A slow action was previously attributable to nothing: the gesture ended, the
		; effect arrived late, and the log said nothing about which action it was.
		_hpGesture := HotPath_Now()
		Fn := GESTURE_ACTIONS[ActionName].Fn
		; Containment lives HERE, at the single choke point all three dispatchers share
		; (gesture, keyboard-shortcut slot, tap-hold). Only GestureDispatch wrapped the
		; call, so a throwing action reached via a shortcut slot (RunKeyboardShortcutAction)
		; or a tap-hold (_TapHoldInvokeConfiguredAction) propagated uncaught into the error
		; net. Fail loud in the log, never rethrow (§5.3) — every dispatcher keeps working.
		try {
				if IsObject(ConfirmedTarget) && GESTURE_ACTIONS[ActionName].HasOwnProp("ConfirmedFn")
						Result := GESTURE_ACTIONS[ActionName].ConfirmedFn.Call(ConfirmedTarget, Sys)
				else if (GestureActionParameterSpec(ActionName) != "")
						Result := Fn.Call(BindingId)
				else
						Result := Fn.Call()
				HotPath_LogIfSlow("Gesture.Invoke", _hpGesture, ActionName)
				return Result
		} catch as e {
				; The throwing path is timed too: an action that spends a second before
				; failing costs the user exactly as much as one that spends a second
				; succeeding
				HotPath_LogIfSlow("Gesture.Invoke", _hpGesture, ActionName . " (threw)")
				LoggerError("gestures", "Action '{1}' (binding '{2}') threw: {3}.", ActionName, BindingId, e.Message)
		}
}

GestureSaveAllAssignments(ActionNameBySlot, WriterFn := 0, NotifyFn := 0) {
		global GestureAssignments, ConfigurationFile
		CandidateAssignments := GestureAssignments.Clone()
		Updates := []
		for Slot, ActionName in ActionNameBySlot {
				CandidateAssignments[Slot] := ActionName
				Updates.Push({ Section: "gestures", Key: Slot, Value: ActionName })
		}
		if !ConfigCommitUpdates(ConfigurationFile, Updates,
				"the gesture assignment batch", WriterFn, NotifyFn)
				return false
		GestureAssignments := CandidateAssignments
		return true
}

/** Clear cancels pending native setup; recommendations preserve explicit intent. */
GestureScopeResetOperations(ScopeId, Mode) {
	if ScopeId != "gestures" || !(Mode == "recommended" || Mode == "clear")
		throw ValueError("Gesture persistence cannot reset another configuration scope.")
	if Mode == "recommended"
		return []
	Section := "gestures", Key := "auto_configure_on_next_start"
	if TomlConfigForeignOwner(Section, Key) != "Gestures"
		throw Error("The queued native setup marker has no matching gesture owner.")
	return [{ Section: Section, Key: Key, Delete: true }]
}

; Consumes the onboarding marker before arming any elevated/PnP side effect.
; TimerFn is injectable so a failed commit can be proven to schedule nothing.
GestureConsumeAutoConfigureFlag(Path, WriterFn := 0, NotifyFn := 0, TimerFn := 0) {
		global GESTURE_AUTO_CONFIGURE_BOOT_DELAY_MS
		LoggerStart("gestures", "Consuming auto_configure_on_next_start flag from onboarding…")
		Updates := [{ Section: "gestures", Key: "auto_configure_on_next_start", Value: TOML_Bool(false) }]
		if !ConfigCommitUpdates(Path, Updates,
				"the onboarding auto-configuration marker", WriterFn, NotifyFn) {
				LoggerError("gestures", "AutoConfigureOnNextStart flag was not cleared — touchpad configuration was not scheduled.")
				return false
		}
		if HasMethod(TimerFn, "Call")
				TimerFn.Call(_DeferredGestureAutoConfigure, -GESTURE_AUTO_CONFIGURE_BOOT_DELAY_MS)
		else
				SetTimer(_DeferredGestureAutoConfigure, -GESTURE_AUTO_CONFIGURE_BOOT_DELAY_MS)
		LoggerSuccess("gestures", "AutoConfigureOnNextStart flag cleared — touchpad config deferred to T+2s.")
		return true
}

; Configures Windows touchpad gestures via the registry so that all 10 gesture
; slots send Ctrl+Win+Shift+F1..F10 without any manual Settings configuration.
; The values come from the generated touchpad table and are written by its one
; owner (modules/gestures/touchpad_registry.ahk), which backs up the prior
; values before the first write so « Restaurer les gestes du pavé tactile
; Windows » can put them back.
; Returns true on success, false if the backup or any registry write failed.
GestureAutoConfigureRegistry(OnDone := 0) {
		LoggerStart("gestures", "Auto-configuring touchpad gestures via registry…")
		if !TouchpadRegistryApply() {
				LoggerError("gestures", "Auto-configuration failed: the touchpad values were not all written.")
				return False
		}

		; The PrecisionTouchPad driver caches gesture mappings in kernel-mode
		; and ignores WM_SETTINGCHANGE — the only reliable way to apply changes
		; without a logout is to disable then re-enable the touchpad PnP device,
		; which is exactly what Windows Settings does internally on apply.
		if !GestureRestartTouchpadDevice(OnDone) {
				LoggerError("gestures", "Gesture registry values were written but the touchpad restart could not be started.")
				return False
		}

		LoggerSuccess("gestures", "All gesture registry values written; touchpad restart is running asynchronously.")
		return True
}

; Disables then re-enables the touchpad PnP device to force the gesture
; driver to reload its configuration from the registry. Requires admin
; elevation — triggers a UAC prompt via the *RunAs verb.
global _GestureRestartJob := Map("epoch", 0, "pid", 0, "script", "", "result", "", "done", 0,
		"starting", false)

_GestureRestartReserve(Candidate, TimerFn := 0) {
	global _GestureRestartJob
	if !(Candidate is Map) || !Candidate.Get("starting", false)
		throw TypeError("Gesture restart reservation requires a starting candidate.")
	PreviousCritical := Critical("On")
	try {
		if _GestureRestartJob.Get("starting", false) || _GestureRestartJob["pid"]
			return false
		; Arm completion first, then publish while this thread is non-interruptible.
		; The poller handles the UAC interval where Candidate has no PID yet.
		PollFn := _GestureRestartPoll.Bind(Candidate["epoch"])
		if HasMethod(TimerFn, "Call")
			TimerFn.Call(PollFn, -100)
		else
			SetTimer(PollFn, -100)
		_GestureRestartJob := Candidate
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

_GestureRestartAbortReservation(Epoch) {
	global _GestureRestartJob
	PreviousCritical := Critical("On")
	try {
		if (_GestureRestartJob["epoch"] == Epoch
				&& _GestureRestartJob.Get("starting", false)) {
			_GestureRestartJob["starting"] := false
			_GestureRestartJob["done"] := 0
		}
	} finally {
		Critical(PreviousCritical)
	}
}

GestureRestartTouchpadDevice(OnDone := 0) {
		global _GestureRestartJob
		LoggerStart("gestures", "Restarting touchpad device to apply gesture config…")
		if _GestureRestartJob.Get("starting", false) {
				LoggerError("gestures", "Touchpad restart launch is already pending.")
				return False
		}
		if _GestureRestartJob["pid"] {
				if FileExist(_GestureRestartJob["result"])
						_GestureRestartPoll(_GestureRestartJob["epoch"])
				else if ProcessExist(_GestureRestartJob["pid"]) {
						LoggerError("gestures", "Touchpad restart is already running.")
						return False
				} else
						_GestureRestartPoll(_GestureRestartJob["epoch"])
				if _GestureRestartJob["pid"] {
						LoggerError("gestures", "Touchpad restart completion is pending.")
						return False
				}
		}

		Epoch := _GestureRestartJob["epoch"] + 1
		JobStem := A_Temp . "\ergopti_touchpad_restart_" . DriverPid . "_" . Epoch
		ScriptPath := JobStem . ".ps1"
		ResultPath := JobStem . ".result"
		Candidate := Map("epoch", Epoch, "pid", 0, "script", ScriptPath,
				"result", ResultPath, "done", OnDone, "starting", true)
		try Reserved := _GestureRestartReserve(Candidate)
		catch as e {
				LoggerError("gestures", "Could not arm touchpad restart completion: {1}.", e.Message)
				return False
		}
		if !Reserved {
				LoggerError("gestures", "Touchpad restart launch is already pending.")
				return False
		}
		FSDelete(ResultPath)
		FSDelete(ResultPath . ".stage")
		if !FSWrite(ScriptPath, _GestureRestartBuildPsScript(ResultPath)) {
				_GestureRestartAbortReservation(Epoch)
				LoggerError("gestures", "Could not write touchpad restart worker.")
				return False
		}

		try {
				; A UAC-approved PnP restart can take tens of seconds. The child writes
				; its own outcome, and the driver only polls it — no hook, timer, or
				; tray callback waits on the worker.
				Run('*RunAs powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' . ScriptPath . '"', , "Hide", &RestartPid)
		} catch as e {
				FSDelete(ScriptPath)
				_GestureRestartAbortReservation(Epoch)
				LoggerError("gestures", "Failed to restart touchpad device: {1}.", e.Message)
				return False
		}
		PreviousCritical := Critical("On")
		try {
				if (_GestureRestartJob["epoch"] != Epoch
						|| !_GestureRestartJob.Get("starting", false))
						throw Error("Touchpad restart reservation was lost before PID publication.")
				_GestureRestartJob["pid"] := RestartPid
				_GestureRestartJob["starting"] := false
		} finally {
				Critical(PreviousCritical)
		}
		LoggerSuccess("gestures", "Touchpad restart worker launched (PID {1}).", RestartPid)
		return True
}

_GestureRestartPoll(Epoch) {
		global _GestureRestartJob
		if (_GestureRestartJob["epoch"] != Epoch)
				return
		if _GestureRestartJob.Get("starting", false) {
				SetTimer(_GestureRestartPoll.Bind(Epoch), -100)
				return
		}
		if !_GestureRestartJob["pid"]
				return
		; Suspend does not stop timers. Preserve the completion until the driver
		; resumes rather than presenting status or invoking a user callback while
		; suspended.
		if A_IsSuspended {
				SetTimer(_GestureRestartPoll.Bind(Epoch), -100)
				return
		}
		; A complete atomic result is authoritative even if Windows has recycled
		; the launch PID. Liveness is only an advisory while no receipt exists.
		if !FileExist(_GestureRestartJob["result"])
				&& ProcessExist(_GestureRestartJob["pid"]) {
				SetTimer(_GestureRestartPoll.Bind(Epoch), -100)
				return
		}
		Ok := _GestureRestartReadResult(_GestureRestartJob["result"])
		Done := _GestureRestartJob["done"]
		FSDelete(_GestureRestartJob["script"])
		FSDelete(_GestureRestartJob["result"])
		FSDelete(_GestureRestartJob["result"] . ".stage")
		_GestureRestartJob["pid"] := 0
		_GestureRestartJob["done"] := 0
		if Ok
				LoggerSuccess("gestures", "Touchpad restart completed.")
		else
				LoggerError("gestures", "Touchpad restart failed or did not publish a result.")
		if IsObject(Done)
				try Done.Call(Ok)
}

_GestureRestartReadResult(ResultPath) {
		Result := FSRead(ResultPath)
		; Type-check the sentinel, never value-compare it. FSRead returns a String on
		; success and the BOOLEAN false on any failure, and the helper script writes
		; its exit code as a bare string whose SUCCESS value is "0" — a numeric
		; string that loosely equals false in v2. So `Result = false` was TRUE on
		; exactly the successful runs, which took the "missing" branch and made the
		; success return below unreachable: a working restart always reported failure.
		if !(Result is String) {
				try LoggerError("gestures", "Touchpad restart result missing.")
				return False
		}
		; Newlines must be trimmed EXPLICITLY: AHK v2's default OmitChars is " `t"
		; only, so a bare Trim() leaves a "0`r`n" payload unequal to "0". The helper
		; writes no newline today, but a switch to WriteAllLines would silently turn
		; every success back into a failure.
		; == and not =, so a numeric coercion cannot creep back in and accept
		; "0.0" / "+0" as the success code.
		return (Trim(Result, " `t`r`n") == "0")
}

_GestureRestartBuildPsScript(ResultPath) {
		CRLF := "`r`n"
		ResultLiteral := StrReplace(ResultPath, "'", "''")
		S := "$ErrorActionPreference = 'Stop'" . CRLF
		S .= "$ResultPath = '" . ResultLiteral . "'" . CRLF
		S .= "$ResultStage = $ResultPath + '.stage'" . CRLF
		S .= "$ErgoptiExitCode = 1" . CRLF
		S .= "$disabled = @()" . CRLF
		S .= "try {" . CRLF
		S .= "  $devs = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq 'HIDClass' -and $_.FriendlyName -match 'Input Configuration|I2C HID' })" . CRLF
		S .= "  if ($devs.Count -eq 0) { throw 'No Precision Touchpad HID device found.' }" . CRLF
		S .= "  foreach ($d in $devs) { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop; $disabled += $d }" . CRLF
		S .= "  Start-Sleep -Milliseconds 500" . CRLF
		S .= "  foreach ($d in $devs) { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop }" . CRLF
		S .= "  $ErgoptiExitCode = 0" . CRLF
		S .= "} catch {} finally { foreach ($d in $disabled) { try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop } catch {} } }" . CRLF
		S .= "try {" . CRLF
		S .= "  [System.IO.File]::WriteAllText($ResultStage, [string]$ErgoptiExitCode, [System.Text.Encoding]::ASCII)" . CRLF
		S .= "  [System.IO.File]::Move($ResultStage, $ResultPath)" . CRLF
		S .= "} catch { Remove-Item -LiteralPath $ResultStage -Force -ErrorAction SilentlyContinue; exit 1 }" . CRLF
		S .= "exit $ErgoptiExitCode" . CRLF
		return S
}

; Build the body of the manual-setup tutorial. Shared by the tray menu and the
; onboarding wizard so the wording stays in lockstep between them.
;
; Locale fragments already embed their own trailing newlines (one after each
; section, two after the header), so they are concatenated as-is here — adding
; extra ``\n`` separators surfaced as visible blank-line clutter inside the
; rendered popup.
; The slot data comes from the constants ACCESSORS, never from the GESTURE_SLOTS
; / GESTURE_SHORTCUT_LABELS globals. Those are top-level assignments in
; modules/gestures/init.ahk, included ~300 lines after ErgoptiPlus.ahk calls
; Onboarding_Run(), so during the whole first-run wizard they were unset — and
; the IsSet() guard that used to wrap this loop turned that into a silently
; EMPTY tutorial: the panel told the user to type the shortcut shown next to
; each gesture and then listed no gestures at all. A function has no include
; position, so this answers correctly whenever it is called.
GestureBuildSetupInstructions() {
		Body := t("gesture.setup.header") . t("gesture.setup.open_path") . t("gesture.setup.for_each")
		Labels := GestureShortcutLabels()
		for _, Slot in GestureSlotIds() {
				Body .= "  " . t("gesture.slots." . Slot) . " :  "
						. Labels[Slot] . "`n"
		}
		return Body
}

; Public entry point: shows the gesture setup tutorial in a single panel with
; a one-click "Open touchpad settings" shortcut to ms-settings:devices-touchpad.
; Replaces the previous two-step ``Show instructions`` + ``Open touchpad
; settings`` menu items — the user only needs one path now.
GestureShowManualTutorialDialog() {
		tg := Gui_Create("", t("onboarding.gestures.register_manual"))
		tg.SetFont("s9", "Segoe UI")
		tg.MarginX := 18
		tg.MarginY := 14
		
		; Instructions in a read-only Edit (selectable text).
		; Sized to fit the 10 slots without a scrollbar (h380).
		instructions := GestureBuildSetupInstructions()
		hEdit := tg.AddEdit("ReadOnly w480 h380 -Wrap", instructions)
		
		; Auto-configure hint placed OUTSIDE the selectable text area.
		tg.AddText("w480 y+12", t("gesture.setup.auto_configure"))
		
		tg.AddText("w480 y+10", t("onboarding.gestures.open_settings_hint"))
		
		; "Open settings" button gets the default focus.
		btnOpenSettings := tg.AddButton("Default w480 y+8", t("onboarding.gestures.open_settings"))
		btnOpenSettings.OnEvent("Click", (*) => GestureOpenTouchpadSettings())
		
		tg.OnEvent("Close", (*) => tg.Destroy())
		tg.OnEvent("Escape", (*) => tg.Destroy())
		
		tg.Show("AutoSize Center")
		
		; Force focus to the button so the Edit text is not selected on start,
		; and an immediate 'Enter' key triggers the settings.
		btnOpenSettings.Focus()
		; Clear any accidental selection in the edit control
		SendMessage(0x00B1, -1, 0, , "ahk_id " . hEdit.Hwnd) ; EM_SETSEL
}

; Opens Windows Settings to the touchpad page. Used both by the tutorial
; dialog's "Open settings" button and by the onboarding wizard.
GestureOpenTouchpadSettings() {
		try {
			Run("ms-settings:devices-touchpad")
			return true
		} catch as Err {
			LoggerError("gestures", "Touchpad settings could not open: {1}.", Err.Message)
			return false
		}
}

; One-shot SetTimer target used by the post-Reload AutoConfigureOnNextStart
; consumer. Wrapped as a named function because AHK fat-arrow lambdas cannot
; contain ``try`` (parser treats it as an identifier). Logs the lifecycle pair
; so a failure here is visible in the log.
_DeferredGestureAutoConfigure(*) {
		if A_IsSuspended {
				SetTimer(_DeferredGestureAutoConfigure, -250)
				return
		}
		LoggerStart("gestures", "Running deferred touchpad auto-configuration…")
		Started := false
		try {
				Started := GestureAutoConfigureRegistry(_DeferredGestureAutoConfigureDone)
		} catch as e {
				LoggerError("gestures", "Deferred auto-configuration threw: {1}.", e.Message)
				return
		}
		if !Started
				LoggerError("gestures", "Deferred touchpad auto-configuration could not start — user can retry from the tray menu.")
}

_DeferredGestureAutoConfigureDone(Ok) {
		if Ok
				LoggerSuccess("gestures", "Deferred touchpad auto-configuration completed.")
		else
				LoggerError("gestures", "Deferred touchpad auto-configuration failed — user can retry from the tray menu.")
}

; Native fallback edits the same executable and literal argv, never a command line.
_GesturePickProgram(BindingId, ActionName, Title, Existing) {
	if !IsSet(ProgramActions_Available) || !IsSet(ProgramActions_BindingSupported)
				|| !ProgramActions_Available() || !ProgramActions_BindingSupported(BindingId)
		return false
	Current := ProgramParameterParse(Existing)
	Arguments := (Current is Map) ? Current["arguments"].Clone() : []
	W := Gui_Create("", Title)
	W.Add("Text", "xm", t("dialog.action_picker.program_executable"))
	Executable := W.Add("Edit", "xm w560", (Current is Map) ? Current["executable"] : "")
	W.Add("Text", "xm", t("dialog.action_picker.program_arguments"))
	List := W.Add("ListBox", "xm w560 r6", Arguments)
	W.Add("Button", "xm", t("dialog.action_picker.program_add_argument")).OnEvent("Click", AddArgument)
	W.Add("Button", "x+8", t("dialog.action_picker.program_remove_argument")).OnEvent("Click", RemoveArgument)
	W.Add("Button", "xm", t("button.save")).OnEvent("Click", Save)
	W.Add("Button", "x+8", t("button.cancel")).OnEvent("Click", (*) => W.Destroy())
	Result := false
	W.OnEvent("Close", (*) => W.Destroy())
	W.OnEvent("Escape", (*) => W.Destroy())
	W.Show()
	WinWaitClose("ahk_id " . W.Hwnd)
	return Result
	AddArgument(*) {
		Picked := Ui_InputBox(t("dialog.action_picker.program_arguments"), Title, "w560 h240", "")
		if Picked.Result != "OK"
			return
		Arguments.Push(Picked.Value)
		List.Delete()
		List.Add(Arguments)
	}
	RemoveArgument(*) {
		Index := List.Value
		if Index <= 0
			return
		Arguments.RemoveAt(Index)
		List.Delete()
		List.Add(Arguments)
	}
	Save(*) {
		Items := ""
		for Index, Argument in Arguments
			Items .= (Index == 1 ? "" : ",") . JsonStringLiteral(Argument)
		Scalar := '{"version":1,"executable":' . JsonStringLiteral(Executable.Value) . ',"arguments":[' . Items . "]}"
		if !(ProgramParameterParse(Scalar) is Map)
			return
		Result := Map("has_value", true, "key", GestureActionParameterKey(BindingId, ActionName), "value", Scalar)
		W.Destroy()
	}
}
