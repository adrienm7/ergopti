; layouts/ui/layout_manager/kbd_register.ahk

; ==============================================================================
; MODULE: Keyboard Layout DLL Registration Entry
; DESCRIPTION:
; The elevated source-mode entry of the layout DLL registration
; (kbd_register_core.ahk): `kbd_register.ahk install <staging dir>` and
; `kbd_register.ahk uninstall <dll> [<staging dir>]`. The layout manager starts
; it with *RunAs, the one UAC prompt of an install; Settings > Apps starts the
; uninstall through the entry it registered. Compiled releases reuse the main
; executable with --kbd-register, which ErgoptiPlus.ahk dispatches before the
; driver initialises. Keeping it on this small include graph avoids replaying
; the driver's boot in an administrator process.
; ==============================================================================

#Requires AutoHotkey v2.0+
#SingleInstance Off
#NoTrayIcon

; The elevated process has no logger: its result reaches the driver as
; result.json, and the crypto adapter's diagnostics are no-ops here.
LoggerError(Args*) => ""

#Include %A_ScriptDir%\..\..\infra\json.ahk
#Include %A_ScriptDir%\..\..\adapters\crypto.ahk
#Include %A_ScriptDir%\kbd_register_core.ahk

KbdRegister_Main()
