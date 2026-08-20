; tests/meta/test_gesture_edit_shortcuts_no_reload.ahk

; ==============================================================================
; MODULE: Personal Shortcuts Runtime Editor Reload Guard
; DESCRIPTION:
; EnsurePersonalShortcutsFile bakes the boot-time policy "freshly written include
; chain => Reload so the include is picked up" and unconditionally ran Reload +
; ExitApp(0). Every user-triggered editor action must suppress that boot-only
; branch, or the process dies before Run(notepad) when a file or stub is created.
;
; ROOT CAUSE ENCODED:
; The first fix covered the gesture caller but left the tray sibling on the
; default. This guard enumerates the complete production call class, permits one
; boot caller, and requires both runtime editor bodies to pass literal false and
; reach their editor launch afterward. (F24 and AHK-21.)
; ==============================================================================

#Requires AutoHotkey v2.0

_GESR_AllRuntimeEditorsSuppressReload() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the personal-shortcuts callsite guard")

	Pattern := "EnsurePersonalShortcutsFile\(([^)\r\n]*)\)"
	Pos := 1
	CallCount := 0
	BootCount := 0
	RuntimeSafeCount := 0
	while (Pos := RegExMatch(Src, Pattern, &Match, Pos)) {
		Args := Trim(Match[1])
		Pos += Match.Len
		if InStr(Args, ":=")
			continue
		CallCount += 1
		if InStr(Args, 'ScriptInformation["PersonalAhkPath"]')
			BootCount += 1
		else if RegExMatch(Args, "^Path\s*,\s*false$")
			RuntimeSafeCount += 1
	}

	AssertEqual(CallCount, 3,
		"every EnsurePersonalShortcutsFile production caller must be inventoried")
	AssertEqual(BootCount, 1,
		"only the boot call may use the reload-enabled default")
	AssertEqual(RuntimeSafeCount, 2,
		"both runtime editor callers must pass false and suppress reload")

	for Name in ["GestureEditPersonalShortcuts", "OpenPersonalShortcuts"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist in the driver source")
		EnsurePos := InStr(Body, "EnsurePersonalShortcutsFile(Path, false)")
		RunPos := InStr(Body, "Run(")
		Assert(EnsurePos > 0,
			Name . " must pass the reload-suppressing false argument")
		Assert(RunPos > EnsurePos,
			Name . " must reach the editor launch after ensuring the file")
	}

	Ensure := _DriverFuncBody("EnsurePersonalShortcutsFile")
	Assert(Ensure != "", "EnsurePersonalShortcutsFile must exist")
	Assert(InStr(Ensure, "AllowReload") > 0,
		"EnsurePersonalShortcutsFile must retain the explicit boot/runtime policy parameter")
}
Test("personal shortcuts: every runtime editor suppresses boot-only reload (personal-shortcuts-runtime-no-reload)",
	_GESR_AllRuntimeEditorsSuppressReload)
