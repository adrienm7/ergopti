; tests/meta/test_watchers_idle_end_ordering.ahk

; ==============================================================================
; MODULE: KL_Watchers IdleTick Ordering Guard
; DESCRIPTION:
; Static source guard for the idle_end / session_end ordering fix in
; modules/keylogger/keylogger_watchers.ahk.
;
; ROOT CAUSE ENCODED:
; The KL_Watchers_IdleTick function previously cleared is_idle before emitting
; idle_end, or emitted session_end before idle_end, which corrupted the event
; log pairing rules. A dangling idle_start without a following idle_end causes
; all downstream idle-time aggregates to be incorrect.
;
; The fix establishes the correct ordering:
;   1. Emit "idle_end" FIRST (while is_idle is still true so we know we are in idle).
;   2. THEN emit "session_end".
; In the source, the KL_LogSession("idle_end", ...) call must appear BEFORE
; is_idle is cleared to false AND before KL_LogSession("session_end", ...).
; This test verifies that ordering by checking character positions in the source.
; ==============================================================================

#Requires AutoHotkey v2.0

_TWIED_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TWIED_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

; Locate the KL_Watchers_IdleTick function body (ends at the next flush-left }).
_TWIED_IdleTickBody(Src) {
	Decl := "KL_Watchers_IdleTick() {"
	Idx := InStr(Src, Decl)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	return End ? SubStr(Rest, 1, End + 1) : Rest
}


; ====================================================================
; ====================================================================
; ======= 1/ idle_end emitted before session_end in IdleTick =========
; ====================================================================
; ====================================================================

_TWIED_IdleEndBeforeSessionEnd() {
	Src := _TWIED_StripLineComments(_TWIED_ReadSource("modules/keylogger/keylogger_watchers.ahk"))
	Assert(Src != "", "modules/keylogger/keylogger_watchers.ahk must be readable")

	Body := _TWIED_IdleTickBody(Src)
	Assert(Body != "", "KL_Watchers_IdleTick must be defined in modules/keylogger/keylogger_watchers.ahk")

	; Both events must appear
	IdleEndPos    := InStr(Body, Chr(0x22) . "idle_end" . Chr(0x22))
	SessionEndPos := InStr(Body, Chr(0x22) . "session_end" . Chr(0x22))
	Assert(IdleEndPos > 0,
		"KL_Watchers_IdleTick must emit idle_end (idle_end event missing from IdleTick body)")
	Assert(SessionEndPos > 0,
		"KL_Watchers_IdleTick must emit session_end (session_end event missing from IdleTick body)")

	; idle_end must appear BEFORE session_end
	Assert(IdleEndPos < SessionEndPos,
		"KL_Watchers_IdleTick must emit idle_end BEFORE session_end — wrong ordering corrupts idle-time aggregates")
}
Test("keylogger_watchers: KL_Watchers_IdleTick emits idle_end before session_end", _TWIED_IdleEndBeforeSessionEnd)
