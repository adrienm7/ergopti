; tests/meta/test_editor_persist_before_publish.ahk

; ============================================================================== 
; MODULE: Editor persist-before-publish regression test
; DESCRIPTION:
; TOML writers return false on ordinary write failures. Editor callbacks must
; keep live state and reload/menu publication untouched until persistence wins.
; ============================================================================== 

#Requires AutoHotkey v2.0

_EPPP_EditorWritesBeforePublishingLiveState() {
    for _, Name in ["ModifyMagicKey", "ToggleRepeatKeyEnabled", "ModifyLink"] {
        Body := _DriverFuncBody(Name)
        PersistPos := InStr(Body, "_EditorWriteToml(")
        Assert(PersistPos > 0, Name . " must gate state publication on _EditorWriteToml")
        if (Name = "ModifyMagicKey")
            PublishPos := InStr(Body, 'ScriptInformation["MagicKey"] :=')
        else if (Name = "ToggleRepeatKeyEnabled")
            PublishPos := InStr(Body, "HSE_RepeatEnabled := Candidate")
        else
            PublishPos := InStr(Body, 'Features["shortcuts"]["gpt"]["link"] :=')
        Assert(PublishPos > PersistPos,
            Name . " must persist successfully before mutating its live configuration")
    }
    Helper := _DriverFuncBody("_EditorWriteToml")
    Assert(InStr(Helper, "return false") > 0 && InStr(Helper, "MsgBox") > 0,
        "failed editor persistence must be explicit to the user and return false")
}

Test("ui editors: persistence succeeds before live state is published", _EPPP_EditorWritesBeforePublishingLiveState)
