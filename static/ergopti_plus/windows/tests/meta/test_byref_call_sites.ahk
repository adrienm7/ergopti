; tests/meta/test_byref_call_sites.ahk

; ==============================================================================
; MODULE: ByRef Call-Site Ampersand Meta Test
; DESCRIPTION:
; AHK v2 requires the address-of operator at the CALL SITE for every parameter a
; function declares ByRef. Passing a bare variable to a `&`-declared parameter
; does not silently bind it — it raises
; "TypeError: This parameter requires a variable reference" at RUNTIME, when the
; call is finally reached, which is why such a mismatch survives boot and the
; whole test suite.
;
; The defect that motivated this guard: _GlobalClearAllBindings was declared
; `(&Updates)` while its single call site passed `Updates`, so every use of the
; tray's "tout desactiver" threw. The global error net logged it, showed a toast
; and returned true, leaving Features/CategoryEnabled/WPMWidget flipped to false
; in memory while the TOML write and Reload never ran — and a later unrelated
; menu toggle then canonicalised that half-state onto disk.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE (a definition/call-site ByRef mismatch), not the one
;    function it was found in — per project-ahk-guard-tests-must-loop-the-class.
;    Any future ByRef signature whose callers were not updated fails here.
; 2. Scans the concatenated driver source with the move-resilient helper, so it
;    keeps working when files are renamed or moved.
; 3. Deliberately conservative: it only judges a call-site argument when that
;    argument actually exists, so optional trailing ByRef out-parameters
;    (the common `&OutX` idiom) are never falsely flagged.
;
; SCOPE: source introspection of the whole driver.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Trim whitespace INCLUDING line breaks. AHK v2's Trim() omits only spaces and
; tabs by default, so an argument in a call spread over several lines keeps its
; leading newline — and a bare SubStr(.., 1, 1) == "&" test then reports a
; correctly-written `&out` call site as a violation. That false positive is
; exactly what this helper exists to prevent.
_BRC_Trim(Value) {
	return Trim(Value, " `t`r`n")
}

; Split a call's argument list on top-level commas only. Parentheses, brackets,
; braces and quoted strings all nest, so a naive StrSplit(",") would mis-align
; the argument positions this test depends on.
_BRC_SplitArgs(ArgStr) {
	Args := []
	Depth := 0
	Quote := ""
	Cur := ""
	Loop Parse, ArgStr {
		ch := A_LoopField
		if (Quote != "") {
			Cur .= ch
			if (ch == Quote)
				Quote := ""
			continue
		}
		if (ch == '"' or ch == "'") {
			Quote := ch
			Cur .= ch
			continue
		}
		if (ch == "(" or ch == "[" or ch == "{") {
			Depth += 1
			Cur .= ch
			continue
		}
		if (ch == ")" or ch == "]" or ch == "}") {
			Depth -= 1
			Cur .= ch
			continue
		}
		if (ch == "," and Depth == 0) {
			Args.Push(Cur)
			Cur := ""
			continue
		}
		Cur .= ch
	}
	if (_BRC_Trim(Cur) != "" or Args.Length > 0)
		Args.Push(Cur)
	return Args
}

; Return the substring inside the parentheses that open at OpenPos, tracking
; nesting and quotes so a ")" inside a string or a nested call does not close
; the list early. Returns "" when the parentheses are unbalanced.
_BRC_ExtractArgList(Src, OpenPos) {
	Depth := 0
	Quote := ""
	Len := StrLen(Src)
	i := OpenPos
	Start := OpenPos + 1
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (Quote != "") {
			if (ch == Quote)
				Quote := ""
		} else if (ch == '"' or ch == "'") {
			Quote := ch
		} else if (ch == "(") {
			Depth += 1
		} else if (ch == ")") {
			Depth -= 1
			if (Depth == 0)
				return SubStr(Src, Start, i - Start)
		} else if (ch == "`n" and Depth == 0) {
			return ""
		}
		i += 1
	}
	return ""
}

; Map every driver function that declares at least one ByRef parameter to the
; 1-based positions of those parameters.
_BRC_ByRefDefinitions(Src) {
	Defs := Map()
	Pos := 1
	while (Pos := RegExMatch(Src, "m)^[ \t]*([A-Za-z_][A-Za-z0-9_]*)\(([^)\r\n]*)\)[ \t]*\{", &m, Pos)) {
		Name := m[1]
		Params := _BRC_SplitArgs(m[2])
		Positions := []
		for Idx, P in Params {
			if (SubStr(_BRC_Trim(P), 1, 1) == "&")
				Positions.Push(Idx)
		}
		if (Positions.Length > 0)
			Defs[Name] := Positions
		Pos += StrLen(m[0])
	}
	return Defs
}





; ===========================================
; ===========================================
; ======= 2/ The class-wide assertion =======
; ===========================================
; ===========================================

_BRC_ByRefCallSitesPassAmpersand() {
	Src := _DriverSourceNoComments()
	Defs := _BRC_ByRefDefinitions(Src)
	Assert(Defs.Count > 0,
		"the ByRef scan must find at least one &-declared parameter, otherwise the guard is vacuous")

	Violations := _BRC_FindViolations(Src, Defs)
	Assert(Violations.Length == 0,
		"every call site of a ByRef parameter must pass it with & — AHK v2 raises TypeError at runtime otherwise, which survives boot and the whole suite. Offenders: "
		. _BRC_Join(Violations))
}

_BRC_FindViolations(Src, Defs, FindNext := RegExMatch) {
	Violations := []
	; Keep the previous scanner's case-sensitive symbol matching without scanning
	; the entire source again for every definition. Only small position lists are
	; indexed; no additional source snapshots or per-call text cache is retained.
	Names := Map()
	Names.CaseSense := "On"
	for Name, Positions in Defs
		Names[Name] := Positions
	Pos := 1
	Pattern := "([^A-Za-z0-9_.$@#]|^)([A-Za-z_][A-Za-z0-9_]*)\("
	while (Pos := FindNext.Call(Src, Pattern, &m, Pos)) {
		Name := m[2]
		OpenPos := Pos + StrLen(m[0]) - 1
		; Retain the opening parenthesis as the prefix of an immediate nested call.
		Pos := OpenPos
		if !Names.Has(Name)
			continue
		Positions := Names[Name]
		; Skip the DEFINITION itself: only a definition is followed by ") {".
		Tail := SubStr(Src, OpenPos, 400)
		IsDef := RegExMatch(Tail, "^\([^)\r\n]*\)[ \t]*\{") > 0
		if (!IsDef) {
			ArgStr := _BRC_ExtractArgList(Src, OpenPos)
			if (ArgStr != "") {
				Args := _BRC_SplitArgs(ArgStr)
				for P in Positions {
					; Only judge an argument that is actually supplied —
					; optional trailing &Out parameters are routinely omitted.
					if (P <= Args.Length and _BRC_Trim(Args[P]) != ""
						and SubStr(_BRC_Trim(Args[P]), 1, 1) != "&") {
						Violations.Push(Name . "() argument #" . P
							. " is declared ByRef but this call passes it by value: "
							. _BRC_Trim(StrReplace(m[0], "`n", " ")) . _BRC_Trim(ArgStr))
					}
				}
			}
		}
	}

	return Violations
}

; Joined on a single line: the TAP reporter truncates a failure message at its
; first newline, so a multi-line offender list would render as an empty one.
_BRC_Join(Items) {
	Out := ""
	for Item in Items
		Out .= (Out == "" ? "" : "  ||  ") . Item
	return Out
}


Test("meta byref: every ByRef parameter is passed with & at every call site",
	_BRC_ByRefCallSitesPassAmpersand)

_BRC_TraceMatch(State, Src, Pattern, &Match, Position) {
	State.Positions.Push(Position)
	return RegExMatch(Src, Pattern, &Match, Position)
}

_BRC_TraversalDoesNotRestart() {
	Src := 'Alpha(&Out) {`n}`nBeta(Value, &Out := unset) {`n}`n'
		. 'Alpha(value)`nBeta(1, &out)`nBeta(1)`nAlpha(Beta(2, wrong))`n'
		. 'obj.Alpha(value)`nLongAlpha(value)`nalpha(value)`n'
	State := { Positions: [] }
	Violations := _BRC_FindViolations(Src, _BRC_ByRefDefinitions(Src),
		_BRC_TraceMatch.Bind(State))
	AssertEqual(3, Violations.Length,
		"both nested offenses survive while optional arguments and unrelated methods stay excluded")
	Reason := " is declared ByRef but this call passes it by value: "
	AssertEqual("Alpha() argument #1" . Reason . "Alpha(value", Violations[1])
	AssertEqual("Alpha() argument #1" . Reason . "Alpha(Beta(2, wrong)", Violations[2])
	AssertEqual("Beta() argument #2" . Reason . "(Beta(2, wrong", Violations[3])
	AssertTrue(State.Positions.Length > 1, "the real regex must inspect the fixture")
	Previous := 0
	for Position in State.Positions {
		AssertTrue(Position > Previous,
			"the source cursor must advance once, not restart for every ByRef symbol")
		Previous := Position
	}
}
Test("meta byref: source traversal never restarts per symbol (byref-scan-source-once)",
	_BRC_TraversalDoesNotRestart)
