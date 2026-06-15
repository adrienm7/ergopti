; tests/meta/test_deadkey_timeout.ahk

#Requires AutoHotkey v2.0

_TDT_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TDT_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_TDT_AssertDeadKeyTimeout() {
	Src := _TDT_ReadSource("modules/layout.ahk")
	
	DeadKeyBody := _TDT_FuncBodyStripped(Src, "DeadKey(Mapping) {")
	
	TimeoutIdx := InStr(DeadKeyBody, '"L1 T2"')
	if !TimeoutIdx
		TimeoutIdx := InStr(DeadKeyBody, "'L1 T2'")
	Assert(TimeoutIdx > 0, "DeadKey InputHook must have a timeout (e.g. T2) (deadkey-inputhook-blocks-thread)")
	
	FinallyIdx := InStr(DeadKeyBody, "finally {")
	Assert(FinallyIdx > 0, "DeadKey must use a finally block to reset InDeadKeySequence (deadkey-inputhook-blocks-thread)")
}

Test("layout: DeadKey InputHook has a timeout and finally block (deadkey-inputhook-blocks-thread)", _TDT_AssertDeadKeyTimeout)
