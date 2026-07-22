; tests/meta/test_dispatcher_start_ungated.ahk

; ==============================================================================
; MODULE: HookDispatcher Unconditional Start Meta Test
; DESCRIPTION:
; Static source guard for HIGH-02: fix-hookdispatcher-start-ungated.
;
; HookDispatcher.Start() used to be the sole production call site and was
; nested inside `if MetricsShortcuts.enabled {` in ErgoptiPlus.ahk. Because
; MetricsShortcuts.enabled defaults to false, the mouse Hotkeys owned by
; HookDispatcher (~LButton / ~RButton / ~MButton / Wheel*) were never registered
; on a default install. Four independent features that subscribe unconditionally
; to those events were therefore silently dead:
;   1. Hotstring prefix-watcher click-reset (_InstallMouseClickResetHooks)
;   2. CapsWord mouse-click cancel (capsword.ahk:46)
;   3. Gesture click-toggle cross-release (gestures.ahk:1602/1691)
;   4. LLM tooltip dismiss-on-click (llm_bridge.ahk:427)
;
; The fix moves HookDispatcher.Start() to before the `if MetricsShortcuts.enabled`
; block so it runs unconditionally on every boot. Start() is already idempotent.
;
; This test reads ErgoptiPlus.ahk and asserts:
;   (a) HookDispatcher.Start() appears in the file.
;   (b) HookDispatcher.Start() does NOT appear inside the
;       `if MetricsShortcuts.enabled {` ... `}` brace span.
;
; Meta-static because Start() registers real OS Hotkeys and is unsafe to invoke
; in the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file.
_DSU_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the 1-based line index of the first occurrence of Needle in Lines array,
; or 0 when not found.
_DSU_FindLine(Lines, Needle) {
	for i, line in Lines {
		if InStr(line, Needle)
			return i
	}
	return 0
}

; Returns the index of the closing brace `}` that matches the open-brace at
; OpenLine (1-based).  Walks forward counting nesting depth.  Returns 0 if not
; found within the slice.
_DSU_FindMatchingClose(Lines, OpenLine) {
	depth := 0
	Loop Lines.Length - OpenLine + 1 {
		i := OpenLine + A_Index - 1
		line := Lines[i]
		; Count opening and closing braces — trim strings and comments for accuracy.
		stripped := RegExReplace(line, ";.*$", "")
		depth += StrLen(RegExReplace(stripped, "[^{]", "")) - StrLen(RegExReplace(stripped, "[^}]", ""))
		if (depth <= 0)
			return i
	}
	return 0
}


; ========================================================
; ========================================================
; ======= 2/ Test implementations ========================
; ========================================================
; ========================================================

_DSU_CheckStartUngated() {
	Body := _DriverSourceConcat()
	Assert(Body != "", "ErgoptiPlus.ahk must be readable")

	; (a) HookDispatcher.Start() must exist somewhere in the file.
	Assert(InStr(Body, "HookDispatcher.Start()"),
		"HookDispatcher.Start() must be present in ErgoptiPlus.ahk")

	; (b) HookDispatcher.Start() must NOT appear inside the MetricsShortcuts gate.
	; Split into lines and find the brace span of `if MetricsShortcuts.enabled {`.
	Lines := StrSplit(Body, "`n")

	GateLine := _DSU_FindLine(Lines, "if MetricsShortcuts.enabled {")
	Assert(GateLine > 0,
		'Could not locate "if MetricsShortcuts.enabled {" in ErgoptiPlus.ahk — update this test if the condition was renamed')

	CloseGateLine := _DSU_FindMatchingClose(Lines, GateLine)
	Assert(CloseGateLine > GateLine,
		'Could not find the closing brace of "if MetricsShortcuts.enabled {"')

	; Scan the gated span for HookDispatcher.Start().
	FoundInsideGate := false
	Loop CloseGateLine - GateLine + 1 {
		i := GateLine + A_Index - 1
		if InStr(Lines[i], "HookDispatcher.Start()") {
			FoundInsideGate := true
			break
		}
	}
	Assert(!FoundInsideGate,
		'HookDispatcher.Start() must NOT be inside "if MetricsShortcuts.enabled {" — it must run unconditionally (HIGH-02 fix-hookdispatcher-start-ungated)')

	; (c) HookDispatcher.Start() must appear BEFORE the gate (not after, which
	;     would still be outside but in a less predictable location).
	StartLine := _DSU_FindLine(Lines, "HookDispatcher.Start()")
	Assert(StartLine > 0 && StartLine < GateLine,
		'HookDispatcher.Start() must appear before the "if MetricsShortcuts.enabled {" block in ErgoptiPlus.ahk')
}


Test("meta fix-hookdispatcher-start-ungated: HookDispatcher.Start() runs unconditionally before MetricsShortcuts gate",
	_DSU_CheckStartUngated)
