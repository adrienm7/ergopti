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
    Body := _WPMPT_Body("_WPMWidget_SaveBatch")
    Assert(InStr(Body, "if TOML_BatchWrite") > 0,
        "WPM persistence must branch on TOML_BatchWrite instead of swallowing its result")
    Assert(InStr(Body, "LoggerError") > 0 && InStr(Body, "return false") > 0,
        "WPM persistence failures must be logged and returned to the caller")
}
Test("wpm persistence: write helper reports failed TOML commits", _WPMPT_SaveHelperPropagatesFailure)

_WPMPT_TogglePersistsBeforeVisibilityMutation() {
    Body := _WPMPT_Body("WPMWidget_Toggle")
    SavePos := InStr(Body, "WPMWidget_SaveVisible(TargetVisible)")
    ShowPos := InStr(Body, "WPMWidget_Show()")
    HidePos := InStr(Body, "WPMWidget_Hide()")
    Assert(SavePos > 0 && ShowPos > SavePos && HidePos > SavePos,
        "WPMWidget_Toggle must save its candidate visibility before showing or hiding the widget")
    Assert(InStr(Body, "if !WPMWidget_SaveVisible(TargetVisible)") > 0,
        "WPMWidget_Toggle must leave live visibility untouched after a failed write")
}
Test("wpm persistence: visibility is committed before surface mutation", _WPMPT_TogglePersistsBeforeVisibilityMutation)

_WPMPT_MenuActionsCommitBeforePublish() {
    Colors := _WPMPT_Body("_ToggleWpmWidgetColors")
    ColorSave := InStr(Colors, "WPMWidget_SaveConfig(TargetColors)")
    ColorPublish := InStr(Colors, "WPMWidget.use_colors := TargetColors")
    Assert(ColorSave > 0 && ColorPublish > ColorSave,
        "WPM colors toggle must persist TargetColors before publishing it live")

    Graph := _WPMPT_Body("_ToggleWpmWidgetGraph")
    GraphSave := InStr(Graph, "WPMWidget_SaveConfig(unset, TargetGraph, -1, -1)")
    HidePos := InStr(Graph, "WPMWidget_Hide()")
    DestroyPos := InStr(Graph, ".Destroy()")
    Assert(GraphSave > 0 && HidePos > GraphSave && DestroyPos > GraphSave,
        "WPM graph toggle must persist graph mode and reset anchor before tearing down its live surface")
}
Test("wpm persistence: menu toggles publish only after durable commit", _WPMPT_MenuActionsCommitBeforePublish)

_WPMPT_DragUsesCandidatePosition() {
    Body := _WPMPT_Body("WPMWidget_DragEnd")
    SavePos := InStr(Body, "WPMWidget_SavePosition(NewX, NewY)")
    PublishPos := InStr(Body, "WPMWidget.pos_x := NewX")
    Assert(SavePos > 0 && PublishPos > SavePos,
        "WPM drag-end must persist candidate coordinates before updating shared position state")
}
Test("wpm persistence: drag commits candidate coordinates before publication", _WPMPT_DragUsesCandidatePosition)
