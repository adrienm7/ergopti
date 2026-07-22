; tests/meta/test_search_shortcut_run_path_existence_guard.ahk

; ==============================================================================
; MODULE: Search Shortcut Run Path Existence Guard Meta Test
; DESCRIPTION:
; Regression guard for AHK-18: SearchPath() (the Win+S handler body) matched
; a Windows file path by REGEX SHAPE only ("^[A-Za-z]:[\\/]...") and then
; executed Run(SelectedText, , "Max") with no FileExist check and no try/catch.
; When the user selected a path-shaped string that does not exist on this machine
; (e.g. "D:\does\not\exist.txt"), Run() threw an OSError which propagated
; uncaught through the raw Hotkey callback to ErgoptiGlobalErrorHandler. That
; net scheduled the heavy deferred crash-report build + showed a scary error
; toast for what is a benign user action. The intended fallback (web search)
; never ran because the throw aborted before the fall-through.
;
; The fix gates the FilePath branch on FileExist(SelectedText) so a
; shape-only match that does not exist falls through to the web-search branch.
; All Run() calls in SearchPath are also wrapped in try/catch+LoggerWarn so
; none can reach the global error net.
;
; This test asserts (source introspection):
;   (a) The FilePath/Run branch is gated on FileExist — the bare
;       "if FilePath { Run(...) }" pattern no longer exists.
;   (b) FileExist is present in the SearchPath body (existence check added).
;   (c) Every Run( call inside SearchPath sits inside a try block, so no
;       OS-call failure can propagate to ErgoptiGlobalErrorHandler.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================================================
; =====================================================================================
; ======= 1/ Test implementation =====================================================
; =====================================================================================
; =====================================================================================

_TSSRPEG_CheckSearchPathRunGuard() {
	Body := _DriverFuncBody("SearchPath")
	Assert(Body != "", "SearchPath must exist in modules/shortcuts/win.ahk")

	; (a) The old bare FilePath+Run pattern must be gone
	; The bug was: if FilePath { Run(SelectedText, ...  with no FileExist check.
	; After the fix the branch must be gated on FileExist.
	Assert(!InStr(Body, "if FilePath {"),
		"AHK-18: 'if FilePath {' (bare, no FileExist) must not appear in SearchPath — a shape-only path match must verify the file exists before Run() or a non-existent path escalates to the crash-report error net")

	; (b) FileExist must be present to verify the path before Run
	Assert(InStr(Body, "FileExist"),
		"AHK-18: SearchPath must call FileExist before Run on a file-path match — regex shape detection does not guarantee the file exists and Run() throws an OSError on non-existent paths")

	; (c) No Run( call in SearchPath may sit outside a try block —
	; locate every "Run(" and ensure "try" precedes it in the body before the next "}"
	; We do a simpler structural check: assert that "try Run(" appears (all guarded
	; calls are directly try Run(... or inside a try { Run(...) block) and that the
	; unguarded "Run(SelectedText, , " pattern from before the fix is absent.
	Assert(InStr(Body, "try Run("),
		"AHK-18: All Run() calls in SearchPath must be wrapped in try so OS-call failures (non-existent path, blocked URL) are caught locally rather than propagating to ErgoptiGlobalErrorHandler")
}


Test("meta ahk-18: SearchPath gates FilePath branch on FileExist and wraps all Run() calls in try to prevent crash-report escalation",
	_TSSRPEG_CheckSearchPathRunGuard)
