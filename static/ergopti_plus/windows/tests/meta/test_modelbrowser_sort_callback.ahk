; tests/meta/test_modelbrowser_sort_callback.ahk

; ==============================================================================
; MODULE: LLM Model Browser Sort Callback Guard
; DESCRIPTION:
; Static source guard for the _LLM_ModelBrowser_Sort O(n log n) fix in
; ui/llm_model_browser.ahk.
;
; ROOT CAUSE ENCODED:
; The original _LLM_ModelBrowser_Sort used a manual O(n²) bubble sort
; implemented with nested Loop constructs. With a large Ollama model library
; (100+ models), this produced visible UI lag every time the browser was opened
; or refreshed. The fix replaces the bubble sort with out.Sort(...) passing a
; comparator callback (_LLM_ModelBrowser_Compare), giving O(n log n) behaviour
; through AHK's built-in Array.Sort.
; ==============================================================================

#Requires AutoHotkey v2.0

_TMBSC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TMBSC_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; =========================================================================
; =========================================================================
; ======= 1/ _LLM_ModelBrowser_Sort uses Array.Sort with comparator =======
; =========================================================================
; =========================================================================

_TMBSC_SortUsesCallback() {
	Src := _TMBSC_StripLineComments(_TMBSC_ReadSource("ui/model_browser/init.ahk"))
	Assert(Src != "", "ui/llm_model_browser.ahk must be readable")

	Body := _DriverFuncBody("_LLM_ModelBrowser_Sort")
	Assert(Body != "", "_LLM_ModelBrowser_Sort must be defined in ui/llm_model_browser.ahk")

	; Must use Array.Sort with a comparison callback (not a nested loop bubble sort)
	Assert(InStr(Body, ".Sort(") > 0,
		"_LLM_ModelBrowser_Sort must use Array.Sort() with a comparator callback (O(n log n)), not a manual bubble sort")

	; Must reference the comparator function
	Assert(InStr(Body, "_LLM_ModelBrowser_Compare") > 0,
		"_LLM_ModelBrowser_Sort must pass _LLM_ModelBrowser_Compare as the sort comparator")

	; The O(n²) nested loop form must be absent
	Assert(InStr(Body, "loop n - 1") = 0,
		"_LLM_ModelBrowser_Sort must NOT use a manual nested-loop bubble sort (replaced by Array.Sort)")
}
Test("llm_model_browser: _LLM_ModelBrowser_Sort uses Array.Sort with comparator (O(n log n))", _TMBSC_SortUsesCallback)
