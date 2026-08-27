; tests/meta/test_plain_paste_clipboard_sequence_ownership.ahk

; ==============================================================================
; MODULE: Plain-paste clipboard ownership regression test
; DESCRIPTION:
; Ctrl+Shift+V and the gesture action temporarily coerce the clipboard to text.
; Their deferred restores must be sequence-fenced just like SendInstant, or a
; copy performed after paste is silently overwritten by an old ClipboardAll.
; ==============================================================================

#Requires AutoHotkey v2.0

_PPCCSO_PlainPasteRestoreOwnsSequence() {
    Shortcut := _DriverFuncBody("PasteWithoutFormatting")
    ShortcutRestore := _DriverFuncBody("_PasteWithoutFormattingRestore")
    Gesture := _DriverFuncBody("GesturePastePlain")
    GestureRestore := _DriverFuncBody("_GesturePastePlainRestore")

    Assert(Shortcut != "" && ShortcutRestore != "" && Gesture != "" && GestureRestore != "",
        "both plain-paste flows and their restore workers must exist")
    for _, Body in [Shortcut, Gesture] {
        Assert(InStr(Body, "CB_SaveAll()") > 0 && InStr(Body, "CB_Write(PlainText)") > 0,
            "plain-paste flows must use a checked all-format clipboard transaction")
        Assert(InStr(Body, "OwnedSequence := CB_GetSequenceNumber()") > 0,
            "plain-paste flows must capture ownership after publishing their temporary payload")
    }
    for _, Restore in [ShortcutRestore, GestureRestore] {
        Assert(InStr(Restore, "CB_GetSequenceNumber() = OwnedSequence") > 0
                && InStr(Restore, "CB_RestoreAll(OldClip)") > 0,
            "plain-paste restore must not overwrite a later clipboard sequence")
        Assert(InStr(Restore, "finally") > 0
                && InStr(Restore, "CB_EndOwnedTransaction(OwnerToken)") > 0,
            "plain-paste restore must always release its exact shared owner token")
    }
}

Test("clipboard: plain-paste restore cannot overwrite a later user copy",
    _PPCCSO_PlainPasteRestoreOwnsSequence)
