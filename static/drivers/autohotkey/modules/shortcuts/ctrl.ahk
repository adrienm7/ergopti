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

if Features["shortcuts"]["save"] {
    AddShortcut("^", "j", (*) => SendFinalResult("^s"))
}
if Features["shortcuts"]["ctrl_j"] {
    AddShortcut("^", "s", (*) => SendFinalResult("^j"))
}

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

    PasteWithoutFormatting(*) {
        if not WinActive("ahk_exe EXCEL.EXE") {
            A_Clipboard := A_Clipboard
            SendFinalResult("^v")
        } else {
            SendFinalResult("^+v")
        }
    }
}
