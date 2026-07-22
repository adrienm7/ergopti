; tests/meta/test_llm_parse_billions_null_guard.ahk

; ==============================================================================
; MODULE: _LLM_ParseBillions JSON-null Guard Meta Test
; DESCRIPTION:
; Regression guard ensuring _LLM_ParseBillions rejects JSON_NULL sentinel
; objects before passing the value to RegExMatch.
;
; The bug: the guard `if (s == "" or not IsObject(s) and s == "N/A")` had
; wrong operator precedence.  When s is a JSON_NULL Object:
;   - s == ""       => false
;   - not IsObject(s) => false  (short-circuits the "and s == N/A" branch)
;   - full condition => false
; Control fell through to RegExMatch(s, ...) which requires a String and
; threw a TypeError.  Because LLM_GetModelIndex has no try wrapper, the
; exception propagated and the entire model index was lost — the prediction
; engine repeated the throw on every hot-path call once a null appeared in
; a Ollama model catalogue entry.
;
; The fix: change the guard to `if (s == "" or IsObject(s) or s == "N/A")`
; so any object (including JSON_NULL) returns 0.0 immediately.
;
; SCOPE: source introspection of modules/llm/models.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_LPBN_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_LPBN_CheckGuardRejectsObjects() {
	Src := _LPBN_ReadSource("modules/llm/models.ahk")
	Assert(Src != "", "modules/llm/models.ahk must be readable")

	Body := _DriverFuncBody("_LLM_ParseBillions")
	Assert(Body != "", "_LLM_ParseBillions must be present in models.ahk")

	; Old broken guard — must not exist
	Assert(!InStr(Body, "not IsObject(s) and s =="),
		"_LLM_ParseBillions must not use 'not IsObject(s) and s ==' — that form is false for JSON_NULL objects and lets them reach RegExMatch")

	; Correct guard — must be present
	Assert(InStr(Body, "IsObject(s)"),
		"_LLM_ParseBillions must reject objects (IsObject guard) before calling RegExMatch")
}

_LPBN_CheckGuardComesBeforeRegExMatch() {
	Src := _LPBN_ReadSource("modules/llm/models.ahk")
	Assert(Src != "", "modules/llm/models.ahk must be readable")

	Body := _DriverFuncBody("_LLM_ParseBillions")
	Assert(Body != "", "_LLM_ParseBillions must be present in models.ahk")

	GuardPos    := InStr(Body, "IsObject(s)")
	RegExPos    := InStr(Body, "RegExMatch(s")

	Assert(GuardPos > 0, "_LLM_ParseBillions must have an IsObject guard")
	Assert(RegExPos > 0, "_LLM_ParseBillions must call RegExMatch")
	Assert(GuardPos < RegExPos,
		"IsObject guard must precede the RegExMatch call in _LLM_ParseBillions")
}


Test("meta llm-parse-billions: _LLM_ParseBillions uses correct guard to reject JSON_NULL objects",
	_LPBN_CheckGuardRejectsObjects)

Test("meta llm-parse-billions: IsObject guard appears before RegExMatch in _LLM_ParseBillions",
	_LPBN_CheckGuardComesBeforeRegExMatch)
