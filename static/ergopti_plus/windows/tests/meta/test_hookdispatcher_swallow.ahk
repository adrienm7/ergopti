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

Test("HookDispatcher: logs swallowed subscriber exceptions", _THS_Check)
