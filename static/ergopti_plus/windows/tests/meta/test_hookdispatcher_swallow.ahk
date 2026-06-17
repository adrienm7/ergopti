; tests/meta/test_hookdispatcher_swallow.ahk

; ==============================================================================
; MODULE: HookDispatcher Swallow Meta Test
; DESCRIPTION:
; Static source guard for the "dispatch-swallows-subscriber-errors" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_THS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_THS_Check() {
	Src := _THS_ReadSource("lib/hook_dispatcher.ahk")
	Assert(Src != "", "Source file must exist")
	Assert(InStr(Src, "catch as e") > 0, "HookDispatcher must catch subscriber exceptions")
	Assert(InStr(Src, 'LoggerWarn("HookDispatcher"') > 0, "HookDispatcher must log subscriber exceptions")
}

; Regression guard: the catch block must escalate to the global error handler so
; modifier-release logic (_ShouldReleaseModifier) runs when a subscriber throws
; during a Ctrl/Shift/Alt keydown. Before this fix the modifier stayed logically
; stuck after any subscriber exception, requiring a script restart.
_THS_CheckModifierRelease() {
	Src := _THS_ReadSource("lib/hook_dispatcher.ahk")
	Assert(InStr(Src, "ErgoptiGlobalErrorHandler(e") > 0,
		"HookDispatcher catch must call ErgoptiGlobalErrorHandler(e, ...) to release stuck modifiers")
}

Test("HookDispatcher: logs swallowed subscriber exceptions", _THS_Check)
Test("HookDispatcher: catch escalates to ErgoptiGlobalErrorHandler for modifier release", _THS_CheckModifierRelease)
