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
global _MagicKeyEditorStopDebt := false
; The window of the live capture, published with its hook.
global _MagicKeyEditorGui := ""

MagicKeyEditor(*) {
		global _MagicKeyEditorInputHook, _MagicKeyEditorStopDebt, _MagicKeyEditorGui
		; Tray callbacks remain reachable while native Suspend is active. Refuse a
		; fresh capture before creating UI, then re-check atomically at publication
		; because a suspend callback can still interrupt between ordinary lines.
		if A_IsSuspended
				return
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
		GuiToShow := Gui_Create("", t("dialog.magic_key.title"))
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
						_MagicKeyEditorGui := GuiToShow
						_MagicKeyEditorStopDebt := false
						IH.Start()
				} finally {
						; Wait() pumps messages and may block indefinitely. It must never
						; inherit a Critical menu caller after publication is complete.
						Critical("Off")
				}
				IH.Wait()
		} finally {
				_MagicKeyEditorStopOwned(IH)
				if (_MagicKeyEditorGui == GuiToShow)
						_MagicKeyEditorGui := ""
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
		; so the next user key cannot be consumed by an orphaned capture. A true
		; return cancels the native Close while teardown debt remains.
		return !_MagicKeyEditorStopOwned(IH)
}

_MagicKeyEditorStopOwned(IH) {
		global _MagicKeyEditorInputHook, _MagicKeyEditorStopDebt
		PreviousCritical := Critical("On")
		try {
				if !IsObject(_MagicKeyEditorInputHook) {
						_MagicKeyEditorStopDebt := false
						return true
				}
				; A stale Close/finally must never stop or clear a successor editor.
				if _MagicKeyEditorInputHook != IH
						return true
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
						return true
				LoggerError("Editors", "Could not stop the Magic Key capture; cleanup ownership was retained: {1}.", Err.Message)
				return false
		}

		PreviousCritical := Critical("On")
		try {
				if IsObject(_MagicKeyEditorInputHook)
				and _MagicKeyEditorInputHook == IH {
						_MagicKeyEditorInputHook := ""
						_MagicKeyEditorStopDebt := false
				}
		} finally Critical(PreviousCritical)
		return true
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
		Plan := _FeatureBuildSinglePlan(Features, "hotstrings.trigger_char", NewValue, "")
		Plan.publish := _EditorPublishDesiredMagicKey.Bind(Plan.publish, NewValue)
		return Plan
	}
	return {
		updates: [{ Section: "hotstrings", Key: "trigger_char", Value: NewValue }],
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

; The physical magic key captured by pressing it: the next key pressed while this
; dialog shows becomes [hotstrings] magic_key_source. Escape, closing the dialog
; or the shared capture timeout changes nothing. It shares the magic-key editor's
; owner (one suppressive capture at a time, stopped by Suspend and by Close).
;
; The key is read from the keyboard hook's PHYSICAL key state, never from the
; scan code the InputHook reports: a remap hotkey suppresses the key it fires on,
; and the hook only sees what that hotkey sends (HookDispatcherConst), at level 2
; — with the Ergopti emulation on, the key typing "j" reported the scan code of
; "j" on the OS layout, and the magic key its own {Text}★, scan code 0. A key
; press, whatever reaches the hook, and a short poll, for a hotkey that sends
; nothing the hook sees (a dead key, a tap-hold), both ask which candidate key is
; physically down. GetKeyState "P" is exact only while the keyboard hook is
; installed, which it always is in this driver.
MagicKeySourceCapture(*) {
		global _MagicKeyEditorInputHook, _MagicKeyEditorStopDebt, _MagicKeyEditorGui
		if A_IsSuspended
				return
		if IsObject(_MagicKeyEditorInputHook) {
				; A live capture keeps its owner and comes back to the front: its
				; hook swallows the next key typed anywhere.
				if !_MagicKeyEditorStopDebt {
						if IsObject(_MagicKeyEditorGui)
								WMPresentWindow(_MagicKeyEditorGui)
						return
				}
				if !_MagicKeyEditorStopOwned(_MagicKeyEditorInputHook)
						return
		}
		GuiToShow := Gui_Create("", t("dialog.magic_key_source.title"))
		GuiToShow.Add("Text", "w300", t("dialog.magic_key_source.prompt"))
		GuiToShow.Show("Center")
		State := _MagicKeySourceCaptureState()
		; L0: no text is collected, every key is reported to OnKeyDown (N) and
		; kept from the application (S); T ends the wait on the shared timeout.
		IH := InputHook("L0 I T" . TimingsGetSec("ui", "magic_key_capture_timeout_ms"))
		IH.KeyOpt("{All}", "NS")
		IH.OnKeyDown := _MagicKeySourceCaptureKeyDown.Bind(State)
		MagicKeyCapturePoll := _MagicKeySourceCapturePoll.Bind(State, IH)
		GuiToShow.OnEvent("Close", _MagicKeyEditorClose.Bind(IH))
		_InheritedCritical := A_IsCritical
		try {
				; Publish + Start is one lifecycle transaction, as in MagicKeyEditor.
				Critical("On")
				try {
						if A_IsSuspended or IsObject(_MagicKeyEditorInputHook)
								return
						_MagicKeyEditorInputHook := IH
						_MagicKeyEditorGui := GuiToShow
						_MagicKeyEditorStopDebt := false
						IH.Start()
				} finally {
						Critical("Off")
				}
				SetTimer(MagicKeyCapturePoll, TimingsGet("ui", "magic_key_capture_poll_ms"))
				IH.Wait()
		} finally {
				SetTimer(MagicKeyCapturePoll, 0)
				_MagicKeyEditorStopOwned(IH)
				if (_MagicKeyEditorGui == GuiToShow)
						_MagicKeyEditorGui := ""
				try GuiToShow.Destroy()
				Critical(_InheritedCritical)
		}
		; A capture whose wait crossed the pause boundary is discarded.
		if A_IsSuspended
				return
		; Escape, Close and the timeout all end without an answer.
		if (IH.EndReason != "Stopped")
				return
		if State.Refused {
				Ui_MsgBox(t("dialog.magic_key_source.not_a_candidate"), t("dialog.magic_key_source.title"), "Icon!")
				return
		}
		if (State.Scan == "")
				return
		ModifyMagicKeySource(LayoutRegistry_KeyCode(State.Scan, LayoutRegistry_Keycodes()))
}

; The state of one capture: the scan codes of the candidate keys, how a key's
; physical state is read, the candidates already down when it opened (an answer
; only once released), and the answer: a scan code, or Refused for a key that is
; no candidate.
; @param IsDown {Func} (KeyName) → whether the key is physically down.
; @returns {Object} Scans, IsDown, Held, Scan and Refused.
_MagicKeySourceCaptureState(IsDown := _MagicKeySourceIsDown) {
		Scans := []
		Keycodes := LayoutRegistry_Keycodes()
		for Code in ManifestFindEntryByPath("hotstrings.magic_key_source")["enum_values"] {
				if MagicKeySourceIsCandidate(Code)
						Scans.Push(LayoutRegistry_KeyScan(Code, Keycodes))
		}
		Held := Map()
		for Scan in Scans {
				if IsDown.Call(Scan)
						Held[Scan] := true
		}
		return { Scans: Scans, IsDown: IsDown, Held: Held, Scan: "", Refused: false }
}

_MagicKeySourceIsDown(KeyName) {
		return GetKeyState(KeyName, "P")
}

; The candidate key physically down, "" when none. A key held since the capture
; opened stops being ignored once it was released.
_MagicKeySourcePressedScan(State) {
		; Collected first: a Map must not lose keys while it is enumerated.
		Released := []
		for Scan in State.Held {
				if !State.IsDown.Call(Scan)
						Released.Push(Scan)
		}
		for Scan in Released
				State.Held.Delete(Scan)
		for Scan in State.Scans {
				if !State.Held.Has(Scan) && State.IsDown.Call(Scan)
						return Scan
		}
		return ""
}

; Poll of the capture, for a key whose hotkey sends nothing the InputHook sees.
_MagicKeySourceCapturePoll(State, IH) {
		if !IH.InProgress
				return
		if State.IsDown.Call("Escape") {
				IH.Stop()
				return
		}
		Scan := _MagicKeySourcePressedScan(State)
		if (Scan == "")
				return
		State.Scan := Scan
		IH.Stop()
}

; List provider of the Layout menu's `magic_key_source` row (ui/menu/menu_init.ahk).
; One row naming the key in effect; its submenu captures the next key pressed,
; restores the automatic key or lists every candidate with the key in effect
; ticked — the rows the Lua drivers build (_shared/lua/keymap/magic_key_source.lua).
MagicKeySourceMenuRows() {
	global ScriptInformation
	Current := ScriptInformation["MagicKeySource"]
	Automatic := ManifestDefaultFor("hotstrings.magic_key_source")
	Keycodes := LayoutRegistry_Keycodes()
	Hkl := KS_ResolveKeyboardLayout()
	Items := [
		Map("label", t("menu.layout.magic_key_source.capture"), "action", MagicKeySourceCapture),
		Map("separator", true),
		Map("label", t("menu.layout.magic_key_source.auto"), "checked", Current == Automatic,
			"action", (*) => ModifyMagicKeySource(Automatic)),
		Map("separator", true)]
	for Code in ManifestFindEntryByPath("hotstrings.magic_key_source")["enum_values"] {
		if (Code == Automatic)
			continue
		Reason := MagicKeySourceChoiceReason(Code)
		Label := _MagicKeySourceLabel(Code, Keycodes, Hkl)
		if Reason != ""
			Label .= " — " . t(Reason)
		Items.Push(Map("label", Label, "checked", Current == Code, "disabled", Reason != "",
			"action", ((Chosen) => (*) => ModifyMagicKeySource(Chosen))(Code)))
	}
	Shown := (Current == Automatic) ? t("menu.layout.magic_key_source.auto")
		: _MagicKeySourceLabel(Current, Keycodes, Hkl)
	return [Map("label", t("menu.layout.magic_key_source") . " : " . Shown, "items", Items)]
}

; The refusal reason of a candidate already owned by a configured tap action.
; @param {String} Value Candidate or automatic source.
; @returns {String} Locale reason key, or empty when there is no conflict.
MagicKeySourceChoiceReason(Value) {
	if Value == ManifestDefaultFor("hotstrings.magic_key_source")
		return ""
	Scan := LayoutRegistry_KeyScan(Value, LayoutRegistry_Keycodes())
	if TapKeyAssignedToScan(Integer("0x" . SubStr(Scan, 3))) != ""
		return "menu.shortcuts.keyboard.magic_editor_reason.explicit_assignment"
	return ""
}

; What the OS layout types on a candidate key, then its KeyboardEvent.code, which
; names the same key on every keyboard; the code alone when the layout cannot say.
_MagicKeySourceLabel(Code, Keycodes, Hkl) {
	Scan := Integer("0x" . SubStr(LayoutRegistry_KeyScan(Code, Keycodes), 3))
	Text := (Hkl == 0) ? "" : KS_KeyTextNoStateChange(KS_ScancodeToVk(Scan, Hkl), Scan, Hkl).Text
	return (Trim(Text) == "") ? Code : Text . "   (" . Code . ")"
}

; OnKeyDown of the capture: a modifier alone chooses nothing, Escape cancels, and
; any other key answers with the candidate physically down — VK and SC describe
; what reached the hook, a remap's output rather than the key pressed. With no
; candidate down, the key pressed is none (Space, Enter, F5…) and is refused; a
; candidate held since the capture opened only repeats and is no answer yet.
_MagicKeySourceCaptureKeyDown(State, IH, VK, SC) {
		global HOTKEY_MODIFIER_VKS
		if HOTKEY_MODIFIER_VKS.Has(VK)
				return
		if (VK == GetKeyVK("Escape")) {
				IH.Stop()
				return
		}
		Scan := _MagicKeySourcePressedScan(State)
		if (Scan == "") {
				if (State.Held.Count > 0)
						return
				State.Refused := true
		}
		State.Scan := Scan
		IH.Stop()
}

; Whether a value names a candidate key of [hotstrings] magic_key_source: one of
; the manifest's enum values, spelled as it spells them, other than the
; automatic default.
MagicKeySourceIsCandidate(Code) {
		if !(Code is String) || Code == ""
				return false
		if (Code == ManifestDefaultFor("hotstrings.magic_key_source"))
				return false
		for Allowed in ManifestFindEntryByPath("hotstrings.magic_key_source")["enum_values"] {
				if (Allowed == Code)
						return true
		}
		return false
}

_EditorBuildMagicKeySourcePlan(Value) {
	global Features
	if _FeatureUsesDesiredState(Features) {
		Plan := _FeatureBuildSinglePlan(Features, "hotstrings.magic_key_source", Value, "")
		Plan.publish := _EditorPublishDesiredMagicKeySource.Bind(Plan.publish, Value)
		return Plan
	}
	return {
		updates: [{ Section: "hotstrings", Key: "magic_key_source", Value: Value }],
		publish: _EditorPublishMagicKeySource.Bind(Value),
	}
}

_EditorPublishDesiredMagicKeySource(PublishFn, Value) {
	PublishFn.Call()
	_EditorPublishMagicKeySource(Value)
}

_EditorPublishMagicKeySource(Value) {
	global ScriptInformation, Features
	ScriptInformation["MagicKeySource"] := Value
	ScriptInformation["MagicKeySourceChosen"] := Value !== ManifestDefaultFor("hotstrings.magic_key_source")
	if IsSet(Features) && Features.Has("hotstrings")
		Features["hotstrings"]["magic_key_source"] := Value
}

; Persists the physical magic key ([hotstrings] magic_key_source) and reloads:
; the remap hotkeys register on its scan code at load.
; @param Value {String} A candidate code or the automatic value.
; @returns {Boolean} Whether the choice was written and the reload accepted.
ModifyMagicKeySource(Value, WriterFn := 0, NotifyFn := 0, ReloadFn := 0) {
	global ConfigurationFile
	if !MagicKeySourceIsCandidate(Value) && Value !== ManifestDefaultFor("hotstrings.magic_key_source") {
		LoggerWarn("Editors", "Refused physical magic key '{1}': no candidate key has that code.", String(Value))
		return false
	}
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ModifyMagicKeySource(Value, WriterFn, NotifyFn, ReloadFn)
		finally Critical(InheritedCritical)
	}
	Reason := MagicKeySourceChoiceReason(Value)
	if Reason != "" {
		if HasMethod(NotifyFn, "Call")
			NotifyFn.Call(Reason)
		else
			Ui_MsgBox(t(Reason), t("dialog.magic_key_source.title"), "Icon!")
		return false
	}
	if !_EditorWriteToml(ConfigurationFile, "the physical magic key",
			_EditorBuildMagicKeySourcePlan.Bind(Value), WriterFn, NotifyFn)
		return false
	return _EditorReloadAfterCommit(ReloadFn)
}

_EditorBuildRepeatKeyPlan() {
	global HSE_RepeatEnabled, Features
	if _FeatureUsesDesiredState(Features) {
		Candidate := !ReadFeatureStateV2("hotstrings.repeat_key_enabled")["enabled"]
		Plan := _FeatureBuildSinglePlan(Features, "hotstrings.repeat_key_enabled", Candidate, "")
		Plan.publish := _EditorPublishDesiredRepeatKey.Bind(Plan.publish)
		return Plan
	}
	Candidate := !HSE_RepeatEnabled
	return {
		updates: [{ Section: "hotstrings", Key: "repeat_key_enabled", Value: Candidate }],
		publish: _EditorPublishRepeatKey.Bind(Candidate),
	}
}

_EditorPublishDesiredRepeatKey(PublishFn) {
	global HSE_RepeatEnabled, Features
	PublishFn.Call()
	HSE_RepeatEnabled := Features["hotstrings"]["repeat_key_enabled"]
	if IsSet(HSE_AdvanceRuntimeDecisionGeneration)
		HSE_AdvanceRuntimeDecisionGeneration()
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
			Ui_MsgBox(t("dialog.personal_info.save_failed"),
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
		GuiToShow := Gui_Create(, t("dialog.personal_info.title"))
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
			Ui_MsgBox(t("dialog.personal_info.saved") "`n`n" PersonalInformationSummary)
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
		GuiToShow := Gui_Create(, t("dialog.gpt_link.title"))
		NewValue := GuiToShow.Add("Edit", "w300", CurrentLink)
		GuiToShow.Add("Button", "w100 Center", t("button.ok")).OnEvent("Click", (*) => ModifyLink(GuiToShow, NewValue.Text))
		GuiToShow.Show("Center")
}

_EditorBuildLinkPlan(NewValue) {
	global Features
	if _FeatureUsesDesiredState(Features)
		return _FeatureBuildSinglePlan(Features, "shortcuts.gpt", NewValue, "link")
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
