; tests/meta/test_sendinstant_deferred_clipboard.ahk

#Requires AutoHotkey v2.0

_SDC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_SDC_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_SDC_AssertDeferredRestore() {
	Src := _SDC_ReadSource("lib/hotstrings/hotstring_engine.ahk")
	
	Body := _SDC_FuncBodyStripped(Src, "SendInstant(Text) {")
	
	SleepIdx := InStr(Body, "Sleep(")
	Assert(!SleepIdx, "SendInstant must NOT call Sleep() inline (wraptext-sendinstant-sleep-hotpath)")
	
	SetTimerIdx := InStr(Body, "SetTimer(")
	Assert(SetTimerIdx > 0, "SendInstant must use SetTimer to defer clipboard restore (wraptext-sendinstant-sleep-hotpath)")
}

Test("hotstring_engine: SendInstant defers clipboard restore (wraptext-sendinstant-sleep-hotpath)", _SDC_AssertDeferredRestore)
