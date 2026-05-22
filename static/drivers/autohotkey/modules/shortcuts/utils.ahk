; modules/shortcuts/utils.ahk

; ==============================================================================
; MODULE: Shortcuts — Utilities
; DESCRIPTION:
; Layout-aware shortcut registration helpers. AddShortcut resolves the physical
; scan code for a given letter at runtime so hotkeys survive keyboard-layout
; switches without a script reload.
; ==============================================================================

#Requires AutoHotkey v2.0

; ==============================
; ==============================
; ======= 1/ UTILITIES =======
; ==============================
; ==============================

; This function makes it possible to create a shortcut that works
; no matter the keyboard layout or the potential emulation of the Ergopti layout on top of it.
; If the keyboard layout changes, the script must be reloaded.
AddShortcut(Modifier, Letter, Callback) {
    Hotkey(Modifier . RetrieveScancode(Letter), Callback)
}

RetrieveScancode(Letter) {
    if RemappedList.Has(Letter) {
        return RemappedList[Letter]
    }
    return Format("sc{:x}", GetKeySC(Letter))
}
