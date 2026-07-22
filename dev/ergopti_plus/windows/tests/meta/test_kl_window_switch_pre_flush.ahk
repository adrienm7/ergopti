; tests/meta/test_kl_window_switch_pre_flush.ahk

; ==============================================================================
; MODULE: Keylogger Window Switch Pre-Flush Order Meta Test
; DESCRIPTION:
; Static source guard for finding T-W09.
;
; KL_Hook_RefreshContext() handles two distinct change events: an app switch
; (NewApp != prev_app) and a title-only change (NewTitle != prev_title) that
; occurs without an app switch, e.g. switching tabs inside a browser. In the
; title-change branch, KL_FlushBuffer() MUST be called BEFORE
; KL_LogWindowSwitch() so that the typing buffer is attributed to the previous
; window context rather than the incoming one.
;
; Without this ordering the chars typed in the old tab are written into the new
; tab's context record, corrupting per-window metrics. The app-switch branch
; already enforces this ordering (M-01 fix); this guard ensures the title-only
; branch obeys the same invariant and that the two calls are never accidentally
; swapped during a future refactor.
;
; ROOT CAUSE ENCODED: The byte offset of "KL_FlushBuffer" must be strictly less
; than the byte offset of "KL_LogWindowSwitch" inside the title-change section
; of KL_Hook_RefreshContext. Any swap makes the test fail immediately.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================
; ================================================
; ======= 1/ Source scan helpers =================
; ================================================
; ================================================

_KLWSP_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Extracts the title-change block — the if-block that starts with
; `if (NewTitle != KLHook.prev_title)` — from an already-extracted
; function body. Returns "" when the sentinel line is absent.
_KLWSP_TitleChangeBlock(FuncBody) {
	Sentinel := "if (NewTitle != KLHook.prev_title)"
	Idx := InStr(FuncBody, Sentinel)
	if !Idx
		return ""
	; Return from the sentinel to the end of the function body; that
	; encompasses the entire title-change if-block and is sufficient for
	; the ordering assertions below.
	return SubStr(FuncBody, Idx)
}




; ================================================
; ================================================
; ======= 2/ Ordering assertion ==================
; ================================================
; ================================================

_KLWSP_FlushBeforeWindowSwitch() {
	Src := _KLWSP_ReadSource("modules/keylogger/keylogger_hook.ahk")

	FuncBody := _DriverFuncBody("KL_Hook_RefreshContext")
	Assert(FuncBody != "",
		"KL_Hook_RefreshContext must exist in keylogger_hook.ahk")

	TitleBlock := _KLWSP_TitleChangeBlock(FuncBody)
	Assert(TitleBlock != "",
		"KL_Hook_RefreshContext must contain the title-change branch "
		. "'if (NewTitle != KLHook.prev_title)' — sentinel line not found")

	FlushPos  := InStr(TitleBlock, "KL_FlushBuffer(")
	SwitchPos := InStr(TitleBlock, "KL_LogWindowSwitch(")

	Assert(FlushPos > 0,
		"KL_Hook_RefreshContext title-change block must call KL_FlushBuffer() "
		. "to drain the typing buffer before attributing it to the new window context")

	Assert(SwitchPos > 0,
		"KL_Hook_RefreshContext title-change block must call KL_LogWindowSwitch() "
		. "to record the context transition")

	Assert(FlushPos < SwitchPos,
		"KL_Hook_RefreshContext: KL_FlushBuffer() must appear BEFORE "
		. "KL_LogWindowSwitch() in the title-change branch so that buffered "
		. "keystrokes are attributed to the previous window, not the new one "
		. "(found FlushBuffer at offset " . FlushPos . ", LogWindowSwitch at offset "
		. SwitchPos . " within the title-change section)")
}

Test("keylogger_hook: KL_FlushBuffer called before KL_LogWindowSwitch on title change",
	_KLWSP_FlushBeforeWindowSwitch)
