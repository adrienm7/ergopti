; tests/meta/test_metrics_focus_cache_atomic.ahk

#Requires AutoHotkey v2.0

_MFCA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_MFCA_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
	return Rest
}

_MFCA_AssertAtomicPublish() {
	Src := _MFCA_ReadSource("lib/metrics/metrics_filters.ahk")
	Body := _MFCA_FuncBodyStripped(Src, "MF_RefreshFocus() {")
	Assert(Body != "", "MF_RefreshFocus must exist in lib/metrics/metrics_filters.ahk")
	
	CritOnIdx := InStr(Body, 'Critical("On")')
	if !CritOnIdx
		CritOnIdx := InStr(Body, "Critical('On')")
	
	Assert(CritOnIdx > 0, "MF_RefreshFocus must wrap the cache assignment in Critical('On') (metrics-focus-cache-cross-thread-race)")
	
	CritOffIdx := InStr(Body, 'Critical("Off")')
	if !CritOffIdx
		CritOffIdx := InStr(Body, "Critical('Off')")
		
	Assert(CritOffIdx > CritOnIdx, "MF_RefreshFocus must wrap the cache assignment in Critical('Off') (metrics-focus-cache-cross-thread-race)")
}

Test("metrics_filters: MF_RefreshFocus updates cache atomically (metrics-focus-cache-cross-thread-race)", _MFCA_AssertAtomicPublish)
