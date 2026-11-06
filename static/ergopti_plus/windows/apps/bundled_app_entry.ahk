; apps/bundled_app_entry.ahk

; ==============================================================================
; MODULE: Bundled App Entry
; DESCRIPTION:
; Minimal source-mode entry point of the bundled App Cloner and Encryptor
; (apps/bundled_apps.ahk). Keeping the app on this small include graph avoids
; replaying the driver's whole boot. Compiled releases reuse the main
; executable with --bundled-app, because the same definitions are embedded
; there (ErgoptiPlus.ahk dispatches before the driver initialises).
; ==============================================================================

#Requires AutoHotkey v2.0+
#SingleInstance Off
#NoTrayIcon

; The app process has no logger: the crypto adapter's diagnostics are no-ops
; here, and every failure the user can act on reaches them as a dialog.
LoggerError(Args*) => ""

#Include %A_ScriptDir%\..\_generated\window_titles.ahk
#Include %A_ScriptDir%\..\infra\native_dialogs.ahk
#Include %A_ScriptDir%\..\infra\json.ahk
#Include %A_ScriptDir%\..\adapters\crypto.ahk
#Include %A_ScriptDir%\..\adapters\bundled_apps_native.ahk
#Include %A_ScriptDir%\app_strings.ahk
#Include %A_ScriptDir%\encryptor_core.ahk
#Include %A_ScriptDir%\app_cloner_core.ahk
#Include %A_ScriptDir%\bundled_apps.ahk

BundledApp_Main(A_ScriptDir . "\..\..\_shared")
