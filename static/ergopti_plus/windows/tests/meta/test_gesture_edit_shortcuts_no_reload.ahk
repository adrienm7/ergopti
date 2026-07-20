; tests/meta/test_gesture_edit_shortcuts_no_reload.ahk

; ==============================================================================
; MODULE: "Open personal shortcuts" opens the editor, never restarts the driver
; DESCRIPTION:
; EnsurePersonalShortcutsFile bakes the boot-time policy "freshly written include
; chain => Reload so the include is picked up" and unconditionally ran Reload +
; ExitApp(0). GestureEditPersonalShortcuts called it then Run(notepad), but the
; process died at ExitApp before the Run — so triggering the open action while the
; file/stub needed (re)creation silently restarted the driver instead of opening the
; editor. The gesture path must suppress the reload. (F24, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_GESR_OpenEditorSuppressesReload() {
	Body := _DriverFuncBody("GestureEditPersonalShortcuts")
	Assert(Body != "", "GestureEditPersonalShortcuts must exist in modules/gestures/actions.ahk")

	EnsurePos := InStr(Body, "EnsurePersonalShortcutsFile(Path, false)")
	RunPos := InStr(Body, "Run(")
	Assert(EnsurePos > 0,
		"GestureEditPersonalShortcuts must pass the reload-suppressing argument (EnsurePersonalShortcutsFile(Path, false)) so opening the file cannot restart the driver")
	Assert(RunPos > 0, "GestureEditPersonalShortcuts must open the file in an editor (Run)")

	; The reload-suppressing parameter must exist on the ensure helper itself.
	Ensure := _DriverFuncBody("EnsurePersonalShortcutsFile")
	Assert(Ensure != "", "EnsurePersonalShortcutsFile must exist")
	Assert(InStr(Ensure, "AllowReload") > 0,
		"EnsurePersonalShortcutsFile must accept an AllowReload parameter so a runtime caller can skip the process-terminating Reload branch")
}
Test("gestures: open-personal-shortcuts opens the editor without restarting the driver",
	_GESR_OpenEditorSuppressesReload)
