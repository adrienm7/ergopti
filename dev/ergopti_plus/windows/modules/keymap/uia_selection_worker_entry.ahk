; modules/keymap/uia_selection_worker_entry.ahk

; ==============================================================================
; MODULE: UIA Selection Worker Entry
; DESCRIPTION:
; Minimal source-mode entrypoint for the disposable selection probe. Keeping the
; child on this small include graph avoids replaying the driver's complete boot
; before it can announce readiness. Compiled releases reuse the main executable
; because the same definitions are already embedded there.
; ==============================================================================

#Requires AutoHotkey v2.0+
#SingleInstance Off
#NoTrayIcon

; window_info.ahk's list-enumeration path has one debug call. The disposable
; worker uses only WIGetFocusedControlToken and deliberately has no logger; this
; local no-op keeps #Warn from opening an invisible modal dialog during load.
LoggerDebug(Args*) => ""

#Include %A_ScriptDir%\..\..\vendor\UIA.ahk
#Include %A_ScriptDir%\..\..\adapters\window_info.ahk
#Include %A_ScriptDir%\..\..\adapters\uia_worker.ahk

UIASW_WorkerMain()
ExitApp(2)
