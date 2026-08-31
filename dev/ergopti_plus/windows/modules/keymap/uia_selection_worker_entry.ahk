; modules/keymap/uia_selection_worker_entry.ahk

; ==============================================================================
; MODULE: UIA Probe Worker Entry
; DESCRIPTION:
; Minimal source-mode entrypoint for disposable UIA probes. Keeping the
; child on this small include graph avoids replaying the driver's complete boot
; before it can announce readiness. Compiled releases reuse the main executable
; because the same definitions are already embedded there.
; ==============================================================================

#Requires AutoHotkey v2.0+
#SingleInstance Off
#NoTrayIcon

; The disposable worker deliberately has no logger. Local no-ops cover the
; WindowInfo diagnostics it never executes and keep #Warn from opening an
; invisible modal dialog while the shared adapter is loaded.
LoggerDebug(Args*) => ""
LoggerError(Args*) => ""

#Include %A_ScriptDir%\..\..\vendor\UIA.ahk
#Include %A_ScriptDir%\..\..\adapters\window_info.ahk
#Include %A_ScriptDir%\..\..\adapters\uia_worker.ahk

UIASW_WorkerMain()
ExitApp(2)
