; tests/meta/test_klpf_writeatomic_delete_window.ahk

; ==============================================================================
; MODULE: KLPF_WriteAtomic Delete-Window Meta Test
; DESCRIPTION:
; Static source guard for the klpf-writeatomic-delete-window finding.
;
; KLPF_WriteAtomic used to write to a .tmp sibling and then publish it via
; FileDelete(path) + FileMove(tmp, path). That sequence leaves a window in
; which ``path`` does not exist: a dashboard fetch('./prefetch.json') landing
; between the delete and the move sees a 404, and an AV/indexer transiently
; holding the freshly-deleted name makes FileMove fail with no retry — leaving
; the page on stale data. KL_WriteAtomic (keylogger.ahk) already solved exactly
; this with MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) +
; one retry: a kernel-level directory-entry swap with no absent-file window.
;
; The fix makes KLPF_WriteAtomic delegate to that shared primitive. This test
; asserts the delete-then-move antipattern is gone from the function body and
; that the function now routes through KL_WriteAtomic.
;
; Meta-static because keylogger_prefetch.ahk depends on COM/SQLite and is part
; of a module graph the headless runner does not load; scanning the source text
; is the load-safe way to lock in the fix.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_KWDW_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Atomic-rename assertions ==============
; ==================================================
; ==================================================

; The function must no longer delete the destination before moving onto it.
_KWDW_NoDeleteThenMove() {
	Src := _KWDW_ReadSource("modules/keylogger/keylogger_prefetch.ahk")
	Seg := _DriverFuncBody("KLPF_WriteAtomic")
	Assert(Seg != "", "KLPF_WriteAtomic(path, content) declaration must exist in keylogger_prefetch.ahk")
	; The destination publish must be a true atomic swap, never FileDelete(path)
	; followed by a FileMove onto it — that gap is the absent-file window.
	Assert(InStr(Seg, "FileMove") = 0,
		"KLPF_WriteAtomic must not use FileMove to publish the destination — it leaves an absent-file window; use the MoveFileExW atomic-swap primitive instead")
	Assert(InStr(Seg, "FileDelete(path)") = 0,
		"KLPF_WriteAtomic must not FileDelete(path) before publishing — that gap lets a dashboard fetch see a 404")
}
Test("keylogger: KLPF_WriteAtomic has no delete-then-move window (klpf-writeatomic-delete-window)", _KWDW_NoDeleteThenMove)

; The writer may delegate the syscall to a narrow helper, but its publish path
; must still end in MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH), never FileMove.
_KWDW_UsesAtomicSwap() {
	WriterBody := _DriverFuncBody("KLPF_WriteAtomic")
	MoveBody := _DriverFuncBody("KLPF_MoveAtomic")
	Assert(WriterBody != "", "KLPF_WriteAtomic(path, content) declaration must exist in keylogger_prefetch.ahk")
	Assert(MoveBody != "", "KLPF_MoveAtomic(source, destination, flags) declaration must exist in keylogger_prefetch.ahk")
	Assert(InStr(WriterBody, "KLPF_MoveAtomic(tmp, path, FLAGS)") > 0,
		"KLPF_WriteAtomic must publish through KLPF_MoveAtomic, never a non-atomic fallback")
	Assert(InStr(MoveBody, "MoveFileExW") > 0,
		"KLPF_MoveAtomic must publish the destination with MoveFileExW — the documented atomic directory-entry swap with no absent-file window")
	Assert(InStr(MoveBody, "MOVEFILE_REPLACE_EXISTING") > 0,
		"KLPF_MoveAtomic must pass MOVEFILE_REPLACE_EXISTING so the rename atomically replaces the existing prefetch file")
}
Test("keylogger: KLPF_WriteAtomic publishes via MoveFileExW atomic swap (klpf-writeatomic-delete-window)", _KWDW_UsesAtomicSwap)
