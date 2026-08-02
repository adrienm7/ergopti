; ui/onboarding/core.ahk

; ==============================================================================
; MODULE: Onboarding / Constants + Entry Points + i18n Preview
; DESCRIPTION:
; Wizard constants and shared state, the public entry points that launch / resume the first-run wizard, the AltGr-neutralisation guard used by other modules #HotIf criteria, and the i18n live-preview helpers.
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

; Default locale index within I18N_LOCALES (1-based; English is index 4 — see
; the table in i18n.ahk: ar, cs, da, de, en, …). Pre-selecting English mirrors
; the historical default and reads as the safest fallback for an unknown user.
global ONBOARDING_DEFAULT_LOCALE_INDEX := 5

; Wizard window width (height is computed automatically from controls)
global ONBOARDING_WIN_W := 460

; Step 2 (layout preview) uses a wider canvas so the embedded keyboard
; layout JPG can be rendered closer to its native resolution — a 420 px-
; wide scale-down on the default window made the keys barely legible.
global ONBOARDING_STEP2_W := 820

; Height of the language ListView — fits ~8 rows, scrollable beyond that
global ONBOARDING_LV_H := 240

; Vertical margin applied to every wizard page. Bumped from the historical 16
; to give the redesigned pages (progress dots + larger bold titles) more air.
global ONBOARDING_MARGIN_Y := 20

; Wizard progress indicator — top-of-page step dots.
; The wizard draws one dot per step so the user always knows where they are.
; Six steps in order: language, config folder, layout, magic key, metrics,
; gestures. Keep in sync with the stepIndex passed by each _Onboarding_StepN.
global ONBOARDING_TOTAL_STEPS := 6
; Horizontal pitch (px) between adjacent step-glyph centres in the progress row.
global ONBOARDING_DOT_PITCH := 28
; Glyph colours (6-hex RGB, no 0x — matches AHK's ``c`` option format).
; Completed steps use green; the current step uses accent blue; upcoming steps are gray.
global ONBOARDING_DOT_ACTIVE := "1E6FD9"
global ONBOARDING_DOT_IDLE   := "C8C8C8"
global ONBOARDING_DOT_DONE   := "1A8C3A"  ; green — shown on completed steps

; Default magic key inserted into the Step 3 input.
; ★ (U+2605 BLACK STAR) is the canonical Ergopti default — it sits on a
; dedicated key in the Ergopti+ layout and the rest of the codebase
; (category.magic_key, dialog.magic_key.prompt, the auto-config menu)
; already labels it as "the magic key". The wizard pre-selects this
; option so a first-run user gets the documented default without any
; extra step; the other radios (``*`` / ``ù`` / ``;``) stay available
; as recommended fallbacks for non-Ergopti layouts.
global ONBOARDING_DEFAULT_MAGIC_KEY := "★"

; Collected answers — populated as the user advances through each step
global _ob_locale            := "en"
global _ob_layout            := false
global _ob_magic_key         := ONBOARDING_DEFAULT_MAGIC_KEY
; Provenance for the answer above. The default IS a valid answer, so its value
; can never tell us whether the user picked it or whether nothing was loaded
; yet — that has to be tracked separately, or a saved default gets silently
; replaced by the layout-derived fallback on the next page build.
global _ob_magic_key_explicit := false
global _ob_metrics           := false
global _ob_gestures          := false
; Config folder choice. Initialised to the current _ConfigDir so a re-run via
; the tray menu shows the user's existing location pre-filled. The first-run
; path inherits whatever paths.toml resolved at boot — typically the OS default
; (``%USERPROFILE%\.config\ergopti_plus\``) since the wizard runs precisely
; when paths.toml hasn't been customised yet.
global _ob_config_dir        := IsSet(_ConfigDir) ? _ConfigDir : ""
; When the user clicks "Auto-register" on the gestures step at first launch, the
; gestures module has not yet executed its top-level globals (Onboarding_Run is
; called early in ErgoptiPlus.ahk auto-exec, long before ``#Include modules/gestures.ahk``
; runs). Calling ``GestureAutoConfigureRegistry`` directly would crash on unset
; globals — so we record the intent here and flush a one-shot flag to config.toml
; in _Onboarding_Commit. The gestures module picks the flag up on the very next
; reload and performs the actual registry writes there.
global _ob_register_pending  := false

; Reference to the currently active wizard Gui object
global _ob_gui := 0

; Debounce state for the step-1 language preview. ItemSelect fires on every
; arrow key / mouse movement, including deselect+select pairs for a single
; navigation step. We arm a one-shot timer and re-read the focused row at
; fire time so only the final resting position triggers a FileRead+JsonParse.
global _ob_s1_lv        := unset   ; ListView ref kept for the timer closure
global _ob_s1_lv_hwnd   := 0       ; Hwnd of that ListView, used to filter WM_KEYDOWN
global _ob_s1_refs      := unset   ; Map of {headingText, btn, SortedLocales}
global _ob_s1_debounce_ms := 120   ; delay after last ItemSelect before re-render

; AltGr passthrough switch — read by ``IsRealAltGrPress`` in modules/keymap/layout/layout_altgr.ahk
; AND by ``IsOnboardingActive`` below. AHK promotes a key to a "prefix key" the
; moment any ``SC138 & X::`` combo is parsed, which costs SC138 (= AltGr) its
; native function. By making every related #HotIf variant evaluate to false we
; restore native behaviour for the duration of the wizard so the host Windows
; layout still produces its AltGr characters in the wizard's edit boxes (and
; anywhere else the user types while it is up). The wizard always exits via
; Reload or ExitApp so this flag never needs to be cleared by hand.
global _OB_ALTGR_PASSTHROUGH := false

; Public check used by other modules' #HotIf criteria to neutralise any
; AltGr-capturing hotkey (e.g. the RAlt tap-hold in platform/remap.ahk)
; while the wizard is on screen. Standalone hotkeys disappear cleanly when
; their #HotIf returns false, restoring the OS-native AltGr typing path.
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
	if FileExist(ConfigurationFile) {
		return
	}
	global _OB_ALTGR_PASSTHROUGH := true
	; Start from a clean slate. The reset lives here rather than in the first
	; page because that page is also the Back target, and resetting on arrival
	; discarded every answer given on the later steps.
	_Onboarding_ResetAnswers()
	; Prefer the shared WebView2 frontend (identical to the macOS wizard) when
	; available; fall back to the native AHK pages otherwise. Both paths set the
	; _ob_gui sentinel the park-loop below waits on.
	if !_Onboarding_TryWeb()
		_Onboarding_Step1()
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


; Allow the user to re-run the wizard from the tray menu even when a
; config already exists — useful after a reset or for re-configuration.
; AltGr passthrough is NOT activated here: the user already has a working
; config and needs their AltGr layer (e.g. magic key) to remain functional
; while navigating the wizard. Passthrough is only needed during first-run
; (Onboarding_Run) where no config exists yet and native AltGr typing in
; text fields must be preserved.
Onboarding_ShowFromMenu(*) {
	; Same web-first preference as first run; the native pages remain the
	; fallback. _Onboarding_TryWeb shows its own window (setting _ob_gui), so on
	; success there is nothing more to do here. The answers are cleared here so
	; a re-run does not inherit the previous run's, and so the first page can
	; stay a pure renderer — it doubles as the Back target.
	_Onboarding_ResetAnswers()
	if !_Onboarding_TryWeb()
		_Onboarding_Navigate(_Onboarding_Step1)
}





; =======================================
; =======================================
; ======= 3/ i18n preview helpers =======
; =======================================
; =======================================

; Resolve a translation key in a target locale WITHOUT touching the active
; locale cache. Used by step 1 so the heading/title/button can be re-rendered
; in the language being previewed while the rest of the running script keeps
; its current locale until the user confirms the choice.
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


; Strips the leading "ErgoptiPlus" brand + separator from a step title so it can
; be shown as an in-content heading without repeating the brand — the window
; title already reads "ErgoptiPlus — Configuration" on every page. The step-title
; keys historically doubled as window titles, so we strip at the point of use
; rather than editing the shared locale strings (all 21 locales use the exact
; "ErgoptiPlus — X" form). Locale-agnostic: a title with no brand prefix is
; returned unchanged.
; @param title string Localised step title (e.g. "ErgoptiPlus — Keyboard layout").
; @returns string The heading without the brand prefix (e.g. "Keyboard layout").
_Onboarding_StripBrand(title) {
	; Separators seen across locales: em dash (U+2014), en dash (U+2013), hyphen.
	return RegExReplace(title, "^\s*ErgoptiPlus\s*[\x{2014}\x{2013}\-]\s*", "")
}





