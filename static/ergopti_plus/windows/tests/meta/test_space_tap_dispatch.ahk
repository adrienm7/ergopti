; tests/meta/test_space_tap_dispatch.ahk

#Requires AutoHotkey v2.0

_ST_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_ST_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_ST_AssertSpaceTapAtomic() {
	Src := _ST_ReadSource("modules/tap_holds/space.ahk")
	Body := _ST_FuncBodyStripped(Src, "_SpaceTap() {")
	Assert(Body != "", "_SpaceTap must exist in modules/tap_holds/space.ahk")
	
	CritOnIdx := InStr(Body, 'Critical("On")')
	if !CritOnIdx
		CritOnIdx := InStr(Body, 'Critical("On")')
	
	Assert(CritOnIdx > 0, "_SpaceTap must use Critical('On') to prevent mid-dispatch races (space-tap-dispatch-not-critical)")
	
	DispatchIdx := InStr(Body, "HSE_DispatchMatch")
	PressIdx := InStr(Body, 'TextPressKey("Space"')
	
	Assert(PressIdx > DispatchIdx, "Literal space emission must occur AFTER the expansion decision, so it isn't sent if a match fires (space-tap-dispatch-not-critical)")
}

Test("tap_holds: _SpaceTap uses Critical('On') and correct emission order (space-tap-dispatch-not-critical)", _ST_AssertSpaceTapAtomic)
