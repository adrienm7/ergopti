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

; Reads gesture assignments from the v2 [ahk.gestures] section.
GesturesReadConfig() {
    global GestureAssignments, GestureActionParameters, _IniCache, GESTURE_ACTIONS

    for _, Slot in GESTURE_SLOTS {
        Value := IniCacheGet(_IniCache, "ahk.gestures", Slot)
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
    if _IniCache.Has("ahk.action_parameters") {
        for BindingAction, Value in _IniCache["ahk.action_parameters"]
            GestureActionParameters[BindingAction] := Value
    }
}

; Saves a single gesture assignment to the v2 [ahk.gestures] section.
GestureSaveAssignment(slot, action) {
    global GestureAssignments, ConfigurationFile

    GestureAssignments[slot] := action
    TOML_Write(action, ConfigurationFile, "ahk.gestures", slot)
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

GestureSetActionParameter(BindingId, ActionName, Value) {
    global GestureActionParameters, ConfigurationFile
    Key := GestureActionParameterKey(BindingId, ActionName)
    GestureActionParameters[Key] := Value
    TOML_Write(Value, ConfigurationFile, "ahk.action_parameters", Key)
}

GestureActionParameterSpec(ActionName) {
    global GESTURE_ACTION_PARAMETER_SPECS
    return GESTURE_ACTION_PARAMETER_SPECS.Has(ActionName) ? GESTURE_ACTION_PARAMETER_SPECS[ActionName] : ""
}

GestureValidateActionParameter(ActionName, Value, &ErrorText := "") {
    Spec := GestureActionParameterSpec(ActionName)
    Value := Trim(Value)
    if (Spec = "")
        return true
    if !RegExMatch(Value, "i)^https?://[^\s]+$") {
        ErrorText := "Saisissez une URL http:// ou https:// valide."
        return false
    }
    PlaceholderAt := InStr(Value, "%s")
    if (Spec = "search_url" && PlaceholderAt = 0) {
        ErrorText := "L’URL de recherche doit contenir %s à l’emplacement de la requête."
        return false
    }
    if (Spec = "search_url" && InStr(Value, "%s",, PlaceholderAt + 2) != 0) {
        ErrorText := "L’URL de recherche doit contenir un seul emplacement %s."
        return false
    }
    return true
}

; The native dialog is mandatory for every parameterized action assignment.
; Cancel keeps the existing assignment unchanged.
GestureEnsureActionParameter(BindingId, ActionName) {
    Spec := GestureActionParameterSpec(ActionName)
    if (Spec = "")
        return true
    Existing := GestureGetActionParameter(BindingId, ActionName)
    Prompt := (Spec = "search_url")
        ? "URL du moteur de recherche (incluez exactement un %s pour la requête) :"
        : "Lien à ouvrir :"
    loop {
        Result := InputBox(Prompt, "Configurer " . _GestureActionLabel(ActionName), "w680 h160", Existing)
        if (Result.Result != "OK")
            return false
        Value := Trim(Result.Value)
        ErrorText := ""
        if GestureValidateActionParameter(ActionName, Value, &ErrorText) {
            GestureSetActionParameter(BindingId, ActionName, Value)
            return true
        }
        MsgBox(ErrorText, "Valeur invalide", "Icon!")
        Existing := Value
    }
}

GestureActionDisplayLabel(ActionName, BindingId := "") {
    Label := _GestureActionLabel(ActionName)
    if (BindingId = "")
        return Label
    Value := GestureGetActionParameter(BindingId, ActionName)
    return (Value != "") ? Label . " (" . Value . ")" : Label
}

; Preserve the zero-argument contract for ordinary actions (including user
; extensions) while passing binding context only to actions that declare it.
GestureInvokeAction(ActionName, BindingId := "") {
    global GESTURE_ACTIONS
    if !GESTURE_ACTIONS.Has(ActionName)
        return
    Fn := GESTURE_ACTIONS[ActionName].Fn
    ; Containment lives HERE, at the single choke point all three dispatchers share
    ; (gesture, keyboard-shortcut slot, tap-hold). Only GestureDispatch wrapped the
    ; call, so a throwing action reached via a shortcut slot (RunKeyboardShortcutAction)
    ; or a tap-hold (_TapHoldInvokeConfiguredAction) propagated uncaught into the error
    ; net. Fail loud in the log, never rethrow (§5.3) — every dispatcher keeps working.
    try {
        if (GestureActionParameterSpec(ActionName) != "")
            return Fn.Call(BindingId)
        return Fn.Call()
    } catch as e {
        LoggerError("gestures", "Action '{1}' (binding '{2}') threw: {3}.", ActionName, BindingId, e.Message)
    }
}

GestureSaveAllAssignments(ActionNameBySlot) {
    global GestureAssignments, ConfigurationFile
    Updates := []
    for Slot, ActionName in ActionNameBySlot {
        GestureAssignments[Slot] := ActionName
        Updates.Push({ Section: "ahk.gestures", Key: Slot, Value: ActionName })
    }
    return TOML_BatchWrite(ConfigurationFile, Updates)
}

; Writes a single REG_DWORD value via RegistryLib, counting failures.
GestureRegWriteDword(ValueName, Value, &ErrorsRef) {
    global GESTURE_REG_PATH

    if (!Reg_WriteDword(GESTURE_REG_PATH, ValueName, Value))
        ErrorsRef += 1
}

; Configures Windows touchpad gestures via the registry so that all 10 gesture
; slots send Ctrl+Win+Shift+F1..F10 without any manual Settings configuration.
; Writes the master enables, per-direction enables, Custom*Tap sentinels,
; KeyParams (encoded as (VK<<16)|7), and resets the new-system *Action values
; to 65535 so the old KeyParams system takes precedence.
; Returns true on success, false if any registry write failed.
GestureAutoConfigureRegistry(OnDone := 0) {
    global GESTURE_REG_PATH, GESTURE_REG_CUSTOM_VALUE
    global GESTURE_REG_ACTIONS, GESTURE_REG_KEY_PARAMS, GESTURE_REG_KEY_PARAMS_NAMES
    global GESTURE_REG_ENABLE_NAMES, GESTURE_REG_CUSTOM_TAP_NAMES
    global GESTURE_REG_CUSTOM_TAP_VALUE, GESTURE_REG_MASTER_ENABLES, GESTURE_SLOTS

    LoggerStart("gestures", "Auto-configuring touchpad gestures via registry…")
    Errors := 0

    ; Master enables — turn the gesture families on
    for _, Name in GESTURE_REG_MASTER_ENABLES {
        GestureRegWriteDword(Name, GESTURE_REG_CUSTOM_VALUE, &Errors)
    }

    ; Per-slot configuration
    for _, Slot in GESTURE_SLOTS {
        ; Direction enables (swipes only)
        if GESTURE_REG_ENABLE_NAMES.Has(Slot) {
            GestureRegWriteDword(GESTURE_REG_ENABLE_NAMES[Slot],
                GESTURE_REG_CUSTOM_VALUE, &Errors)
        }
        ; Custom*Tap=7 sentinel for tap slots
        if GESTURE_REG_CUSTOM_TAP_NAMES.Has(Slot) {
            GestureRegWriteDword(GESTURE_REG_CUSTOM_TAP_NAMES[Slot],
                GESTURE_REG_CUSTOM_TAP_VALUE, &Errors)
        }
        ; KeyParams — actual shortcut encoding (Ctrl+Win+Shift+Fn)
        GestureRegWriteDword(GESTURE_REG_KEY_PARAMS_NAMES[Slot],
            GESTURE_REG_KEY_PARAMS[Slot], &Errors)
        ; New-system *Action — 65535 disables it so KeyParams takes precedence
        GestureRegWriteDword(GESTURE_REG_ACTIONS[Slot],
            GESTURE_REG_CUSTOM_VALUE, &Errors)
    }

    if (Errors > 0) {
        LoggerError("gestures", "Auto-configuration failed with {1} error(s).", Errors)
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
global _GestureRestartJob := Map("epoch", 0, "pid", 0, "script", "", "result", "", "done", 0)

GestureRestartTouchpadDevice(OnDone := 0) {
    global _GestureRestartJob
    LoggerStart("gestures", "Restarting touchpad device to apply gesture config…")
    if _GestureRestartJob["pid"] {
        if ProcessExist(_GestureRestartJob["pid"]) {
            LoggerError("gestures", "Touchpad restart is already running.")
            return False
        }
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
    FSDelete(ResultPath)
    if !FSWrite(ScriptPath, _GestureRestartBuildPsScript(ResultPath)) {
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
        LoggerError("gestures", "Failed to restart touchpad device: {1}.", e.Message)
        return False
    }
    _GestureRestartJob := Map("epoch", Epoch, "pid", RestartPid, "script", ScriptPath, "result", ResultPath, "done", OnDone)
    SetTimer(_GestureRestartPoll.Bind(Epoch), -100)
    LoggerSuccess("gestures", "Touchpad restart worker launched (PID {1}).", RestartPid)
    return True
}

_GestureRestartPoll(Epoch) {
    global _GestureRestartJob
    if (_GestureRestartJob["epoch"] != Epoch || !_GestureRestartJob["pid"])
        return
    ; Suspend does not stop timers. Preserve the completion until the driver
    ; resumes rather than presenting status or invoking a user callback while
    ; suspended.
    if A_IsSuspended {
        SetTimer(_GestureRestartPoll.Bind(Epoch), -100)
        return
    }
    if ProcessExist(_GestureRestartJob["pid"]) {
        SetTimer(_GestureRestartPoll.Bind(Epoch), -100)
        return
    }
    Ok := _GestureRestartReadResult(_GestureRestartJob["result"])
    Done := _GestureRestartJob["done"]
    FSDelete(_GestureRestartJob["script"])
    FSDelete(_GestureRestartJob["result"])
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
    if (Result = false) {
        try LoggerError("gestures", "Touchpad restart result missing.")
        return False
    }
    Result := Trim(Result)
    return (Result = "0")
}

_GestureRestartBuildPsScript(ResultPath) {
    CRLF := "`r`n"
    ResultLiteral := StrReplace(ResultPath, "'", "''")
    S := "$ErrorActionPreference = 'Stop'" . CRLF
    S .= "$ResultPath = '" . ResultLiteral . "'" . CRLF
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
    S .= "try { [System.IO.File]::WriteAllText($ResultPath, [string]$ErgoptiExitCode, [System.Text.Encoding]::ASCII) } catch { exit 1 }" . CRLF
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
    tg := Gui("+AlwaysOnTop", t("onboarding.gestures.register_manual"))
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
    try Run("ms-settings:devices-touchpad")
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
