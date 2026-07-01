; modules/shortcuts/ctrl.ahk

; ==============================================================================
; MODULE: Shortcuts — Ctrl Combos
; DESCRIPTION:
; Ctrl-layer shortcuts: Save/CtrlJ swap, Microsoft Bold fix, and
; PasteWithoutFormatting.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 3/ CTRL SHORTCUTS =======
; =================================
; =================================

if Features["shortcuts"]["microsoft_bold"] {
    ; Makes it possible to use the standard shortcuts instead of their translation in Microsoft apps
    AddShortcut(
        "^", "b",
        (*) => MicrosoftApps() ? SendFinalResult("^g") : SendFinalResult("^b")
    )
}

if Features["shortcuts"]["paste_without_formatting"] {
    ; Ctrl + Shift + V -- paste plain text everywhere except Excel, which keeps
    ; its native paste-special behaviour (re-assigning the standard combo there
    ; would break the user's expected workflow).
    AddShortcut("^+", "v", PasteWithoutFormatting)

    ; Deferred clipboard restore for PasteWithoutFormatting. Runs on a negative-delay
    ; SetTimer so the synthetic ^v has already consumed the coerced text before the
    ; user's original (possibly non-text) clipboard is put back.
    _PasteWithoutFormattingRestore(OldClip) {
        global _SEND_INSTANT_CLIP_BUSY
        A_Clipboard := OldClip
        _SEND_INSTANT_CLIP_BUSY := false
    }

    PasteWithoutFormatting(*) {
        global _SEND_INSTANT_CLIP_BUSY
        if not WinActive("ahk_exe EXCEL.EXE") {
            ; Strip rich formatting only when the clipboard holds text. CB_Read()
            ; returns "" for non-text payloads (image/file list); the self-assign
            ; round-trip on those would destroy them, so we skip the strip and
            ; paste the content as-is instead.
            if CB_Read() != "" {
                ; Skip the save/restore dance while SendInstant is already mid-flight
                ; to avoid a second thread trampling the in-flight clipboard before
                ; the first paste settles -- mirrors GesturePastePlain's guard.
                if _SEND_INSTANT_CLIP_BUSY {
                    SendFinalResult("^v")
                    return
                }
                ; Snapshot the FULL clipboard (all formats) before coercing to
                ; plain text. A_Clipboard := A_Clipboard keeps only the text form,
                ; silently dropping any image/HTML/RTF the user may still want, so
                ; we restore the original after the paste settles -- mirroring
                ; GesturePastePlain's save/paste/deferred-restore guarantee.
                _SEND_INSTANT_CLIP_BUSY := true
                OldClip := ClipboardAll()
                try {
                    A_Clipboard := A_Clipboard
                    SendFinalResult("^v")
                    SetTimer(_PasteWithoutFormattingRestore.Bind(OldClip), -SEND_INSTANT_PASTE_DELAY_MS)
                } catch as e {
                    A_Clipboard := OldClip
                    _SEND_INSTANT_CLIP_BUSY := false
                    try LoggerError("shortcuts", "PasteWithoutFormatting threw during paste — clipboard and guard restored: {1}.", e.Message)
                }
            } else {
                SendFinalResult("^v")
            }
        } else {
            SendFinalResult("^+v")
        }
    }
}
