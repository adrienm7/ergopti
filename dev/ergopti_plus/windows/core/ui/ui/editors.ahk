; core/ui/ui/editors.ahk

; ==============================================================================
; MODULE: Config Editors (GUI dialogs)
; DESCRIPTION:
; Small modal GUI editors for user-configurable values: the magic key, the
; repeat-key toggle and the ChatGPT link, plus the entry point of the WebView
; personal-information editor. Extracted verbatim from ErgoptiPlus.ahk (the
; entry-point decomposition) and #Include'd at the original position so boot
; order is unchanged. Functions are hoisted, so their menu/hotkey call sites
; elsewhere are unaffected.
; ==============================================================================

; The generated key vocabulary the word-reset and cascade settings are named by
; (a dedupe-safe include: menu_init.ahk and menu_manifest.ahk name it too).
#Include %A_LineFile%\..\..\..\..\_generated\config_keys.ahk
#Include %A_LineFile%\..\..\..\lifecycle\engine\value_check.ahk

global _MagicKeyEditorInputHook := ""
global _MagicKeyEditorStopDebt := false
; The window of the live capture, published with its hook.
global _MagicKeyEditorGui := ""

MagicKeyEditor(*) {
		global _MagicKeyEditorInputHook, _MagicKeyEditorStopDebt, _MagicKeyEditorGui, ScriptInformation
		; A pause stops typing, not configuration (EDD-1): the capture runs while
		; paused and saves the character at once, inert until the resume. The pause state the capture belongs to
		; is re-checked at publication: a pause or a resume ends it.
		StartedSuspended := A_IsSuspended
		if IsObject(_MagicKeyEditorInputHook) {
				; An active editor keeps its owner. Only a terminal Stop debt from an
				; earlier rollback may be retried before opening a successor.
				if !_MagicKeyEditorStopDebt {
						; Requested again: bring the live editor back in front. Its
						; hook swallows the next key typed anywhere, so a covered
						; editor would turn a keystroke in another app into the
						; new magic key.
						if IsObject(_MagicKeyEditorGui)
								WMPresentWindow(_MagicKeyEditorGui)
						return
				}
				if !_MagicKeyEditorStopOwned(_MagicKeyEditorInputHook)
						return
		}
		; Prepare the cached scalar membership before any dialog is visible.
		; I keeps its existing MinSendLevel=1 admission for non-AHK input.
		ScalarEndKeys := _SIHO_ScalarEndKeys() . "{Escape}"
		_InheritedCritical := A_IsCritical
		GuiToShow := 0, IH := 0
		try {
				GuiToShow := Gui_Create("", t("dialog.magic_key.title"))
				; The default is the layout's (feature_state.ahk), shown as « ★ (ù) ».
				GuiToShow.Add("Text", "w300", Format(t("dialog.magic_key.prompt"),
					MagicKeyShown(ScriptInformation["MagicKeyDefault"])))
				GuiToShow.Add("Text", "w300", t("button.cancel") . " → " . t("layer_editor.key.escape"))
				; Construct while hidden: native Close otherwise hides an unowned Gui
				; before the later factory returns and starts an invisible capture.
				IH := InputHook("L2 E C I", ScalarEndKeys)
				GuiToShow.OnEvent("Close", _MagicKeyEditorClose.Bind(IH))
				Critical("On")
				try {
						if A_IsSuspended != StartedSuspended or IsObject(_MagicKeyEditorInputHook)
								return
						_MagicKeyEditorInputHook := IH
						_MagicKeyEditorGui := GuiToShow
						_MagicKeyEditorStopDebt := false
						IH.Start()
						if A_IsSuspended != StartedSuspended || _MagicKeyEditorInputHook != IH || _MagicKeyEditorGui != GuiToShow
								return
						; Show pumps messages. Its Close handler must already own the
						; started hook, with no later Start able to revive that capture.
						GuiToShow.Show("Center")
						if A_IsSuspended != StartedSuspended || _MagicKeyEditorInputHook != IH || _MagicKeyEditorGui != GuiToShow
								return
				} finally {
						; Wait must never inherit a Critical menu caller.
						Critical("Off")
				}
				IH.Wait()
		} finally {
				CaptureSettled := false
				try {
						if IsObject(IH)
								CaptureSettled := _MagicKeyEditorStopOwned(IH, true)
				} finally {
						if IsObject(GuiToShow) {
								if (_MagicKeyEditorGui == GuiToShow)
										_MagicKeyEditorGui := ""
								; Close or a constructor failure may already retire this Gui.
								try GuiToShow.Destroy()
						}
						Critical(_InheritedCritical)
				}
		}

		; Close or a complete pause/resume may retire this exact owner while a
		; completed native hook still retains its reason and captured units. Only the
		; terminal path which actually retires that owner may persist its result.
		if !CaptureSettled || A_IsSuspended != StartedSuspended
				return
		Capture := _SIHO_ReadScalar(IH, "{Escape}")
		if Capture.Reason != ""
				LoggerWarn("Editors", "Discarded invalid Magic Key scalar capture ({1}).", Capture.Reason)
		if Capture.Kind == "text"
				ModifyMagicKey(0, Capture.Text)
}

_MagicKeyEditorClose(IH, GuiToClose, *) {
		; Closing the dialog is cancellation. Stop its suppressive InputHook now
		; so the next user key cannot be consumed by an orphaned capture. A true
		; return cancels the native Close while teardown debt remains.
		return !_MagicKeyEditorStopOwned(IH)
}

; Cleanup is idempotent for Close/lifecycle callers. Terminal capture delivery
; instead requires this call to retire the exact owner after native Stop.
_MagicKeyEditorStopOwned(IH, SettleCapture := false) {
		global _MagicKeyEditorInputHook, _MagicKeyEditorStopDebt
		PreviousCritical := Critical("On")
		try {
				if !IsObject(_MagicKeyEditorInputHook) {
						_MagicKeyEditorStopDebt := false
						return !SettleCapture
				}
				; A stale Close/finally must never stop or clear a successor editor.
				if _MagicKeyEditorInputHook != IH
						return !SettleCapture
		} finally Critical(PreviousCritical)

		try IH.Stop()
		catch as Err {
				OwnerRetained := false
				PreviousCritical := Critical("On")
				try {
						if IsObject(_MagicKeyEditorInputHook)
						and _MagicKeyEditorInputHook == IH {
								_MagicKeyEditorStopDebt := true
								OwnerRetained := true
						}
				} finally Critical(PreviousCritical)
				; Stop may have pumped an OnEnd/finally that settled this owner first.
				if !OwnerRetained
						return !SettleCapture
				LoggerError("Editors", "Could not stop the Magic Key capture; cleanup ownership was retained: {1}.", Err.Message)
				return false
		}

		PreviousCritical := Critical("On")
		try {
				if IsObject(_MagicKeyEditorInputHook)
				and _MagicKeyEditorInputHook == IH {
						_MagicKeyEditorInputHook := ""
						_MagicKeyEditorStopDebt := false
						return true
				}
		} finally Critical(PreviousCritical)
		; Cleanup remains idempotent for Close/lifecycle callers. A capture
		; receipt additionally proves that no reentrant Stop already revoked it.
		return !SettleCapture
}

_EditorWriteToml(Path, Context, BuildFn, WriterFn := 0, NotifyFn := 0) {
	if !HasMethod(NotifyFn, "Call") {
		NotifyFn := (Message, Options) => Ui_MsgBox(t("onboarding.error.write_failed"),
			t("editor.hotstrings.save_error"), "Icon!")
	}
	Committed := ConfigCommitBuilt(Path, Context, BuildFn, WriterFn, NotifyFn)
	return (Committed is Integer) && Committed == 1
}

; Configuration is already durable when these callbacks run. Never let a
; native/UI exception escape its menu or InputHook entry point, and never report
; a callback's false or string lookalike as success.
_EditorInvokePostCommitAction(ActionFn, Context) {
	try Result := ActionFn.Call()
	catch as Err {
		try LoggerError("Editors", "Post-commit {1} failed after config.toml was already persisted: {2}.", Context, Err.Message)
		return false
	}
	if !((Result is Integer) && Result == 1) {
		try LoggerError("Editors", "Post-commit {1} was refused or returned a malformed status after config.toml was already persisted.", Context)
		return false
	}
	return true
}

_EditorReloadAfterCommit(ReloadFn := 0) {
	if HasMethod(ReloadFn, "Call")
		return _EditorInvokePostCommitAction(ReloadFn, "reload")
	return _EditorInvokePostCommitAction(ReloadPreservingSuspend, "reload")
}

_EditorRebuildAfterCommit(RebuildFn := 0) {
	if HasMethod(RebuildFn, "Call")
		return _EditorInvokePostCommitAction(RebuildFn, "tray rebuild")
	return _EditorInvokePostCommitAction(RebuildTrayMenu, "tray rebuild")
}

_EditorDestroyAfterCommit(gui, Context) {
	if (gui is Integer) && gui == 0
		return true
	try gui.Destroy()
	catch as Err {
		try LoggerError("Editors", "Could not destroy the {1} after config.toml was already persisted: {2}.", Context, Err.Message)
		return false
	}
	return true
}

_EditorBuildMagicKeyPlan(NewValue) {
	global Features
	if _FeatureUsesDesiredState(Features) {
		Plan := _FeatureBuildSinglePlan(Features, ConfigKey.HOTSTRINGS_TRIGGER_CHAR, NewValue, "")
		Plan.publish := _EditorPublishDesiredMagicKey.Bind(Plan.publish, NewValue)
		return Plan
	}
	return {
		updates: [{ Section: "hotstrings", Key: ConfigLeaf.TRIGGER_CHAR, Value: NewValue }],
		publish: _EditorPublishMagicKey.Bind(NewValue),
	}
}

_EditorPublishDesiredMagicKey(PublishFn, NewValue) {
	global ScriptInformation
	PublishFn.Call()
	ScriptInformation["MagicKey"] := NewValue
}

_EditorPublishMagicKey(NewValue) {
	global ScriptInformation, Features
	ScriptInformation["MagicKey"] := NewValue
	if IsSet(Features) && Features.Has("hotstrings")
		Features["hotstrings"][ConfigLeaf.TRIGGER_CHAR] := NewValue
}

ModifyMagicKey(gui, NewValue, WriterFn := 0, NotifyFn := 0, ReloadFn := 0) {
	global ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ModifyMagicKey(gui, NewValue, WriterFn, NotifyFn, ReloadFn)
		finally Critical(InheritedCritical)
	}
	if !_EditorWriteToml(ConfigurationFile, "the magic key",
			_EditorBuildMagicKeyPlan.Bind(NewValue), WriterFn, NotifyFn)
		return false
	; A refused reload leaves the editor surface available for recovery. A real
	; successful Reload terminates this process and therefore never reaches destroy.
	if !_EditorReloadAfterCommit(ReloadFn)
		return false
	if !_EditorDestroyAfterCommit(gui, "magic-key editor")
		return false
	return true
}

_EditorBuildRepeatKeyPlan() {
	global HSE_RepeatEnabled, Features
	if _FeatureUsesDesiredState(Features) {
		Candidate := !ReadFeatureStateV2(ConfigKey.HOTSTRINGS_REPEAT_KEY_ENABLED)["enabled"]
		Plan := _FeatureBuildSinglePlan(Features, ConfigKey.HOTSTRINGS_REPEAT_KEY_ENABLED, Candidate, "")
		Plan.publish := _EditorPublishDesiredRepeatKey.Bind(Plan.publish)
		return Plan
	}
	Candidate := !HSE_RepeatEnabled
	return {
		updates: [{ Section: "hotstrings", Key: ConfigLeaf.REPEAT_KEY_ENABLED, Value: Candidate }],
		publish: _EditorPublishRepeatKey.Bind(Candidate),
	}
}

_EditorPublishDesiredRepeatKey(PublishFn) {
	global HSE_RepeatEnabled, Features
	PublishFn.Call()
	HSE_RepeatEnabled := Features["hotstrings"][ConfigLeaf.REPEAT_KEY_ENABLED]
	if IsSet(HSE_AdvanceRuntimeDecisionGeneration)
		HSE_AdvanceRuntimeDecisionGeneration()
}

_EditorPublishRepeatKey(Candidate) {
	global HSE_RepeatEnabled, Features
	HSE_RepeatEnabled := Candidate
	if IsSet(Features) && Features.Has("hotstrings")
		Features["hotstrings"][ConfigLeaf.REPEAT_KEY_ENABLED] := Candidate
	if IsSet(HSE_AdvanceRuntimeDecisionGeneration)
		HSE_AdvanceRuntimeDecisionGeneration()
	return true
}

ToggleRepeatKeyEnabled(WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	global ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ToggleRepeatKeyEnabled(WriterFn, NotifyFn, RebuildFn)
		finally Critical(InheritedCritical)
	}
	if !_EditorWriteToml(ConfigurationFile, "the repeat-key toggle",
			_EditorBuildRepeatKeyPlan, WriterFn, NotifyFn)
		return false
	; The live flag and its decision epoch were published together under the
	; config gateway's short Critical span. Hide/refresh the old projection only
	; after that span because tooltip teardown performs Win32 work.
	if IsSet(HSE_InvalidateRuntimeDecisionProjection)
		HSE_InvalidateRuntimeDecisionProjection()
	; No Reload: the repeat key is a pure runtime flag the engine reads live
	; (HSE_TryRepeatKey checks HSE_RepeatEnabled on every keystroke). Just
	; rebuild the tray so the checkmark reflects the new state.
	if !_EditorRebuildAfterCommit(RebuildFn)
		return false
	return true
}

; The engine global each word-reset setting publishes to.
_EditorWordResetGlobal(Key, Value) {
	global HSE_IdleResetSeconds, HSE_ClickResetsWord, HSE_CascadeMaxArrows
	global HSE_ArrowResetsWord, HSE_ShortcutResetsWord, HSE_TapHoldResetsWord
	global HSE_BackspaceRestoreEnabled, HSE_BackspaceRestoreWindowMs
	if (Key == ConfigLeaf.IDLE_RESET_SECONDS)
		HSE_IdleResetSeconds := Value
	else if (Key == ConfigLeaf.BACKSPACE_RESTORE_ENABLED)
		HSE_BackspaceRestoreEnabled := Value
	else if (Key == ConfigLeaf.BACKSPACE_RESTORE_WINDOW_MS)
		HSE_BackspaceRestoreWindowMs := Value
	else if (Key == ConfigLeaf.CASCADE_MAX_ARROWS)
		HSE_CascadeMaxArrows := Value
	else if (Key == ConfigLeaf.CLICK_RESETS_WORD)
		HSE_ClickResetsWord := Value
	else if (Key == ConfigLeaf.ARROW_RESETS_WORD)
		HSE_ArrowResetsWord := Value
	else if (Key == ConfigLeaf.SHORTCUT_RESETS_WORD)
		HSE_ShortcutResetsWord := Value
	else if (Key == ConfigLeaf.TAP_HOLD_RESETS_WORD)
		HSE_TapHoldResetsWord := Value
	else if HSE_PreviewSwitchIsKnown(Key)
		HSE_PreviewSwitchPublish(Key, Value)
	else
		throw ValueError("Unknown word-reset setting: " . Key)
}

; One plan for both word-reset settings (hotstrings.idle_reset_seconds and
; hotstrings.click_resets_word), through the same desired-state gateway as the
; repeat key. The engine reads both live: no reload.
_EditorBuildWordResetPlan(Key, Value) {
	global Features
	if _FeatureUsesDesiredState(Features) {
		Plan := _FeatureBuildSinglePlan(Features, "hotstrings." . Key, Value, "")
		Plan.publish := _EditorPublishDesiredWordReset.Bind(Plan.publish, Key, Value)
		return Plan
	}
	return {
		updates: [{ Section: "hotstrings", Key: Key, Value: Value }],
		publish: _EditorPublishWordReset.Bind(Key, Value),
	}
}

_EditorPublishDesiredWordReset(PublishFn, Key, Value) {
	PublishFn.Call()
	_EditorWordResetGlobal(Key, Value)
}

_EditorPublishWordReset(Key, Value) {
	global Features
	_EditorWordResetGlobal(Key, Value)
	if IsSet(Features) && (Features is Map) && Features.Has("hotstrings")
		Features["hotstrings"][Key] := Value
	return true
}

; Persists one word-reset setting, publishes it to the engine and redraws the
; tray so the tick and the caption follow.
_EditorCommitWordReset(Key, Value, Context, WriterFn, NotifyFn, RebuildFn) {
	global ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _EditorCommitWordReset(Key, Value, Context, WriterFn, NotifyFn, RebuildFn)
		finally Critical(InheritedCritical)
	}
	if !_EditorWriteToml(ConfigurationFile, Context,
			_EditorBuildWordResetPlan.Bind(Key, Value), WriterFn, NotifyFn)
		return false
	try LoggerInfo("Editors", "hotstrings.{1} set to {2}.", Key, String(Value))
	return _EditorRebuildAfterCommit(RebuildFn)
}

/**
 * Sets the pause after which the next key starts a new word.
 * @param {Number} Seconds Finite and non-negative; 0 disables the reset.
 * @returns {Integer|Boolean} 1 once persisted and redrawn, otherwise false.
 */
SetHotstringsIdleResetSeconds(Seconds, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	if !HSE_ValidIdleResetSeconds(Seconds)
			|| !ValueCheckValue(ValueCheckEntryFor(ConfigKey.HOTSTRINGS_IDLE_RESET_SECONDS), Seconds)["ok"] {
		try LoggerError("Editors", "Refused idle-reset delay: not a number of seconds within its declared range.")
		return false
	}
	return _EditorCommitWordReset(ConfigLeaf.IDLE_RESET_SECONDS, Seconds, "the idle-reset delay",
		WriterFn, NotifyFn, RebuildFn)
}

/**
 * Sets the longest chain of hotstrings: how many expansions (arrows) it may hold.
 * @param {Integer} Arrows A whole number from 1 (a single expansion) to 10.
 * @returns {Integer|Boolean} 1 once persisted and redrawn, otherwise false.
 */
SetHotstringsCascadeMaxArrows(Arrows, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	if !HSE_ValidCascadeMaxArrows(Arrows) {
		try LoggerError("Editors", "Refused cascade arrow count: not a whole number from 1 to 10.")
		return false
	}
	return _EditorCommitWordReset(ConfigLeaf.CASCADE_MAX_ARROWS, Arrows, "the cascade arrow count",
		WriterFn, NotifyFn, RebuildFn)
}

/**
 * Asks for a free idle delay, prefilled with the current one.
 * @param {Func} PromptFn Optional seam with Ui_InputBox's signature.
 * @param {Func} NotifyFn Optional seam called with the invalid-value message.
 * @returns {Integer|Boolean} 1 once persisted and redrawn, otherwise false.
 */
PromptHotstringsIdleResetSeconds(PromptFn := 0, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return PromptHotstringsIdleResetSeconds(PromptFn, WriterFn, NotifyFn, RebuildFn)
		finally Critical(InheritedCritical)
	}
	Current := HSE_IdleResetSecondsCurrent()
	Prefill := _MR_FormatFreeNumber(Current)
	Prompt := t("menu.hotstrings.idle_reset_prompt")
	Title := t("menu.hotstrings.idle_reset_title")
	Answer := HasMethod(PromptFn, "Call") ? PromptFn.Call(Prompt, Title, "w380 h150", Prefill)
		: Ui_InputBox(Prompt, Title, "w380 h150", Prefill)
	if !(Answer is Object) || Answer.Result != "OK"
		return false
	; The shared value schema owns the accepted range and its localized refusal.
	; A blank answer resets the setting to its default (PCK-13).
	Typed := ValueCheckParseEntry(ValueCheckEntryFor(ConfigKey.HOTSTRINGS_IDLE_RESET_SECONDS), Answer.Value,
		ManifestDefaultFor(ConfigKey.HOTSTRINGS_IDLE_RESET_SECONDS))
	if !Typed["ok"] {
		if HasMethod(NotifyFn, "Call") {
			try LoggerWarn("Editors", "Invalid idle-reset delay typed — ignored.")
			NotifyFn.Call(ValueCheckRenderMessage(ValueCheckMessageParts(
				ValueCheckEntryFor(ConfigKey.HOTSTRINGS_IDLE_RESET_SECONDS), Typed), (K) => t(K)), "Icon!")
		} else
			ValueCheckShowRefusal(ConfigKey.HOTSTRINGS_IDLE_RESET_SECONDS, Typed, Answer.Value)
		return false
	}
	Seconds := Typed["value"]
	return SetHotstringsIdleResetSeconds(Seconds, WriterFn, NotifyFn, RebuildFn)
}

/**
 * Flips whether a Backspace right after an expansion undoes it.
 * @returns {Integer|Boolean} 1 once persisted and redrawn, otherwise false.
 */
ToggleHotstringsBackspaceRestore(WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	return _EditorCommitWordReset(ConfigLeaf.BACKSPACE_RESTORE_ENABLED, !HSE_BackspaceRestoreEnabledCurrent(),
		"the Backspace undo toggle", WriterFn, NotifyFn, RebuildFn)
}

/**
 * Sets how long after an expansion a Backspace still undoes it.
 * @param {Integer} Milliseconds A whole number within the value schema's range.
 * @returns {Integer|Boolean} 1 once persisted and redrawn, otherwise false.
 */
SetHotstringsBackspaceRestoreWindowMs(Milliseconds, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	if !HSE_ValidBackspaceRestoreWindowMs(Milliseconds)
			|| !ValueCheckValue(ValueCheckEntryFor(ConfigKey.HOTSTRINGS_BACKSPACE_RESTORE_WINDOW_MS), Milliseconds)["ok"] {
		try LoggerError("Editors", "Refused Backspace undo window: not a whole number of milliseconds within its declared range.")
		return false
	}
	return _EditorCommitWordReset(ConfigLeaf.BACKSPACE_RESTORE_WINDOW_MS, Milliseconds,
		"the Backspace undo window", WriterFn, NotifyFn, RebuildFn)
}

/**
 * Asks for a free Backspace undo window, prefilled with the current one.
 * @param {Func} PromptFn Optional seam with Ui_InputBox's signature.
 * @param {Func} NotifyFn Optional seam called with the invalid-value message.
 * @returns {Integer|Boolean} 1 once persisted and redrawn, otherwise false.
 */
PromptHotstringsBackspaceRestoreWindowMs(PromptFn := 0, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return PromptHotstringsBackspaceRestoreWindowMs(PromptFn, WriterFn, NotifyFn, RebuildFn)
		finally Critical(InheritedCritical)
	}
	Entry := ValueCheckEntryFor(ConfigKey.HOTSTRINGS_BACKSPACE_RESTORE_WINDOW_MS)
	Prefill := _MR_FormatFreeNumber(HSE_BackspaceRestoreWindowMsCurrent())
	Prompt := t("menu.hotstrings.backspace_restore_window_prompt")
	Title := t("menu.hotstrings.backspace_restore_window_title")
	Answer := HasMethod(PromptFn, "Call") ? PromptFn.Call(Prompt, Title, "w380 h170", Prefill)
		: Ui_InputBox(Prompt, Title, "w380 h170", Prefill)
	if !(Answer is Object) || Answer.Result != "OK"
		return false
	; The shared value schema owns the accepted range and its localized refusal.
	; A blank answer resets the setting to its default (PCK-13).
	Typed := ValueCheckParseEntry(Entry, Answer.Value, ManifestDefaultFor(ConfigKey.HOTSTRINGS_BACKSPACE_RESTORE_WINDOW_MS))
	if !Typed["ok"] {
		if HasMethod(NotifyFn, "Call") {
			try LoggerWarn("Editors", "Invalid Backspace undo window typed — ignored.")
			NotifyFn.Call(ValueCheckRenderMessage(ValueCheckMessageParts(Entry, Typed), (K) => t(K)), "Icon!")
		} else
			ValueCheckShowRefusal(ConfigKey.HOTSTRINGS_BACKSPACE_RESTORE_WINDOW_MS, Typed, Answer.Value)
		return false
	}
	return SetHotstringsBackspaceRestoreWindowMs(Typed["value"], WriterFn, NotifyFn, RebuildFn)
}

/**
 * Flips whether a mouse click starts a new word.
 * @returns {Integer|Boolean} 1 once persisted and redrawn, otherwise false.
 */
ToggleHotstringsClickResetsWord(WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	return _EditorCommitWordReset(ConfigLeaf.CLICK_RESETS_WORD, !HSE_ClickResetsWordCurrent(),
		"the click word-reset toggle", WriterFn, NotifyFn, RebuildFn)
}

/**
 * Flips one event word-reset setting: whether an arrow key, a shortcut, or a
 * tap-hold key's own output starts a new word.
 * @param {String} Key "arrow_resets_word", "shortcut_resets_word" or
 *        "tap_hold_resets_word".
 * @returns {Integer|Boolean} 1 once persisted and redrawn, otherwise false.
 */
ToggleHotstringsWordResetFlag(Key, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	return _EditorCommitWordReset(Key, !HSE_WordResetFlagCurrent(Key),
		"the " . Key . " toggle", WriterFn, NotifyFn, RebuildFn)
}

/**
 * Flips one preview-bubble switch (hotstrings.preview_star_enabled,
 * preview_autocorrect_enabled, preview_ai_enabled, preview_colored_tooltips,
 * preview_category_glyphs, preview_announcements).
 * The engine and the prediction path read the switches live, so there is no
 * reload; the bubble on screen is retired because it was promised under the old
 * value (macOS and Linux revoke it the same way).
 * @param {String} Key One of HSE_PreviewSwitchKeys().
 * @returns {Integer|Boolean} 1 once persisted and redrawn, otherwise false.
 */
ToggleHotstringsPreviewSwitch(Key, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	if !HSE_PreviewSwitchIsKnown(Key) {
		try LoggerError("Editors", "Refused unknown preview switch.")
		return false
	}
	Candidate := !HSE_PreviewSwitchCurrent(Key)
	if !_EditorCommitWordReset(Key, Candidate, "the " . Key . " toggle",
			WriterFn, NotifyFn, RebuildFn)
		return false
	; Retire what the old value promised: a bubble on screen, a prediction timer.
	TooltipHide("PreviewSwitch", true)
	if (Key == ConfigLeaf.PREVIEW_AI_ENABLED && !Candidate && IsSet(LLM_Engine_CancelTimer))
		LLM_Engine_CancelTimer()
	static NoticeKeys := Map(ConfigLeaf.PREVIEW_STAR_ENABLED, "menu.hotstrings.notify_bubble_star",
		ConfigLeaf.PREVIEW_AUTOCORRECT_ENABLED, "menu.hotstrings.notify_bubble_autocorrect",
		ConfigLeaf.PREVIEW_AI_ENABLED, "menu.hotstrings.notify_bubble_ai",
		ConfigLeaf.PREVIEW_COLORED_TOOLTIPS, "menu.hotstrings.notify_bubble_colored",
		ConfigLeaf.PREVIEW_CATEGORY_GLYPHS, "menu.hotstrings.notify_bubble_glyphs",
		ConfigLeaf.PREVIEW_ANNOUNCEMENTS, "menu.hotstrings.notify_bubble_announcements")
	if NoticeKeys.Has(Key)
		NotifyFeature(t(NoticeKeys[Key]), Candidate)
	return true
}

_PersonalInfoReportSaveFailure(NotifyFn := 0) {
	try {
		if HasMethod(NotifyFn, "Call")
			NotifyFn.Call(t("dialog.personal_info.save_failed"), "Iconx")
		else
			Ui_MsgBox(t("dialog.personal_info.save_failed"),
				t("dialog.personal_info.save_failed_title"), "Iconx")
	} catch as Err {
		try LoggerError("PersonalInfo",
			"Could not display the personal-information save failure: {1}.",
			Err.Message)
	}
	return false
}

; Opens the personal-information editor. WebView only (maintainer decision
; 2026-11-11): when WebView2 cannot open the shared page, the user is told
; WebView2 is required and the reason is logged; no native form is built.
; @returns {Boolean} False when WebView2 refused the opening.
PersonalInformationEditor(*) {
	if _PiEdWeb_TryOpen(&FailureReason)
		return true
	return WebView_RefuseUnavailable("personal information editor", FailureReason)
}

; Every opening creates a fresh native dialog. Default Close only hides it,
; retaining its edit control and the button callback that captures this Gui.
_GPTLinkEditorClose(Window, *) {
	Window.Destroy()
	return true
}

GPTLinkEditor(*) {
		global Features
		CurrentLink := ""
		if IsSet(Features) and Features.Has("shortcuts") and Features["shortcuts"].Has(ConfigLeaf.CHATGPT_URL)
				CurrentLink := Features["shortcuts"][ConfigLeaf.CHATGPT_URL]
		GuiToShow := Gui_Create(, t("dialog.gpt_link.title"))
		GuiToShow.OnEvent("Close", _GPTLinkEditorClose)
		GuiToShow.OnEvent("Escape", _GPTLinkEditorClose)
		; A screen reader names an Edit by the text just before it.
		GuiToShow.Add("Text", "w300", t("dialog.gpt_link.label"))
		NewValue := GuiToShow.Add("Edit", "w300", CurrentLink)
		GuiToShow.Add("Button", "w100 Center", t("button.ok")).OnEvent("Click", (*) => ModifyLink(GuiToShow, NewValue.Text))
		GuiToShow.Show("Center")
}

_EditorBuildLinkPlan(NewValue) {
	global Features
	if _FeatureUsesDesiredState(Features)
		return _FeatureBuildSinglePlan(Features, ConfigKey.SHORTCUTS_CHATGPT_URL, NewValue, "")
	return {
		updates: [{ Section: "shortcuts", Key: ConfigLeaf.CHATGPT_URL, Value: NewValue }],
		publish: _EditorPublishLink.Bind(NewValue),
	}
}

_EditorPublishLink(NewValue) {
	global Features
	if IsSet(Features) && Features.Has("shortcuts")
		Features["shortcuts"][ConfigLeaf.CHATGPT_URL] := NewValue
}

ModifyLink(gui, NewValue, WriterFn := 0, NotifyFn := 0, ReloadFn := 0) {
	global ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ModifyLink(gui, NewValue, WriterFn, NotifyFn, ReloadFn)
		finally Critical(InheritedCritical)
	}
	; The shared value check names what a web address needs; nothing is written.
	Typed := ValueCheckParseEntry(ValueCheckEntryFor(ConfigKey.SHORTCUTS_CHATGPT_URL), NewValue)
	if !Typed["ok"] {
		ValueCheckShowRefusal(ConfigKey.SHORTCUTS_CHATGPT_URL, Typed, NewValue)
		return false
	}
	NewValue := Typed["value"]
	if !_EditorWriteToml(ConfigurationFile, "the ChatGPT link",
			_EditorBuildLinkPlan.Bind(NewValue), WriterFn, NotifyFn)
		return false
	if !_EditorReloadAfterCommit(ReloadFn)
		return false
	if !_EditorDestroyAfterCommit(gui, "ChatGPT-link editor")
		return false
	return true
}
