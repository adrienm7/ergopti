; ui/editors.ahk

; ==============================================================================
; MODULE: Config Editors (GUI dialogs)
; DESCRIPTION:
; Small modal GUI editors for user-configurable values: the magic key, the
; repeat-key toggle, personal information, and the ChatGPT link. Extracted
; verbatim from ErgoptiPlus.ahk (the entry-point decomposition) and #Include'd at
; the original position so boot order is unchanged. Functions are hoisted, so
; their menu/hotkey call sites elsewhere are unaffected.
; ==============================================================================

global _MagicKeyEditorInputHook := ""

MagicKeyEditor(*) {
		global _MagicKeyEditorInputHook
		; Tray callbacks remain reachable while native Suspend is active. Refuse a
		; fresh capture before creating UI, then re-check atomically at publication
		; because a suspend callback can still interrupt between ordinary lines.
		if A_IsSuspended or IsObject(_MagicKeyEditorInputHook)
				return
		GuiToShow := Gui_Create("+AlwaysOnTop", t("dialog.magic_key.title"))
		GuiToShow.Add("Text", "w300", t("dialog.magic_key.prompt"))
		GuiToShow.Add("Text", "w300", t("button.cancel") . " → Echap")
		GuiToShow.Show("Center")
		IH := InputHook("L1 I", "{Escape}")
		GuiToShow.OnEvent("Close", _MagicKeyEditorClose.Bind(IH))
		_InheritedCritical := A_IsCritical
		try {
				; Publish + Start is one lifecycle transaction. If suspend lands before
				; publication this gate refuses Start; if it lands afterwards, suspend
				; owns this exact live hook and stops it synchronously.
				Critical("On")
				try {
						if A_IsSuspended or IsObject(_MagicKeyEditorInputHook)
								return
						_MagicKeyEditorInputHook := IH
						IH.Start()
				} finally {
						; Wait() pumps messages and may block indefinitely. It must never
						; inherit a Critical menu caller after publication is complete.
						Critical("Off")
				}
				IH.Wait()
		} finally {
				try IH.Stop()
				; A future owner must never be cleared by an older callback unwinding.
				if (IsObject(_MagicKeyEditorInputHook)
				and _MagicKeyEditorInputHook == IH)
						_MagicKeyEditorInputHook := ""
				; The Close event may already have destroyed the native window.
				try GuiToShow.Destroy()
				Critical(_InheritedCritical)
		}
		; InputHook.Wait pumps messages and native Suspend does not stop hooks by
		; itself. Discard a capture whose wait crossed the pause boundary.
		if A_IsSuspended
				return
		if (IH.EndReason = "Max" && IH.Input != "")
				ModifyMagicKey(0, IH.Input)
}

_MagicKeyEditorClose(IH, GuiToClose, *) {
		; Closing the dialog is cancellation. Stop its suppressive InputHook now
		; so the next user key cannot be consumed by an orphaned capture.
		try IH.Stop()
}

_EditorWriteToml(Path, Context, BuildFn, WriterFn := 0, NotifyFn := 0) {
	if !HasMethod(NotifyFn, "Call") {
		NotifyFn := (Message, Options) => MsgBox(t("onboarding.error.write_failed"),
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
	return {
		updates: [{ Section: "hotstrings", Key: "trigger_char", Value: NewValue }],
		publish: _EditorPublishMagicKey.Bind(NewValue),
	}
}

_EditorPublishMagicKey(NewValue) {
	global ScriptInformation, Features
	ScriptInformation["MagicKey"] := NewValue
	if IsSet(Features) && Features.Has("hotstrings")
		Features["hotstrings"]["trigger_char"] := NewValue
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
	global HSE_RepeatEnabled
	Candidate := !HSE_RepeatEnabled
	return {
		updates: [{ Section: "hotstrings", Key: "repeat_key_enabled", Value: Candidate }],
		publish: _EditorPublishRepeatKey.Bind(Candidate),
	}
}

_EditorPublishRepeatKey(Candidate) {
	global HSE_RepeatEnabled, Features
	HSE_RepeatEnabled := Candidate
	if IsSet(Features) && Features.Has("hotstrings")
		Features["hotstrings"]["repeat_key_enabled"] := Candidate
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

_PersonalInfoReportSaveFailure(NotifyFn := 0) {
	try {
		if HasMethod(NotifyFn, "Call")
			NotifyFn.Call(t("dialog.personal_info.save_failed"), "Iconx")
		else
			MsgBox(t("dialog.personal_info.save_failed"),
				t("dialog.personal_info.save_failed_title"), "Iconx")
	} catch as Err {
		try LoggerError("PersonalInfo",
			"Could not display the personal-information save failure: {1}.",
			Err.Message)
	}
	return false
}

PersonalInformationEditor(*) {
		; Prefer the shared WebView2 editor (identical UI to macOS); the native
		; multi-field dialog below remains as an automatic fallback.
		if _PiEdWeb_TryOpen()
				return
		GuiToShow := Gui(, t("dialog.personal_info.title"))
		UpdatedPersonalInformation := Map()
		ReverseLetters := Map()
		for k, v in PersonalInformationLetters
				ReverseLetters[v] := k
		for PersonalInformationKey, OldValue in PersonalInformation {
				TextToAdd := ""
				if ReverseLetters.Has(PersonalInformationKey)
						TextToAdd := " (@" . ReverseLetters[PersonalInformationKey] . ScriptInformation["MagicKey"] . ")"
				GuiToShow.SetFont("bold")
				GuiToShow.Add("Text", , PersonalInformationKey . TextToAdd)
				GuiToShow.SetFont("norm")
				NewValue := GuiToShow.Add("Edit", "w300", OldValue)
				UpdatedPersonalInformation[PersonalInformationKey] := NewValue
		}
		GuiToShow.Add("Button", "w100 Center", t("button.ok")).OnEvent("Click", (*) => ProcessUserInput(GuiToShow, UpdatedPersonalInformation))
		GuiToShow.Show("Center")
}

ProcessUserInput(gui, edits, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0,
		AuthorizeFn := 0, NotifyFn := 0, ReloadFn := 0, ConfirmFn := 0) {
	global PersonalInformation, ScriptInformation
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		; GUI confirmation, durable persistence and reload can all block. A caller
		; may be Critical, but this complete user action must remain interruptible.
		Critical("Off")
		try return ProcessUserInput(gui, edits, WriterFn, ReplaceFn, DeleteFn,
			AuthorizeFn, NotifyFn, ReloadFn, ConfirmFn)
		finally Critical(InheritedCritical)
	}
	if !(edits is Map) {
		try LoggerError("PersonalInfo", "The native personal-information editor returned a malformed control map.")
		return _PersonalInfoReportSaveFailure(NotifyFn)
	}
	Values := Map()
	Changed := Map()
	for Key, EditControl in edits {
		try NewValue := EditControl.Text
		catch as Err {
			try LoggerError("PersonalInfo",
				"Could not read field '{1}' from the native personal-information editor: {2}.",
				Key, Err.Message)
			return _PersonalInfoReportSaveFailure(NotifyFn)
		}
		if !(NewValue is String) {
			try LoggerError("PersonalInfo",
				"The native personal-information editor returned a non-string value for '{1}'.", Key)
			return _PersonalInfoReportSaveFailure(NotifyFn)
		}
		Values[Key] := NewValue
		OldValue := PersonalInformation.Has(Key) ? PersonalInformation[Key] : ""
		if (NewValue != OldValue)
			Changed[Key] := true
	}

	if !PersonalInfoCommitValues(ScriptInformation["PersonalInfoTomlPath"],
			Values, WriterFn, ReplaceFn, DeleteFn, AuthorizeFn) {
		try LoggerError("PersonalInfo",
			"Personal information NOT saved — keeping the native editor open so the values are not lost.")
		return _PersonalInfoReportSaveFailure(NotifyFn)
	}

	PersonalInformationSummary := ""
	for Key, _ in Changed
		PersonalInformationSummary .= Key . ": " . PersonalInformation[Key] . "`n"
	try {
		if HasMethod(ConfirmFn, "Call")
			ConfirmFn.Call(t("dialog.personal_info.saved") "`n`n" PersonalInformationSummary)
		else
			MsgBox(t("dialog.personal_info.saved") "`n`n" PersonalInformationSummary)
	}
	catch as Err
		try LoggerError("PersonalInfo", "Could not display the personal-information save confirmation: {1}.", Err.Message)
	if !_EditorReloadAfterCommit(ReloadFn)
		return false
	if !_EditorDestroyAfterCommit(gui, "personal-information editor")
		return false
	return true
}

GPTLinkEditor(*) {
		global Features
		CurrentLink := ""
		if IsSet(Features) and Features.Has("shortcuts") and Features["shortcuts"].Has("gpt") and Features["shortcuts"]["gpt"].Has("link")
				CurrentLink := Features["shortcuts"]["gpt"]["link"]
		GuiToShow := Gui(, t("dialog.gpt_link.title"))
		NewValue := GuiToShow.Add("Edit", "w300", CurrentLink)
		GuiToShow.Add("Button", "w100 Center", t("button.ok")).OnEvent("Click", (*) => ModifyLink(GuiToShow, NewValue.Text))
		GuiToShow.Show("Center")
}

_EditorBuildLinkPlan(NewValue) {
	return {
		updates: [{ Section: "shortcuts.gpt", Key: "link", Value: NewValue }],
		publish: _EditorPublishLink.Bind(NewValue),
	}
}

_EditorPublishLink(NewValue) {
	global Features
	if IsSet(Features) && Features.Has("shortcuts") && Features["shortcuts"].Has("gpt")
		Features["shortcuts"]["gpt"]["link"] := NewValue
}

ModifyLink(gui, NewValue, WriterFn := 0, NotifyFn := 0, ReloadFn := 0) {
	global ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ModifyLink(gui, NewValue, WriterFn, NotifyFn, ReloadFn)
		finally Critical(InheritedCritical)
	}
	if !_EditorWriteToml(ConfigurationFile, "the ChatGPT link",
			_EditorBuildLinkPlan.Bind(NewValue), WriterFn, NotifyFn)
		return false
	if !_EditorReloadAfterCommit(ReloadFn)
		return false
	if !_EditorDestroyAfterCommit(gui, "ChatGPT-link editor")
		return false
	return true
}
