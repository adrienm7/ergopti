; tests/support/legacy_cleanup_child.ahk

; ==============================================================================
; MODULE: Legacy Cleanup Child Fixture
; DESCRIPTION:
; A private guardian job owns this bounded child independently of the legacy
; finalizer under test, so injected termination refusals cannot orphan it.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

Sleep(60000)
ExitApp(0)
