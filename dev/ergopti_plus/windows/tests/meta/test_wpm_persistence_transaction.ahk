; tests/meta/test_wpm_persistence_transaction.ahk

; ==============================================================================
; MODULE: WPM persistence transaction regression guard
; DESCRIPTION:
; The WPM menu used to mutate the live widget first and then discard both false
; and thrown TOML_BatchWrite failures. The visible menu state looked accepted,
; but the next reload restored a different state. Every WPM setting must now
; persist its candidate before the caller publishes the corresponding live UI.
; ==============================================================================

#Requires AutoHotkey v2.0

_WPMPT_Body(Name) {
    Body := _DriverFuncBody(Name)
    Assert(Body != "", Name . " must exist")
    return Body
}

_WPMPT_SaveHelperPropagatesFailure() {
    Body := _WPMPT_Body("_WPMWidget_SaveBuilt")
    Assert(InStr(Body, "ConfigCommitBuilt(ConfigurationFile") > 0,
        "WPM persistence must use the global configuration transaction gateway")
    Assert(InStr(Body, "TOML_BatchWrite(") = 0,
        "WPM persistence must not bypass global ownership with a direct TOML write")
    Assert(InStr(Body, "Committed is Integer") > 0 && InStr(Body, "Committed == 1") > 0,
        "WPM persistence must expose only a strict boolean commit result")
}
Test("wpm persistence: write helper reports failed TOML commits", _WPMPT_SaveHelperPropagatesFailure)

_WPMPT_SaveFunctionsPublishThroughGateway() {
    for Name in ["WPMWidget_SaveVisible", "WPMWidget_SavePosition", "WPMWidget_SaveConfig"] {
        Body := _WPMPT_Body(Name)
        PersistPos := InStr(Body, "_WPMWidget_SaveBuilt(")
        Assert(InStr(Body, "BuildFn :=") > 0 && InStr(Body, ".Bind(") > 0,
            Name . " must defer detached candidate construction until after ownership")
        Assert(PersistPos > 0 && InStr(Body, "WPMWidget.") = 0,
            Name . " must not read live widget state before the gateway admits it")
    }
    for Name in ["WPMWidget_ToggleVisibleConfig", "WPMWidget_ToggleColorsConfig",
            "WPMWidget_ToggleGraphConfig"] {
        Body := _WPMPT_Body(Name)
        Assert(InStr(Body, "_WPMWidget_SaveBuilt(") > 0,
            Name . " must send toggle intent through the owned builder gateway")
        Assert(InStr(Body, "!WPMWidget.") = 0,
            Name . " must not resolve its inversion before gateway admission")
    }
}
Test("wpm persistence: save functions publish detached candidates inside the gateway",
    _WPMPT_SaveFunctionsPublishThroughGateway)

_WPMPT_TogglePersistsBeforeVisibilityMutation() {
    Body := _WPMPT_Body("WPMWidget_Toggle")
    SavePos := InStr(Body, "WPMWidget_ToggleVisibleConfig(WriterFn, NotifyFn)")
    ShowPos := InStr(Body, "WPMWidget_Show()")
    HidePos := InStr(Body, "WPMWidget_Hide()")
    Assert(SavePos > 0 && ShowPos > SavePos && HidePos > SavePos,
        "WPMWidget_Toggle must save its candidate visibility before showing or hiding the widget")
    Assert(InStr(Body, "if !WPMWidget_ToggleVisibleConfig(WriterFn, NotifyFn)") > 0
        && InStr(Body, "!WPMWidget.visible") = 0,
        "WPMWidget_Toggle must leave live visibility untouched after a failed write")
}
Test("wpm persistence: visibility is committed before surface mutation", _WPMPT_TogglePersistsBeforeVisibilityMutation)

_WPMPT_MenuActionsCommitBeforePublish() {
    Colors := _WPMPT_Body("_ToggleWpmWidgetColors")
    ColorSave := InStr(Colors, "WPMWidget_ToggleColorsConfig(WriterFn, NotifyFn)")
    Assert(ColorSave > 0,
        "WPM colors toggle must submit its target through the persistence gateway")

    Graph := _WPMPT_Body("_ToggleWpmWidgetGraph")
    GraphSave := InStr(Graph, "WPMWidget_ToggleGraphConfig(WriterFn, NotifyFn)")
    HidePos := InStr(Graph, "WPMWidget_Hide()")
    DestroyPos := InStr(Graph, ".Destroy()")
    Assert(GraphSave > 0 && HidePos > GraphSave && DestroyPos > GraphSave,
        "WPM graph toggle must persist graph mode and reset anchor before tearing down its live surface")
    Assert(InStr(Colors, "WPMWidget.use_colors :=") = 0
        && InStr(Graph, "WPMWidget.show_graph :=") = 0
        && InStr(Graph, "WpmWidget.pos_x :=") = 0
        && InStr(Graph, "WpmWidget.pos_y :=") = 0,
        "WPM menu callers must not republish state after the owned commit")
    Assert(InStr(Colors, "!WPMWidget.use_colors") = 0
        && InStr(Graph, "!WPMWidget.show_graph") = 0,
        "WPM menu callers must pass toggle intent instead of resolving it before admission")
}
Test("wpm persistence: menu toggles publish only after durable commit", _WPMPT_MenuActionsCommitBeforePublish)

_WPMPT_DragUsesCandidatePosition() {
    Body := _WPMPT_Body("WPMWidget_DragEnd")
    SavePos := InStr(Body, "WPMWidget_SavePosition(NewX, NewY, WriterFn, NotifyFn)")
    RestorePos := InStr(Body, "_WPMWidget_ApplySurfaceGeometry(gui_ref)")
    Assert(SavePos > 0 && InStr(Body, "WPMWidget.pos_x :=") = 0
        && InStr(Body, "WPMWidget.pos_y :=") = 0,
        "WPM drag-end must leave candidate publication to the owned commit")
    Assert(InStr(Body, "if !WPMWidget_SavePosition(NewX, NewY, WriterFn, NotifyFn)") > 0
        && RestorePos > SavePos && InStr(Body, 'HasMethod(MoveFn, "Call")') > 0,
        "a refused dragged position must restore the live window from the retained anchor")
}
Test("wpm persistence: drag commits candidate coordinates before publication", _WPMPT_DragUsesCandidatePosition)

_WPMPT_AllNativeCloseEventsUseOwnedEntryPoint() {
    Compact := _WPMPT_Body("WPMWidget_BuildCompact")
    Graph := _WPMPT_Body("WPMWidget_BuildGraph")
    CloseBody := _WPMPT_Body("WPMWidget_Close")
    for Body in [Compact, Graph] {
        Assert(InStr(Body, 'g.OnEvent("Close", WPMWidget_Close)') > 0,
            "every WPM surface must route native close through the owned entry point")
        Assert(InStr(Body, '=> WPMWidget_Hide()') = 0,
            "no native close event may bypass persistence with a direct hide")
    }
    SavePos := InStr(CloseBody, "WPMWidget_SaveVisible(false, WriterFn, NotifyFn)")
    HidePos := InStr(CloseBody, "HideFn.Call()")
    FallbackHidePos := InStr(CloseBody, "WPMWidget_Hide()")
    NativeFallbackPos := InStr(CloseBody, "GuiObj.Hide()")
    Assert(SavePos > 0 && HidePos > SavePos && FallbackHidePos > SavePos,
        "the close entry point must persist explicit hidden state before either hide path")
    Assert(NativeFallbackPos > HidePos,
        "a failed hide seam must fall back to hiding the exact native Gui")
    Assert(InStr(CloseBody, "return true") > 0,
        "the close entry point must suppress Gui.Close's implicit hide on refusal")
}
Test("wpm persistence: every native close is gated by the global transaction",
    _WPMPT_AllNativeCloseEventsUseOwnedEntryPoint)
