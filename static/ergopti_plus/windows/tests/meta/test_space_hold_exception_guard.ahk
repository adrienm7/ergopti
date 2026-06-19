; tests/meta/test_space_hold_exception_guard.ahk

#Requires AutoHotkey v2.0

_SHEG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_SHEG_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_SHEG_AssertSpaceHoldTryGuard() {
	Src := _SHEG_ReadSource("modules/tap_holds/space.ahk")
	
	Funcs := ["_SpaceHoldCtrl", "_SpaceHoldShift", "_SpaceHoldAlt", "_SpaceHoldAltGr", "_SpaceHoldWin"]
	for _, fn in Funcs {
		Body := _SHEG_FuncBodyStripped(Src, fn . "(captured) {")
		Assert(Body != "", fn . " must exist in space.ahk")
		
		; We assert that there's a try block protecting the SendInput of the captured char
		Assert(RegExMatch(Body, "try\s*\{[\s\S]*try\s+SendInput") > 0, fn . " must protect SendInput(captured) with an inner try block to avoid unhandled target exceptions (space-hold-exception-guard)")
		
		; We assert that RegExReplace is used to escape characters
		Assert(InStr(Body, 'RegExReplace(captured, "([!#^+{}])", "{$1}")') > 0, fn . " must escape characters for SendInput to prevent unexpected AHK v2 parsing errors (space-hold-exception-guard)")
	}
}

Test("tap_holds: space hold functions guard dynamic SendInput against unhandled exceptions (space-hold-exception-guard)", _SHEG_AssertSpaceHoldTryGuard)
