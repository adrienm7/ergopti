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
    global GestureAssignments, GestureActionParameters, _IniCache

    for _, Slot in GESTURE_SLOTS {
        Value := IniCacheGet(_IniCache, "ahk.gestures", Slot)
        if (Value != "_") {
            GestureAssignments[Slot] := Value
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
    if (GestureActionParameterSpec(ActionName) != "")
        return Fn.Call(BindingId)
    return Fn.Call()
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
GestureAutoConfigureRegistry() {
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
    GestureRestartTouchpadDevice()

    LoggerSuccess("gestures", "All gesture registry values written successfully.")
    return True
}

; Disables then re-enables the touchpad PnP device to force the gesture
; driver to reload its configuration from the registry. Requires admin
; elevation — triggers a UAC prompt via the *RunAs verb.
GestureRestartTouchpadDevice() {
    LoggerStart("gestures", "Restarting touchpad device to apply gesture config…")

    ; Target the "Microsoft Input Configuration Device" — this is the HID
    ; collection node that exposes the Precision Touchpad gesture surface
    ; and reloads its config from the registry on enable. The parent I2C HID
    ; node alone is not enough; we also toggle it as a fallback to cover
    ; vendor variations.
    PsCmd := "$ErrorActionPreference='Stop'; "
        . "$devs = Get-PnpDevice -PresentOnly | Where-Object { "
        . "$_.Class -eq 'HIDClass' -and ( "
        . "$_.FriendlyName -match 'Input Configuration|I2C HID' "
        . ") }; "
        . "foreach ($d in $devs) { "
        . "  Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:`$false -ErrorAction SilentlyContinue "
        . "}; "
        . "Start-Sleep -Milliseconds 500; "
        . "foreach ($d in $devs) { "
        . "  Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:`$false -ErrorAction SilentlyContinue "
        . "}"

    try {
        ; A UAC-approved PnP restart can take tens of seconds.  Launch it and
        ; return to the message pump immediately: RunWait here stalls every
        ; hook, timer, and tray callback on the single AHK thread.
        Run('*RunAs powershell.exe -NoProfile -WindowStyle Hidden -Command "' . PsCmd . '"', , "Hide", &RestartPid)
        LoggerSuccess("gestures", "Touchpad restart command launched (PID {1}).", RestartPid)
    } catch as e {
        LoggerError("gestures", "Failed to restart touchpad device: {1}.", e.Message)
    }
}

; Build the body of the manual-setup tutorial. Shared by the tray menu and the
; onboarding wizard so the wording stays in lockstep between them.
;
; Locale fragments already embed their own trailing newlines (one after each
; section, two after the header), so they are concatenated as-is here — adding
; extra ``\n`` separators surfaced as visible blank-line clutter inside the
; rendered popup.
GestureBuildSetupInstructions() {
    Body := t("gesture.setup.header") . t("gesture.setup.open_path") . t("gesture.setup.for_each")
    if IsSet(GESTURE_SLOTS) and IsSet(GESTURE_SHORTCUT_LABELS) {
        for _, Slot in GESTURE_SLOTS {
            Body .= "  " . t("gesture.slots." . Slot) . " :  "
                . GESTURE_SHORTCUT_LABELS[Slot] . "`n"
        }
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
    LoggerStart("gestures", "Running deferred touchpad auto-configuration…")
    Ok := false
    try {
        Ok := GestureAutoConfigureRegistry()
    } catch as e {
        LoggerError("gestures", "Deferred auto-configuration threw: {1}.", e.Message)
        return
    }
    if Ok {
        LoggerSuccess("gestures", "Deferred touchpad auto-configuration completed.")
    } else {
        LoggerWarn("gestures", "Deferred touchpad auto-configuration reported failure — user can retry from the tray menu.")
    }
}
