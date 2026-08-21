; tests/meta/test_hotif_globals_boot_safe.ahk

; ==============================================================================
; MODULE: Regression — nothing reachable from a parse-time #HotIf may read an
;         unset global (hotif-globals-boot-safe)
; DESCRIPTION:
; Compiled .exe, first launch, no extracted bundle yet. Press Tab during
; Bundle_Init's RunWait extraction and the driver never finishes booting.
;
; ROOT CAUSE ENCODED: #HotIf criteria are armed at PARSE time — every one of
; them is live before a single line of the auto-execute section has run. The
; extraction shells out through RunWait, and RunWait PUMPS MESSAGES, so any key
; pressed during those ~250 ms is dispatched through hotkey resolution and
; evaluates whichever #HotIf expressions apply. Whatever those expressions call
; therefore runs in a driver where almost nothing is initialised yet. A bare
; read of a module global there raises UnsetError inside the #HotIf evaluator,
; _DriverBootPhase is still "starting", and the error net treats that as a fatal
; boot fault.
;
; This crash shape has now been shipped twice: once through Features
; (crash_reports/2026-07-19, fixed for Features derefs only) and once through
; the LLM tooltip trio, whose sibling LLM_TooltipIsVisible was guarded while
; LLM_TooltipGetText — the one the Tab #HotIf actually calls — was not. Guarding
; the reported symbol again would leave the class open a third time, so this
; test walks EVERY parse-time #HotIf, resolves the driver functions it calls,
; and requires each module global those functions dereference to be either
; seeded in the pre-pump block or IsSet-guarded at the point of use.
;
; SCOPE: source-level, which is the only level at which "armed before the
; auto-execute section runs" is observable at all.
; ==============================================================================

#Requires AutoHotkey v2.0

; Globals whose seeding in the pre-pump block IS the fix. Anything a #HotIf
; helper reads must be here, or IsSet-guarded where it is read.
global _HGBS_PRE_PUMP_SEEDED := ["CapsWordEnabled", "LayerEnabled", "TapHold",
	"_ALTGR_KANA_FIXUP", "_DriverBootPhase", "_PersonalShortcutsRegistry", "DriverPid"]
global _HGBS_HOTIF_PARENTS := Map()





; ==================================================================
; ==================================================================
; ======= 1/ The pre-pump block still seeds what it promises =======
; ==================================================================
; ==================================================================

; The entry source above Bundle_Init(). Everything a parse-time #HotIf can
; reach during the first pump must be established in here.
_HGBS_PrePumpSource() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	if (Src == "")
		return ""
	Code := _StripFullLineComments(Src)
	BundlePos := InStr(Code, "Bundle_Init()")
	return (BundlePos > 0) ? SubStr(Code, 1, BundlePos) : ""
}

_HGBS_SeedsSurviveInThePrePumpBlock() {
	global _HGBS_PRE_PUMP_SEEDED
	PrePump := _HGBS_PrePumpSource()
	Assert(PrePump != "",
		"the entry must still call Bundle_Init() and be readable — without that boundary this whole guard silently measures nothing")

	for Name in _HGBS_PRE_PUMP_SEEDED
		Assert(RegExMatch(PrePump, "m)^global\s+" . Name . "\s*:="),
			"'" . Name . "' is read by a parse-time #HotIf helper, so it must be assigned in the pre-pump block, above Bundle_Init's message-pumping RunWait. Moving it below that call re-opens the boot crash: a key pressed during the extraction evaluates the #HotIf and reads it unset")
}





; ==============================================================
; ==============================================================
; ======= 2/ Every parse-time #HotIf helper is boot-safe =======
; ==============================================================
; ==============================================================

; Names of the driver functions called from a parse-time #HotIf directive.
; Multi-line directives are covered: `#HotIf (` continues until the closing
; paren, and a scanner that only reads the directive's first line is blind to
; everything after it — that blindness is itself a recorded finding.
_HGBS_HotIfFunctions() {
	global _HGBS_HOTIF_PARENTS
	Src := _DriverSourceNoComments()
	Names := Map()
	Parents := Map()
	Lines := StrSplit(Src, "`n", "`r")
	InDirective := false
	Depth := 0
	for Line in Lines {
		Text := ""
		if RegExMatch(Line, "^\s*#HotIf\s*(.*)$", &M) {
			Text := M[1]
			; A directive that opens more parens than it closes continues below.
			Depth := 0
			InDirective := true
		} else if (InDirective) {
			Text := Line
		} else {
			continue
		}
		Depth += StrLen(Text) - StrLen(StrReplace(Text, "("))
		Depth -= StrLen(Text) - StrLen(StrReplace(Text, ")"))
		if (Depth <= 0)
			InDirective := false

		for Fn in _HGBS_CalleesIn(Text) {
			Names[Fn] := true
			if !Parents.Has(Fn)
				Parents[Fn] := "#HotIf"
		}
	}
	; TRANSITIVE. The reported crash went through a one-line wrapper:
	; `#HotIf LLM_Tooltip_GetText()` calls LLM_TooltipGetText(), and it is the
	; INNER function that reads the unset globals. A scan that stops at the name
	; written in the directive sees a wrapper declaring no globals at all and
	; reports the whole class clean — a false green over the exact bug. Walk the
	; call graph until it closes.
	Pending := []
	for Fn, _ in Names
		Pending.Push(Fn)
	while (Pending.Length > 0) {
		Fn := Pending.Pop()
		; A callee harvested from source can be a built-in or a method (Has, Map…),
		; so absence is expected here and must not throw — this is one of the rare
		; legitimate uses of the tolerant variant.
		Body := _DriverFuncBodyOrEmpty(Fn)
		if (Body == "")
			continue
		for Callee in _HGBS_CalleesIn(Body) {
			if Names.Has(Callee)
				continue
			Names[Callee] := true
			Parents[Callee] := Fn
			Pending.Push(Callee)
		}
	}
	_HGBS_HOTIF_PARENTS := Parents
	return Names
}

_HGBS_PathTo(Fn) {
	global _HGBS_HOTIF_PARENTS
	Path := Fn
	Seen := Map(Fn, true)
	while _HGBS_HOTIF_PARENTS.Has(Fn) {
		Fn := _HGBS_HOTIF_PARENTS[Fn]
		Path := Fn . " -> " . Path
		if (Fn == "#HotIf" || Seen.Has(Fn))
			break
		Seen[Fn] := true
	}
	return Path
}

; Function names called in a snippet, minus the language constructs and the
; control-flow keywords AHK spells with parentheses.
_HGBS_CodeOnly(Text) {
	Out := ""
	Quote := ""
	i := 1
	while (i <= StrLen(Text)) {
		Ch := SubStr(Text, i, 1)
		if (Quote != "") {
			if (Ch == Chr(96)) {
				Out .= "  "
				i += 2
				continue
			}
			if (Ch == Quote)
				Quote := ""
			Out .= (Ch == "`n") ? "`n" : " "
		} else if (Ch == Chr(34) or Ch == Chr(39)) {
			Quote := Ch
			Out .= " "
		} else if (Ch == ";") {
			LineEnd := InStr(Text, "`n", , i)
			if !LineEnd
				break
			Out .= "`n"
			i := LineEnd + 1
			continue
		} else {
			Out .= Ch
		}
		i++
	}
	return Out
}

_HGBS_CalleesIn(Text) {
	static Skip := Map("IsSet", true, "not", true, "and", true, "or", true,
		"if", true, "while", true, "for", true, "return", true, "loop", true,
		"catch", true, "switch", true, "case", true, "Critical", true)
	Text := _HGBS_CodeOnly(Text)
	Found := []
	Pos := 1
	; A method call such as Object.Has() is not a call to a same-named driver
	; function. Treating it as one makes the graph jump between unrelated APIs.
	while (FoundPos := RegExMatch(Text, "(?<![.\w])([A-Za-z_]\w*)\s*\(", &C, Pos)) {
		Pos := FoundPos + C.Len
		; A one-line `try Callee()` contains an early-boot UnsetError by language
		; contract; descending into it reports a crash that cannot escape #HotIf.
		Prefix := SubStr(Text, Max(1, FoundPos - 12), Min(12, FoundPos - 1))
		if RegExMatch(Prefix, "i)\btry\s*$")
			continue
		if Skip.Has(C[1])
			continue
		Found.Push(C[1])
	}
	return Found
}

; Every global a function dereferences without an IsSet guard on that same
; global. A `global a, b` declaration line only imports names; what matters is
; whether each is READ bare afterwards.
_HGBS_UnguardedGlobalsOf(Body) {
	Unguarded := []
	Declared := []
	for Line in StrSplit(Body, "`n", "`r") {
		if RegExMatch(Line, "^\s*global\s+([^\r\n:=]+)$", &G) {
			for Name in StrSplit(G[1], ",", " `t")
				if (Name != "")
					Declared.Push(Name)
		}
	}
	for Name in Declared {
		; Guarded anywhere in the body is enough: these functions are small and
		; the guard is always an early return.
		if InStr(Body, "IsSet(" . Name . ")")
			continue
		Unguarded.Push(Name)
	}
	return Unguarded
}

; The class guard. A helper reachable from a parse-time #HotIf may read a global
; only if that global is seeded before the first pump, or if it checks IsSet.
_HGBS_EveryHotIfHelperIsBootSafe() {
	global _HGBS_PRE_PUMP_SEEDED
	Fns := _HGBS_HotIfFunctions()

	Count := 0
	for _, _ in Fns
		Count++
	Assert(Count >= 5,
		"the scan must reach the real parse-time #HotIf directives (found only " . Count . " helper(s)) — a scan that matches nothing cannot fail")

	for Fn, _ in Fns {
		; Not a driver function (a built-in, or defined in a file outside the
		; scanned tree) — nothing to assert, so the tolerant variant is required
		; here rather than the throwing one.
		Body := _DriverFuncBodyOrEmpty(Fn)
		if (Body == "")
			continue
		for Name in _HGBS_UnguardedGlobalsOf(Body) {
			Seeded := false
			for S in _HGBS_PRE_PUMP_SEEDED
				if (S == Name)
					Seeded := true
			Assert(Seeded,
				"'" . Fn . "' is reachable from a parse-time #HotIf via " . _HGBS_PathTo(Fn)
				. " and reads the global '" . Name . "' without an IsSet guard, while that global is not seeded in the pre-pump block. A key pressed during Bundle_Init's extraction evaluates that #HotIf before the assignment runs, raises UnsetError inside the evaluator, and kills the boot. Either IsSet-guard the read or seed the global above Bundle_Init()")
		}
	}
}

_HGBS_FunctionScannerIgnoresLiteralBraces() {
	Body := _DriverFuncBody("LLM_TooltipGetText")
	AssertContains(Body, "_LLM_TooltipGetCurrentRecord()",
		"the positive-control tooltip body must be extracted")
	Assert(InStr(Body, "LLM_TriggerJournalReconcile") = 0,
		"a brace in a string or comment must not make function extraction absorb unrelated sibling files")
}

_HGBS_CalleeScannerIgnoresNonCodeAndMethods() {
	Snippet := 'RealCall()`nobj.MethodCall()`n"StringCall()" ' . Chr(59)
		. ' CommentCall()`ntry ContainedCall()'
	Calls := _HGBS_CalleesIn(Snippet)
	AssertEqual(1, Calls.Length,
		"the call graph must ignore method-name collisions, strings, and comments")
	AssertEqual("RealCall", Calls[1])
}


Test("meta hotif-globals-boot-safe: the pre-pump block still seeds what it promises",
	_HGBS_SeedsSurviveInThePrePumpBlock)
Test("meta hotif-globals-boot-safe: every parse-time #HotIf helper is boot-safe",
	_HGBS_EveryHotIfHelperIsBootSafe)
Test("meta hotif-globals-boot-safe: function scan stops at the real closing brace",
	_HGBS_FunctionScannerIgnoresLiteralBraces)
Test("meta hotif-globals-boot-safe: call scan follows executable free functions only",
	_HGBS_CalleeScannerIgnoresNonCodeAndMethods)
