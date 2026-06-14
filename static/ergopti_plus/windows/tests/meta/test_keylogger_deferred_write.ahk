; tests/meta/test_keylogger_deferred_write.ahk

#Requires AutoHotkey v2.0

_KDW_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_KDW_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
	return Rest
}

_KDW_AssertDeferredWrite() {
	Src := _KDW_ReadSource("modules/keylogger/keylogger.ahk")
	
	AppendBody := _KDW_FuncBodyStripped(Src, "KL_AppendLog(entry) {")
	
	InlineWriteIdx := InStr(AppendBody, "fh.Write(")
	Assert(!InlineWriteIdx, "KL_AppendLog must NOT call fh.Write() inline (kl-synchronous-disk-write-on-keystroke)")
	
	IngestBody := _KDW_FuncBodyStripped(Src, "KL_IngestOnce() {")
	
	DeferredWriteIdx := InStr(IngestBody, "fh.Write(")
	Assert(DeferredWriteIdx > 0, "KL_IngestOnce must write pending_snapshot to disk (kl-synchronous-disk-write-on-keystroke)")
}

Test("keylogger: Keystroke log writes are deferred off the hot path (kl-synchronous-disk-write-on-keystroke)", _KDW_AssertDeferredWrite)
