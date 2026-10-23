; tests/meta/modules/llm/menu/test_modelbrowser_sort_callback.ahk

; =================================================================
; MODULE: LLM Model Browser Sort Callback Guard
; DESCRIPTION:
; Guards the actual native Array API and catalogue comparator. Runtime tests
; cover sorted family/parameter order, independent copies and duplicates.
;
; ROOT CAUSE ENCODED:
; The previous assertion required out.Sort even though native AutoHotkey v2
; Array does not expose that method. It passed on an implementation that threw
; before returning any sorted result. Reject that unsupported API explicitly;
; the separate native component cases exercise the actual sorting contract.
; =================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ Supported Native Array API and Comparator =======
; ============================================================
; ============================================================

_TMBSC_UsesSupportedArrayApi() {
	Body := _DriverFuncBody("_LLM_ModelBrowser_Sort")
	Comparator := _DriverFuncBody("_LLM_ModelBrowser_Compare")
	Assert(Body != "", "The actual model-browser sort helper must exist")
	Assert(Comparator != "", "The actual catalogue comparator must exist")
	; Native AutoHotkey v2 Array has no Sort method. The old positive assertion
	; certified an unsupported call; actual ordering and cloning run separately.
	Assert(InStr(Body, ".Sort(") = 0,
		"A native array must not call the unsupported Array.Sort API")
	Assert(InStr(Body, "_LLM_ModelBrowser_Compare") > 0,
		"The actual sorting path must reference its catalogue comparator")
	Assert(InStr(Comparator, "LLM_GetModelInfo") > 0 && InStr(Comparator, "StrCompare") > 0,
		"The real comparator must retain both catalogue size and family comparison")
}
Test("llm_model_browser: sorting uses supported native array operations and the real comparator", _TMBSC_UsesSupportedArrayApi)
