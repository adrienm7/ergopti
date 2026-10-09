; tests/meta/test_i18n_setlocale_resets_fallback.ahk

; ==============================================================================
; MODULE: I18nSetLocale Fallback Reset Guard
; DESCRIPTION:
; Static source guard for the I18nSetLocale fallback-warm reset fix in
; infra/i18n.ahk.
;
; ROOT CAUSE ENCODED:
; After a locale change via I18nSetLocale, the fallback lookup table
; (_I18nFallbacksWarmed) was not cleared. The next call to t() would short-
; circuit at the "already warmed" check and use the stale fallback translations
; from the old locale rather than building the table for the new locale. The
; result was that UI strings remained partially in the old language after
; switching locales.
;
; The fix sets _I18nFallbacksWarmed := false inside I18nSetLocale so the next
; t() call rebuilds the fallback table for the newly active locale.
; ==============================================================================

#Requires AutoHotkey v2.0

_TISLRF_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TISLRF_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; =============================================================================
; =============================================================================
; ======= 1/ I18nSetLocale clears _I18nFallbacksWarmed on locale change =======
; =============================================================================
; =============================================================================

_TISLRF_FallbackWarmReset() {
	Src := _TISLRF_StripLineComments(_TISLRF_ReadSource("infra/i18n.ahk"))
	Assert(Src != "", "infra/i18n.ahk must be readable")

	Body := _DriverFuncBody("I18nSetLocale")
	Assert(Body != "", "I18nSetLocale must be defined in infra/i18n.ahk")

	; _I18nFallbacksWarmed must be reset inside the function
	Assert(InStr(Body, "_I18nFallbacksWarmed  := false") > 0
		or InStr(Body, "_I18nFallbacksWarmed := false") > 0,
		"I18nSetLocale must reset _I18nFallbacksWarmed := false so the next t() call rebuilds the fallback table for the new locale")
}
Test("i18n: I18nSetLocale resets _I18nFallbacksWarmed to false on locale change", _TISLRF_FallbackWarmReset)
