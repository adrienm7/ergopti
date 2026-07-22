; tests/meta/test_logger_flush_on_error.ahk

; ==============================================================================
; MODULE: Logger Flush on Error Meta Test
; DESCRIPTION:
; Regression guard ensuring _LoggerEmit's synchronous force-flush is guarded by
; exactly LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["ERROR"], the current,
; intentional product decision (commit b0c3f4a90). Scoped to the precise
; if-block wrapping the _LoggerFlush(true) call site inside _LoggerEmit's
; function body — not a whole-directory substring search — so it cannot be
; satisfied by an unrelated LOGGER_SEVERITY["WARNING"] comparison elsewhere in
; the same function (the WARNING gate at line ~530 only pushes onto
; _LOGGER_PENDING_ERRORS, it does not flush).
;
; SCOPE: source introspection of lib/logger.ahk, scoped to _LoggerEmit's body.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_LFOE_CheckErrorThreshold() {
	Body := _DriverFuncBody("_LoggerEmit")
	Assert(Body != "", "_LoggerEmit must exist in lib/logger.ahk")

	; [^}]* between the guard's "{" and "_LoggerFlush(true)" requires the flush
	; call to be inside THIS specific if-block with no intervening "}" — so the
	; earlier, unrelated 'LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["WARNING"]'
	; gate (which only pushes to _LOGGER_PENDING_ERRORS, never flushes) cannot
	; satisfy this match, unlike a naive whole-file InStr search.
	Found := RegExMatch(Body,
		'LOGGER_SEVERITY\[Level\]\s*>=\s*LOGGER_SEVERITY\["(\w+)"\]\s*\{[^}]*_LoggerFlush\(true\)',
		&m)
	Assert(Found,
		'_LoggerEmit must guard its synchronous _LoggerFlush(true) call with a LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["..."] comparison directly wrapping the call')

	Assert(m[1] == "ERROR",
		Format('_LoggerEmit`'s force-flush guard must compare against LOGGER_SEVERITY["ERROR"] (current intentional behavior, commit b0c3f4a90); found LOGGER_SEVERITY["{1}"] instead — if this threshold changed on purpose, update this test to match', m[1]))
}


Test('meta logger: force-flush guard scoped to _LoggerEmit compares against LOGGER_SEVERITY["ERROR"] exactly',
	_LFOE_CheckErrorThreshold)
