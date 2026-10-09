; tests/meta/test_i18n_fallback_deferred.ahk

; ==============================================================================
; MODULE: i18n Fallback-Deferral Test
; DESCRIPTION:
; Guards that the i18n locale loader parses only the ACTIVE locale on the boot
; critical path and defers the EN/FR fallback caches off it: warmed by a
; post-"ready" timer, or lazily on the first missing-key lookup inside t().
;
; WHY THIS MATTERS (the regression this encodes):
;   I18nPreload() used to call _I18nEnsureLoaded(), which parses the active locale
;   AND the EN fallback (~2196 keys each) on the boot path. On a complete locale
;   the fallback is never consulted, so that second JSON parse (~78 ms) was pure
;   boot latency. The loader now parses the active locale alone at boot and warms
;   the fallbacks via I18nWarmFallbacks (deferred SetTimer) plus a lazy net inside
;   t(). If a future edit reverts I18nPreload to the all-locales path, boot
;   re-inflates: caught here.
;
; SCOPE: source introspection of infra/i18n.ahk + ErgoptiPlus.ahk (not loaded by
;   the headless runner).
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckI18nFallbackDeferred() {
	SplitPath(A_ScriptDir, , &WindowsDir)

	I18n := _DriverDirConcat("infra")
	Assert(I18n != "", "infra\i18n.ahk must be readable")

	; The boot preload must load the active locale only, with a separate warmer and
	; a lazy net for the fallbacks.
	Assert(InStr(I18n, "_I18nEnsureActiveLoaded("),
		"i18n must define _I18nEnsureActiveLoaded (active-only boot load)")
	Assert(InStr(I18n, "_I18nEnsureFallbacksLoaded("),
		"i18n must define _I18nEnsureFallbacksLoaded (fallback load split out)")
	Assert(InStr(I18n, "I18nWarmFallbacks("),
		"i18n must define I18nWarmFallbacks (the deferred fallback warmer)")
	Assert(InStr(I18n, "I18N_FALLBACK_WARM_DELAY_MS"),
		"i18n must define the I18N_FALLBACK_WARM_DELAY_MS defer constant")
	Assert(InStr(I18n, "if !_I18nFallbacksWarmed"),
		"t() must lazy-load the fallbacks on the first miss (the lazy net)")

	; The boot path must arm the deferred warmer. That it is armed AFTER "ready" is
	; enforced separately by test_boot_deferred_tasks; here we assert it exists.
	Boot := ""
	try Boot := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	Assert(Boot != "", "ErgoptiPlus.ahk must be readable")
	Assert(InStr(Boot, "SetTimer(I18nWarmFallbacks"),
		"ErgoptiPlus.ahk must arm the deferred I18nWarmFallbacks timer")
}

Test("meta i18n: fallback locales deferred off the boot path",
	_MetaCheckI18nFallbackDeferred)
