; ui/onboarding/translate.ahk

; ==============================================================================
; MODULE: Onboarding / Locale Preview Translation
; DESCRIPTION:
; Resolves a key in the locale the user is previewing, without switching the
; running script. Definitions only: the WebView host and the error renderer
; call it, and the test harness includes it with them without building the
; wizard (core.ahk carries state the harness replaces with stubs).
; ==============================================================================





; Resolve a translation key in a target locale WITHOUT touching the active
; locale cache. Used while the user previews languages, so the window title and
; error messages follow the language being previewed while the rest of the
; running script keeps its current locale until the user confirms the choice.
;
; @param Code string Locale code to resolve under (e.g. "fr", "en").
; @param Key  string Translation key to look up.
; @returns string The translated value in Code, or the key itself on failure.
_Onboarding_Translate(Code, Key) {
	; Load the target locale into a throwaway local cache so we never touch the
	; shared globals (_I18nLocale / _I18nCache / _I18nCacheLoaded). Swapping
	; globals was the root cause of the rapid-switch stale-language bug: rapid
	; ItemSelect events queued multiple swap/restore cycles, each one capturing
	; the globals mid-flight from the previous swap, leaving the cache pointing
	; at an arbitrary intermediate locale after the dust settled.
	local LocalCache := Map(), Loaded := false
	_I18nLoadInto(Code, &LocalCache, &Loaded)
	if Loaded and LocalCache.Has(Key)
		return LocalCache[Key]
	; Fall back to the key name so the UI is never silently blank
	return Key
}
