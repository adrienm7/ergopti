; tests/meta/test_spotlight_gdiplus_leak.ahk

; ==============================================================================
; MODULE: Spotlight GDI+ Leak Meta Test
; DESCRIPTION:
; Static source guard for the "spotlight-gdiplus-token-leak-on-error" finding.
; SpotlightMouseAt must wrap its window creation in a try/catch block to ensure
; the GDI+ token and handles are not leaked if an error is thrown.
; ==============================================================================

#Requires AutoHotkey v2.0

_SGL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_SGL_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_SGL_SpotlightHasTryCatch() {
	Src := _SGL_ReadSource("ui/spotlight.ahk")
	Seg := _DriverFuncBody("SpotlightMouseAt")
	Assert(Seg != "", "SpotlightMouseAt declaration must exist")
	
	Assert(InStr(Seg, "try {") > 0,
		"SpotlightMouseAt must wrap window creation in a try block (spotlight-gdiplus-token-leak-on-error)")
		
	Assert(InStr(Seg, "catch as Err {") > 0,
		"SpotlightMouseAt must catch errors to cleanup GDI+ token")
		
	Assert(InStr(Seg, "GdiplusShutdown") > 0,
		"SpotlightMouseAt must call GdiplusShutdown in the catch block")
}
Test("spotlight: SpotlightMouseAt has try/catch to prevent GDI+ token leak", _SGL_SpotlightHasTryCatch)
