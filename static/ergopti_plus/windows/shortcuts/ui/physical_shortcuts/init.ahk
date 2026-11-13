; shortcuts/ui/physical_shortcuts/init.ahk

; ==============================================================================
; MODULE: Physical Shortcut Editor (Windows)
; DESCRIPTION:
; Loads the slot model, the editor protocol and the WebView2 host of the
; shared physical shortcut page, in dependency order.
; ==============================================================================

#Include %A_LineFile%\..\slots.ahk
#Include %A_LineFile%\..\editor.ahk
#Include %A_LineFile%\..\host.ahk
