; tests/meta/core/i18n/test_fallback_deferred.ahk

; ==============================================================================
; MODULE: i18n Fallback-Deferral Test
; DESCRIPTION:
; Guards that the i18n locale loader parses only the ACTIVE locale on the boot
; critical path and leaves the EN/FR fallback caches to the first missing-key
; lookup inside t(), which a complete catalogue never makes.
;
; WHY THIS MATTERS (the regression this encodes):
;   I18nPreload() used to call _I18nEnsureLoaded(), which parses the active locale
;   AND the EN fallback (~2196 keys each) on the boot path. On a complete locale
;   the fallback is never consulted, so that second JSON parse (~78 ms) was pure
;   boot latency. The loader now parses the active locale alone at boot, with a
;   lazy net inside t(). If a future edit reverts I18nPreload to the all-locales
;   path, boot re-inflates: caught here.
;
;   A post-"ready" timer later warmed the fallbacks anyway: each boot then loaded
;   one or two catalogues nobody read, on the input thread (en.tsv measured at
;   about 110 million cycles and 1000 page faults, 2026-11-21). Every shipped
;   catalogue carries en.json's keys, so a re-armed warmer is caught here too.
;
; SCOPE: source introspection of core/i18n/engine/i18n.ahk + ErgoptiPlus.ahk (not loaded by
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

	I18n := _DriverDirsConcat("infra", "hotstrings/engine", "diagnostics/engine/reports", "diagnostics/engine/field_run", "apps/engine", "ai/engine", "tray", "menu/engine", "settings/engine", "platform/input", "core/ui/engine", "core/timing/engine", "core/text/engine", "core/network/engine", "core/logger/engine", "core/lifecycle/engine", "core/i18n/engine", "core/fs/engine")
	Assert(I18n != "", "core\i18n\engine\i18n.ahk must be readable")

	; The boot preload must load the active locale only, with a lazy net for the
	; fallbacks.
	Assert(InStr(I18n, "_I18nEnsureActiveLoaded("),
		"i18n must define _I18nEnsureActiveLoaded (active-only boot load)")
	Assert(InStr(I18n, "_I18nEnsureFallbacksLoaded("),
		"i18n must define _I18nEnsureFallbacksLoaded (fallback load split out)")
	Assert(InStr(I18n, "if !_I18nFallbacksWarmed"),
		"t() must lazy-load the fallbacks on the first miss (the lazy net)")
	Assert(!RegExMatch(I18n, "SetTimer\([^)\r\n]*Fallback"),
		"no timer may warm the fallback catalogues: every catalogue carries en.json's keys")

	; No boot path may load the fallbacks before a key misses.
	Boot := ""
	try Boot := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	Assert(Boot != "", "ErgoptiPlus.ahk must be readable")
	Assert(!InStr(Boot, "Fallbacks", true) && !InStr(Boot, "_I18nEnsureLoaded(", true),
		"ErgoptiPlus.ahk must not load the fallback catalogues: a complete active catalogue never reads them")
}

Test("meta i18n: fallback locales deferred off the boot path",
	_MetaCheckI18nFallbackDeferred)
