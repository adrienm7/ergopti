; ui/editors.ahk

; ==============================================================================
; MODULE: Config Editors (GUI dialogs)
; DESCRIPTION:
; Small modal GUI editors for user-configurable values: the magic key, the
; repeat-key toggle, personal information, and the ChatGPT link. Extracted
; verbatim from ErgoptiPlus.ahk (P4 entrypoint decomposition) and #Include'd at
; the original position so boot order is unchanged. Functions are hoisted, so
; their menu/hotkey call sites elsewhere are unaffected.
; ==============================================================================

MagicKeyEditor(*) {
    GuiToShow := Gui_Create("+AlwaysOnTop", t("dialog.magic_key.title"))
    GuiToShow.Add("Text", "w300", t("dialog.magic_key.prompt"))
    GuiToShow.Add("Text", "w300", t("button.cancel") . " → Echap")
    GuiToShow.Show("Center")
    IH := InputHook("L1 I", "{Escape}")
    GuiToShow.OnEvent("Close", _MagicKeyEditorClose.Bind(IH))
    IH.Start()
    IH.Wait()
    ; The Close event may already have destroyed the native window.
    try GuiToShow.Destroy()
    if (IH.EndReason = "Max" && IH.Input != "")
        ModifyMagicKey(0, IH.Input)
}

_MagicKeyEditorClose(IH, GuiToClose, *) {
    ; Closing the dialog is cancellation. Stop its suppressive InputHook now
    ; so the next user key cannot be consumed by an orphaned capture.
    try IH.Stop()
}

_EditorWriteToml(Value, Path, Section, Key) {
    try {
        if TOML_Write(Value, Path, Section, Key)
            return true
    } catch as e {
        try LoggerError("Editors", "Could not persist {1}.{2}: {3}", Section, Key, e.Message)
    }
    try LoggerError("Editors", "Could not persist {1}.{2}; live state was left unchanged.", Section, Key)
    MsgBox(t("onboarding.error.write_failed"), t("editor.hotstrings.save_error"), "Icon!")
    return false
}

ModifyMagicKey(gui, NewValue) {
    global ScriptInformation, Features, ConfigurationFile
    if !_EditorWriteToml(NewValue, ConfigurationFile, "hotstrings", "trigger_char")
        return false
    ScriptInformation["MagicKey"] := NewValue
    if IsSet(Features) and Features.Has("hotstrings") {
        Features["hotstrings"]["trigger_char"] := NewValue
    }
    if (gui != 0)
        gui.Destroy()
    ReloadPreservingSuspend()
}

ToggleRepeatKeyEnabled(*) {
    global HSE_RepeatEnabled, Features, ConfigurationFile
    Candidate := !HSE_RepeatEnabled
    if !_EditorWriteToml(Candidate, ConfigurationFile, "hotstrings", "repeat_key_enabled")
        return false
    HSE_RepeatEnabled := Candidate
    if IsSet(Features) and Features.Has("hotstrings") {
        Features["hotstrings"]["repeat_key_enabled"] := HSE_RepeatEnabled
    }
    ; No Reload: the repeat key is a pure runtime flag the engine reads live
    ; (HSE_TryRepeatKey checks HSE_RepeatEnabled on every keystroke). Just
    ; rebuild the tray so the checkmark reflects the new state.
    RebuildTrayMenu()
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

ProcessUserInput(gui, edits) {
    global PersonalInformation, ScriptInformation
    changed := Map()
    for key, editControl in edits {
        NewValue := editControl.Text
        OldValue := PersonalInformation.Has(key) ? PersonalInformation[key] : ""
        if (NewValue != OldValue)
            changed[key] := True
        PersonalInformation[key] := NewValue
    }
    WritePersonalInfoToml(ScriptInformation["PersonalInfoTomlPath"])
    gui.Destroy()
    PersonalInformationSummary := ""
    for key, _ in edits {
        NewValue := PersonalInformation[key]
        line := key ": " NewValue "`n"
        if changed.Has(key) {
            PersonalInformationSummary := PersonalInformationSummary line
        }
    }
    MsgBox(t("dialog.personal_info.saved") "`n`n" PersonalInformationSummary)
    ReloadPreservingSuspend()
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

ModifyLink(gui, NewValue) {
    global Features, ConfigurationFile
    if !_EditorWriteToml(NewValue, ConfigurationFile, "ahk.shortcuts.gpt", "link")
        return false
    if IsSet(Features) and Features.Has("shortcuts") and Features["shortcuts"].Has("gpt") {
        Features["shortcuts"]["gpt"]["link"] := NewValue
    }
    gui.Destroy()
    ReloadPreservingSuspend()
}
