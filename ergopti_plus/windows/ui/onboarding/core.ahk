; ui/onboarding/core.ahk

; ==============================================================================
; MODULE: Onboarding / State + Entry Points + i18n Preview
; DESCRIPTION:
; Wizard state, the public entry points that launch the first-run wizard or
; re-run it from the tray, the AltGr-neutralisation guard other modules' #HotIf
; criteria read, and the translation helper that previews a locale without
; switching the running script.
;
; Split out of the former infra/onboarding.ahk (the module split); see
; ui/onboarding/init.ahk for the module overview. Functions and globals are
; hoisted, so load order across the onboarding/*.ahk files is irrelevant.
; ==============================================================================





; =============================================
; =============================================
; ======= 1/ Constants and wizard state =======
; =============================================
; =============================================

; Language of a first run, before the user picks one: I18nInit runs after the
; wizard, so no active locale exists yet. A re-run opens in the active locale.
global ONBOARDING_FIRST_RUN_LOCALE := "en"

; Language the wizard is shown in; its error messages follow it too.
global _ob_locale := ONBOARDING_FIRST_RUN_LOCALE

; Reference to the wizard's Gui (0 while none is open). Onboarding_Run parks on
; it, and the WebView2 host's singleton guard reads it.
global _ob_gui := 0

; AltGr passthrough switch — read by ``IsRealAltGrPress`` in modules/keymap/layout/layout_altgr.ahk
; AND by ``IsOnboardingActive`` below. While it is set every AltGr combination
; and AltGr tap-hold owner is false, so the host Windows layout still produces
; its AltGr characters in the wizard's edit boxes (and anywhere else the user
; types while it is up). SC138 stays an armed prefix key during the wizard,
; because the always-eligible "~SC138 & ~F24" anchor in platform/remap/altgr.ahk
; has no criterion, and that costs the wizard nothing: AutoHotkey reads SC138
; as the RAlt modifier on every layout and never suppresses a modifier prefix
; that no variant fires for (hook.cpp Case #1, "this_key.as_modifiersLR"), so
; the native AltGr press reaches the wizard. The anchor's ~ is there for the
; standalone SC138 hotkeys, which it fires on the press rather than on the
; release (test_altgr_prefix_arms_on_press.ahk). The wizard always exits via
; Reload or ExitApp so this flag never needs to be cleared by hand.
global _OB_ALTGR_PASSTHROUGH := false

; Public check used by other modules' #HotIf criteria to neutralise any
; AltGr-capturing hotkey (e.g. the AltGr tap-hold owners in
; platform/remap/altgr_criteria.ahk) while the wizard is on screen. Standalone
; hotkeys disappear cleanly when their #HotIf returns false; the SC138 prefix
; itself stays armed by the "~SC138 & ~F24" anchor, and AutoHotkey passes that
; modifier's press through when no variant fires (see _OB_ALTGR_PASSTHROUGH
; above).
IsOnboardingActive() {
	global _OB_ALTGR_PASSTHROUGH
	return IsSet(_OB_ALTGR_PASSTHROUGH) and _OB_ALTGR_PASSTHROUGH
}





; ======================================
; ======================================
; ======= 2/ Public entry points =======
; ======================================
; ======================================

; Run the wizard only when config.toml does not yet exist.
; Called at startup before features are loaded.
;
; BLOCKING contract: this function must NOT return while the wizard is on
; screen. ``g.Show()`` is non-blocking on its own, so without this guard the
; caller would continue with no config and ParseTomlFile() would raise
; cascading errors that crash the GUI within ~1 second. We park here until
; the wizard either commits (calls Reload, which kills the loop) or the user
; dismisses it (in which case there is no usable config and we ExitApp).
Onboarding_Run() {
	global ONBOARDING_FIRST_RUN_LOCALE
	if FileExist(ConfigurationFile) {
		return
	}
	global _OB_ALTGR_PASSTHROUGH := true
	global _ob_locale := ONBOARDING_FIRST_RUN_LOCALE
	; The wizard is the only way to create a configuration. Without WebView2 it
	; cannot be shown, and the driver cannot run on a configuration nobody chose.
	if !_Onboarding_TryWeb() {
		_Onboarding_ShowError("onboarding.error.open_failed")
		ExitApp(1)
	}
	; Loop tick chosen large enough to leave the message pump idle most of
	; the time, small enough to dismiss the script quickly when the user
	; closes the wizard.
	while (_ob_gui != 0) {
		Sleep(100)
	}
	; Reaching here means the wizard window was closed without committing —
	; the driver cannot operate without a config, so exit cleanly.
	ExitApp(0)
}


; Re-runs the wizard from the tray menu over the configuration in force: the
; pages open on its values and in the active language. AltGr passthrough is
; NOT activated here: the user already has a working config and needs their
; AltGr layer (e.g. magic key) to remain functional while navigating the
; wizard. Passthrough is only needed during first-run (Onboarding_Run) where
; no config exists yet and native AltGr typing in text fields must be
; preserved.
Onboarding_ShowFromMenu(*) {
	global _ob_locale := I18nGetLocale()
	if !_Onboarding_TryWeb()
		_Onboarding_ShowError("onboarding.error.open_failed")
}





; =======================================
; =======================================
; ======= 3/ i18n preview helpers =======
; =======================================
; =======================================

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
