; tests/meta/test_sendinstant_clipboard_sequence_ownership.ahk

; ==============================================================================
; MODULE: SendInstant clipboard ownership regression test
; DESCRIPTION:
; The restore timer must never overwrite a user copy made after SendInstant
; published its temporary paste payload. The Win32 sequence number is the
; ownership fence; the busy latch still has to release if restore fails.
; ==============================================================================

#Requires AutoHotkey v2.0

_SICSO_SendInstantRestoreOwnsSequence() {
    SendBody := _DriverFuncBody("SendInstant")
    Restore := _DriverFuncBody("_SendInstant_RestoreClipboard")

    Assert(SendBody != "" && Restore != "", "SendInstant and its restore worker must exist")
    Assert(InStr(SendBody, "CB_SaveAll()") > 0 && InStr(SendBody, "CB_Write(Text)") > 0,
        "SendInstant must use the clipboard adapter for its all-format transaction")
    Assert(InStr(SendBody, "OwnedSequence := CB_GetSequenceNumber()") > 0,
        "SendInstant must capture the sequence immediately after publishing its payload")
    Assert(InStr(SendBody, "_SendInstant_RestoreClipboard.Bind(OldClipboard, OwnedSequence)") > 0,
        "SendInstant must bind its owned sequence to the deferred restore")
    Assert(InStr(Restore, "CB_GetSequenceNumber() = OwnedSequence") > 0
            && InStr(Restore, "CB_RestoreAll(OldClip)") > 0,
        "SendInstant restore must restore only while it still owns the clipboard sequence")
    Assert(InStr(Restore, "finally") > 0
            && InStr(Restore, "_SEND_INSTANT_CLIP_BUSY := false") > 0,
        "SendInstant restore must release the busy latch even when clipboard restoration fails")
}

Test("hotstrings: SendInstant restores only its own clipboard sequence",
    _SICSO_SendInstantRestoreOwnsSequence)
