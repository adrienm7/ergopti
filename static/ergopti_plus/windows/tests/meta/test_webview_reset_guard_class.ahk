; tests/meta/test_webview_reset_guard_class.ahk

; ==============================================================================
; MODULE: Regression — EVERY WebView2 teardown carries the double-close guard
;         (webview-reset-guard-class)
; DESCRIPTION:
; Companion to test_webview_reset_idempotent_siblings.ahk, whose sibling registry
; is a HARDCODED array of six host prefixes. The driver has ten WebView2 teardown
; functions; two of them (_LLM_MBW_Reset, _CLW_Reset) never received the F7
; ResetDone guard at all, and because they were not in that array the suite was
; green on both forever. That is the failure mode the repo names explicitly: an
; invariant applied to the sites a list happens to name rather than to the class.
;
; ROOT CAUSE ENCODED: the registry is DERIVED from driver source here — every
; "*_Reset" function whose body closes a WebView2 controller must carry the
; guard. An eleventh hand-rolled host cannot be omitted, because nobody has to
; remember to add it.
;
; WHY THE GUARD: each of these windows wires Close AND Escape to the same handler
; (the model browser adds a deferred model-apply as a third trigger), and
; Controller.Close() is a COM call that pumps messages. A second dispatch during
; that pump re-enters the teardown while the controller globals are still set and
; runs the release + Close sequence a second time against a controller that is
; already going away — the uncatchable SEH class documented at
; ui/personal_toml_editor_webview.ahk, where it was an observed production crash.
;
; SCOPE: source-level. The crash is a hard access violation and the headless
; harness has no live WebView2 runtime, so behaviour cannot be exercised.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ The host registry, derived from source ================
; ==================================================================
; ==================================================================

; Every "*_Reset" function in the driver whose body actually closes a WebView2
; controller. Comment lines are stripped by _DriverFuncBody, so the many
; explanatory "… Controller.Close() …" prose blocks cannot inflate this.
_WVRG_TeardownFunctions() {
	Src := _DriverSourceNoComments()
	Out := []
	Seen := Map()
	Pos := 1
	while (Pos := RegExMatch(Src, "m)^([A-Za-z0-9_]+_Reset)\(\)\s*\{", &M, Pos)) {
		Name := M[1]
		Pos += StrLen(M[0])
		if Seen.Has(Name)
			continue
		Seen[Name] := true
		Body := _DriverFuncBody(Name)
		if (Body == "" or InStr(Body, "Controller.Close()") == 0)
			continue
		Out.Push(Name)
	}
	return Out
}





; ==================================================================
; ==================================================================
; ======= 2/ Every teardown is idempotent ==========================
; ==================================================================
; ==================================================================

_WVRG_EveryTeardownIsGuarded() {
	Checked := 0
	for _, Fn in _WVRG_TeardownFunctions() {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must be resolvable in the driver source")

		Assert(RegExMatch(Body, "if\s+([A-Za-z0-9_]+ResetDone)", &Flag) > 0,
			Fn . " must open with a ResetDone guard: Close and Escape are wired to the same handler and Controller.Close() pumps messages, so a second dispatch re-enters this teardown and closes a controller that is already going away — an uncatchable access violation that kills the process with nothing in the log")
		FlagName := Flag[1]

		GuardPos := InStr(Body, "if " . FlagName)
		ReturnPos := InStr(Body, "return", , GuardPos)
		Assert(ReturnPos > GuardPos,
			Fn . " must RETURN on the guard — a guard that only reports still runs the teardown twice")

		Assert(InStr(Body, FlagName . " := true") > 0,
			Fn . " must latch " . FlagName . " := true once it proceeds past the guard, or a re-entrant call short-circuits nothing")
		LatchPos := InStr(Body, FlagName . " := true")

		; The subscription release is the exact ComCall the second pass hit in the
		; observed crash, so the guard has to precede it, not merely exist.
		UnsubPos := RegExMatch(Body, "[A-Za-z0-9_]+Sub\s*:=\s*unset")
		Assert(UnsubPos > 0, Fn . " must still release its subscription handle before closing the controller")
		Assert(GuardPos < UnsubPos and LatchPos < UnsubPos,
			Fn . " must check AND latch " . FlagName . " before touching the subscription globals — that release is the ComCall a second pass performs against an already-invalidated pointer")

		; A flag that is never re-armed turns the NEXT session's teardown into a
		; permanent no-op and leaks that session's controller, so the fix must not
		; trade one leak for another. Column 0 is the declaration; a re-arm lives
		; inside a function and is therefore indented.
		Assert(RegExMatch(_DriverSourceNoComments(), "m)^[ \t]+(global\s+)?" . FlagName . "\s*:=\s*false") > 0,
			FlagName . " must be re-armed to false where a fresh controller is wired up — otherwise a flag left set by the previous session makes the next session's teardown a no-op and leaks its WebView2 controller")

		Checked += 1
	}

	; A floor, not a tautology: the count comes from the source scan, so a host
	; that loses its Controller.Close() (or its definition) drops below it.
	Assert(Checked >= 10,
		"every WebView2 teardown must be covered by this invariant (found " . Checked . ") — the sibling test's hardcoded six-entry registry is precisely how two of them stayed unguarded and green")
}
Test("meta webview-reset-guard-class: every WebView2 teardown is idempotent",
	_WVRG_EveryTeardownIsGuarded)
