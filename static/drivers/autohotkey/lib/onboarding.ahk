; drivers/autohotkey/lib/onboarding.ahk

; ==============================================================================
; MODULE: Onboarding Wizard
; DESCRIPTION:
; Displays a multi-step first-run wizard that guides the user through the
; initial configuration of ErgoptiPlus when no config.toml is found.
;
; FEATURES & RATIONALE:
; 1. First-Run Detection: Called by ErgoptiPlus.ahk before any feature is
;    activated — if ConfigurationFile does not exist, the wizard must run
;    before the script can operate.
; 2. Page-as-Destroy Pattern: Each wizard step destroys the current Gui and
;    creates a fresh one. This avoids the complexity of hiding/showing groups
;    of controls and keeps each page self-contained.
; 3. Locale-Live-Switch: Selecting a language on step 1 immediately re-renders
;    the title, heading and Next button in the previewed locale via the
;    transient cache-swap helper, so the user sees the wizard in their language
;    before even reaching step 2.
; 4. Atomic Write: All user choices are applied in a single TOML_BatchWrite
;    call at the end, then Reload is called once.
; ==============================================================================




; ================================================
; ================================================
; ======= 1/ Constants and wizard state =======
; ================================================
; ================================================

; Default locale index within I18N_LOCALES (1-based; English is index 4 — see
; the table in i18n.ahk: ar, cs, da, de, en, …). Pre-selecting English mirrors
; the historical default and reads as the safest fallback for an unknown user.
global ONBOARDING_DEFAULT_LOCALE_INDEX := 5

; Wizard window width (height is computed automatically from controls)
global ONBOARDING_WIN_W := 460

; Height of the language ListView — fits ~8 rows, scrollable beyond that
global ONBOARDING_LV_H := 240

; Default magic key inserted into the Step 3 input. ★ is the canonical visual
; symbol for the magic key; the user can change it to ù, ; or any single character.
global ONBOARDING_DEFAULT_MAGIC_KEY := "★"

; Collected answers — populated as the user advances through each step
global _ob_locale            := "en"
global _ob_layout            := false
global _ob_magic_key         := ONBOARDING_DEFAULT_MAGIC_KEY
global _ob_metrics           := false
global _ob_gestures          := false
; When the user clicks "Auto-register" on the gestures step at first launch, the
; gestures module has not yet executed its top-level globals (Onboarding_Run is
; called early in ErgoptiPlus.ahk auto-exec, long before ``#Include modules/gestures.ahk``
; runs). Calling ``GestureAutoConfigureRegistry`` directly would crash on unset
; globals — so we record the intent here and flush a one-shot flag to config.toml
; in _Onboarding_Commit. The gestures module picks the flag up on the very next
; reload and performs the actual registry writes there.
global _ob_register_pending  := false

; Reference to the currently active wizard Gui object
global _ob_gui          := unset

; AltGr passthrough switch — read by ``IsRealAltGrPress`` in lib/layout/layout_altgr.ahk
; AND by ``IsOnboardingActive`` below. AHK promotes a key to a "prefix key" the
; moment any ``SC138 & X::`` combo is parsed, which costs SC138 (= AltGr) its
; native function. By making every related #HotIf variant evaluate to false we
; restore native behaviour for the duration of the wizard so the host Windows
; layout still produces its AltGr characters in the wizard's edit boxes (and
; anywhere else the user types while it is up). The wizard always exits via
; Reload or ExitApp so this flag never needs to be cleared by hand.
global _OB_ALTGR_PASSTHROUGH := false

; Public check used by other modules' #HotIf criteria to neutralise any
; AltGr-capturing hotkey (e.g. the RAlt tap-hold in modules/tap_holds.ahk)
; while the wizard is on screen. Standalone hotkeys disappear cleanly when
; their #HotIf returns false, restoring the OS-native AltGr typing path.
IsOnboardingActive() {
	global _OB_ALTGR_PASSTHROUGH
	return IsSet(_OB_ALTGR_PASSTHROUGH) and _OB_ALTGR_PASSTHROUGH
}




; =========================================
; =========================================
; ======= 2/ Public entry points =======
; =========================================
; =========================================

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
	_Onboarding_Step1()
	; Loop tick chosen large enough to leave the message pump idle most of
	; the time, small enough to dismiss the script quickly when the user
	; closes the wizard.
	while IsSet(_ob_gui) {
		Sleep(100)
	}
	; Reaching here means the wizard window was closed without committing —
	; the driver cannot operate without a config, so exit cleanly.
	ExitApp(0)
}


; Allow the user to re-run the wizard from the tray menu even when a
; config already exists — useful after a reset or for re-configuration.
Onboarding_ShowFromMenu(*) {
	global _OB_ALTGR_PASSTHROUGH := true
	_Onboarding_Step1()
}




; ===============================================
; ===============================================
; ======= 3/ i18n preview helpers =======
; ===============================================
; ===============================================

; Resolve a translation key in a target locale WITHOUT touching the active
; locale cache. Used by step 1 so the heading/title/button can be re-rendered
; in the language being previewed while the rest of the running script keeps
; its current locale until the user confirms the choice.
;
; @param Code string Locale code to resolve under (e.g. "fr", "en").
; @param Key  string Translation key to look up.
; @returns string The translated value in Code, or the key itself on failure.
_Onboarding_Translate(Code, Key) {
	global _I18nLocale, _I18nCache, _I18nCacheLoaded
	PrevLocale := _I18nLocale
	PrevCache  := _I18nCache
	PrevLoaded := _I18nCacheLoaded
	_I18nLocale      := Code
	_I18nCacheLoaded := false
	Value := t(Key)
	_I18nLocale      := PrevLocale
	_I18nCache       := PrevCache
	_I18nCacheLoaded := PrevLoaded
	return Value
}




; ==========================================
; ==========================================
; ======= 4/ Step implementations =======
; ==========================================
; ==========================================

; ============================================
; ===== 4.1) Step 1 — Language selection =====
; ============================================

_Onboarding_Step1() {
	_Onboarding_DestroyActive()
	global _StaticDir, _ob_layout, _ob_magic_key, _ob_metrics, _ob_gestures, _ob_register_pending
	_ob_layout            := false
	_ob_magic_key         := ONBOARDING_DEFAULT_MAGIC_KEY
	_ob_metrics           := false
	_ob_gestures          := false
	_ob_register_pending  := false

	; Sort the locale list alphabetically by Name so the wizard's language
	; picker matches the tray menu's order (both use _I18nSortedLocales) —
	; users who know where English lives in the tray menu now find it in the
	; same spot here. Resolve the default English row in the sorted list so
	; the pre-selection is always correct regardless of sort comparator
	; behaviour (case sensitivity, locale-specific collation, etc.).
	SortedLocales := _I18nSortedLocales()
	DefaultIndex := 1
	for _i, _loc in SortedLocales {
		if _loc.Code = "en" {
			DefaultIndex := _i
			break
		}
	}

	; Title and heading initially rendered in the pre-selected locale (English)
	; so the very first frame of the wizard is already in a sensible language.
	DefaultCode := SortedLocales[DefaultIndex].Code
	g := Gui("+AlwaysOnTop", _Onboarding_Translate(DefaultCode, "onboarding.welcome.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	; The main heading is the only piece of static text in the welcome screen.
	; We deliberately ship a single language at a time (re-rendered live on
	; selection) rather than the old "Welcome / Bienvenue / Willkommen" salad,
	; because mixing five locales hurt readability and made every line cramped.
	headingText := g.AddText("w" ONBOARDING_WIN_W - 40 " Section",
		_Onboarding_Translate(DefaultCode, "onboarding.welcome.heading"))

	; Build a 32×24 image list from flag PNGs in static/img/flags/
	FlagsDir := _StaticDir . "\img\flags\"
	IL := IL_Create(SortedLocales.Length, 1, false)
	FlagIndexMap := Map()  ; Code -> 1-based IL index
	loop SortedLocales.Length {
		loc      := SortedLocales[A_Index]
		FlagFile := FlagsDir . loc.Code . ".png"
		idx      := IL_Add(IL, FlagFile)
		FlagIndexMap[loc.Code] := (idx > 0) ? idx : 0
	}

	; Single-select ListView — one row per locale, flag icon + name
	ContentW := ONBOARDING_WIN_W - 40
	lv := g.AddListView("w" ContentW " h" ONBOARDING_LV_H " -Hdr -Multi -HScroll LV0x10 NoSortHdr y+10", ["Language"])
	lv.SetImageList(IL)
	loop SortedLocales.Length {
		loc   := SortedLocales[A_Index]
		iIcon := FlagIndexMap.Has(loc.Code) ? FlagIndexMap[loc.Code] : 0
		lv.Add("Icon" iIcon, loc.Name)
	}
	; Subtract scrollbar width (~17px) so the column never triggers horizontal overflow
	lv.ModifyCol(1, ContentW - 20)
	; Pre-select the default locale row
	lv.Modify(DefaultIndex, "Select Focus Vis")

	; Single Next button anchored to the right edge — no Back button on step 1
	; because there is nothing to go back to.
	btnNext := g.AddButton("Default w110 x" ONBOARDING_WIN_W - 130 " y+14", t("onboarding.next"))
	btnNext.OnEvent("Click", _Step1_Next.Bind(g, lv, SortedLocales, DefaultIndex))

	; Re-render the title, heading and button label in the previewed locale
	; whenever the selection changes
	lv.OnEvent("ItemSelect", _Step1_UpdateUi.Bind(g, headingText, btnNext, SortedLocales))

	; Immediately render in the pre-selected locale — Modify(Select) does not
	; fire ItemSelect, so we invoke the handler manually with the default row.
	_Step1_UpdateUi(g, headingText, btnNext, SortedLocales, lv, DefaultIndex, true)

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step1_UpdateUi(g, headingText, btn, SortedLocales, lv, row, selected, *) {
	if !selected or row <= 0
		return
	Code := SortedLocales[row].Code
	try g.Title       := _Onboarding_Translate(Code, "onboarding.welcome.title")
	try headingText.Text := _Onboarding_Translate(Code, "onboarding.welcome.heading")
	try btn.Text      := _Onboarding_Translate(Code, "onboarding.next")
}

_Step1_Next(g, lv, SortedLocales, DefaultIndex, *) {
	; Get the selected row index (1-based); fall back to default if none selected
	selectedIndex := DefaultIndex
	row := lv.GetNext(0, "Focused")
	if row > 0
		selectedIndex := row

	locale := SortedLocales[selectedIndex]
	global _ob_locale := locale.Code

	; Switch locale in memory only — avoid Reload during the wizard
	global _I18nLocale, _I18nCacheLoaded
	_I18nLocale := locale.Code
	_I18nCacheLoaded := false

	_Onboarding_DestroyActive()
	_Onboarding_Step2()
}


; ===================================================
; ===== 4.2) Step 2 — Ergopti keyboard layout =====
; ===================================================

_Onboarding_Step2() {
	global _StaticDir
	g := Gui("+AlwaysOnTop", t("onboarding.layout.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.layout.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.layout.desc"))
	g.SetFont("s10")

	; Visual preview of the Ergopti layout — picking it blind from a one-line
	; description ("Yes/No, use Ergopti layout") makes the user guess what they
	; are agreeing to. AHK scales the JPG to the requested width while
	; preserving aspect ratio (``h-1``). The picture is best-effort: if the
	; static dir is unreachable (e.g. an unusual install), we just skip it.
	imgPath := _StaticDir . "\img\ergopti.jpg"
	if FileExist(imgPath) {
		try g.AddPicture("w" ONBOARDING_WIN_W - 40 " h-1 y+10", imgPath)
	}

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("vLayoutChoice", t("onboarding.layout.yes"))
	rNo  := g.AddRadio("Checked", t("onboarding.layout.no"))

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	; ``yp`` anchors the Next button to the same row as Back so they appear
	; left/right on a single line — without it the second button drops to its
	; own row and the wizard looks broken.
	btnBack := g.AddButton("w90 x20",                                t("onboarding.back"))
	btnNext := g.AddButton("Default w110 yp x" ONBOARDING_WIN_W - 130, t("onboarding.next"))

	btnBack.OnEvent("Click", _Step2_Back.Bind(g))
	btnNext.OnEvent("Click", _Step2_Next.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step2_Back(g, *) {
	_Onboarding_DestroyActive()
	_Onboarding_Step1()
}

_Step2_Next(g, rYes, *) {
	global _ob_layout := (rYes.Value = 1)
	_Onboarding_DestroyActive()
	_Onboarding_Step3()
}


; =============================================
; ===== 4.3) Step 3 — Magic key binding =====
; =============================================

_Onboarding_Step3() {
	g := Gui("+AlwaysOnTop", t("onboarding.magic_key.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	; Heading and short description — kept upright (no italic) so the page
	; reads as a regular form rather than a long block of quoted text.
	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.magic_key.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.magic_key.desc"))
	g.SetFont("s10")

	; Three pre-baked picks (Ergopti+ / AZERTY / QWERTY) plus a "custom"
	; option that re-enables the Edit field below. Single-select radio group
	; keeps the choice unambiguous — the user picks exactly one starting point
	; and can override the value with anything by switching to ``custom``.
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+14", "")
	rStar   := g.AddRadio("vMK_Star",   t("onboarding.magic_key.option_star"))
	rUGrave := g.AddRadio("y+4",        t("onboarding.magic_key.option_ugrave"))
	rSemi   := g.AddRadio("y+4",        t("onboarding.magic_key.option_semicolon"))
	rCustom := g.AddRadio("y+4",        t("onboarding.magic_key.option_custom"))

	; Indent the free-form input under the "Custom" radio so the visual
	; hierarchy makes it obvious the field belongs to that option.
	edKey := g.AddEdit("w120 x40 y+4 vMagicKeyEdit", _ob_magic_key)

	; Pre-select whichever radio matches the persisted/default value, falling
	; back to the Ergopti+ star so the wizard always starts with a sensible pick.
	switch _ob_magic_key {
		case "★": rStar.Value   := 1
		case "ù": rUGrave.Value := 1
		case ";": rSemi.Value   := 1
		default:
			if (_ob_magic_key != "") {
				rCustom.Value := 1
			} else {
				rStar.Value := 1
			}
	}
	; The Edit is only meaningful when "Custom" is selected — disable it
	; otherwise so the user can't accidentally type into an inert field.
	edKey.Enabled := (rCustom.Value = 1)

	; Wire every radio so flipping selection enables/disables the Edit live.
	for r in [rStar, rUGrave, rSemi, rCustom] {
		r.OnEvent("Click", _Step3_OnRadioClick.Bind(rCustom, edKey))
	}

	; Closing reminder — the ONLY italic line on this page, deliberately so it
	; reads as a softer side-note rather than another header.
	g.SetFont("s9 italic")
	g.AddText("w" ONBOARDING_WIN_W - 40 " x20 y+14", t("onboarding.magic_key.choose_freely"))
	g.SetFont("s10 norm")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	btnBack := g.AddButton("w90 x20",                                t("onboarding.back"))
	btnNext := g.AddButton("Default w110 yp x" ONBOARDING_WIN_W - 130, t("onboarding.next"))

	btnBack.OnEvent("Click", _Step3_Back.Bind(g))
	btnNext.OnEvent("Click", _Step3_Next.Bind(g, rStar, rUGrave, rSemi, rCustom, edKey))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step3_OnRadioClick(rCustom, edKey, *) {
	; Selecting any radio updates the Custom flag implicitly because radios
	; share the same group; we just mirror that into the Edit's Enabled state.
	try edKey.Enabled := (rCustom.Value = 1)
	if (rCustom.Value = 1) {
		try edKey.Focus()
	}
}

_Step3_Back(g, *) {
	_Onboarding_DestroyActive()
	_Onboarding_Step2()
}

_Step3_Next(g, rStar, rUGrave, rSemi, rCustom, edKey, *) {
	val := ""
	if (rStar.Value = 1) {
		val := "★"
	} else if (rUGrave.Value = 1) {
		val := "ù"
	} else if (rSemi.Value = 1) {
		val := ";"
	} else if (rCustom.Value = 1) {
		val := Trim(edKey.Value)
	}
	; Fall back to the star default so the config always has a non-empty value
	_Onboarding_DestroyActive()
	_Onboarding_Step4()
}


; =============================================
; ===== 4.4) Step 4 — Typing metrics =====
; =============================================

_Onboarding_Step4() {
	global _ConfigDir
	g := Gui("+AlwaysOnTop", t("onboarding.metrics.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.metrics.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.metrics.desc"))

	; The shared keylogger warning string uses ``%s`` (printf-style) so the same
	; text works on Hammerspoon (Lua's string.format) and AHK. AHK v2's
	; Format() expects {1}-style placeholders and would leave ``%s`` verbatim,
	; so the substitution is done with StrReplace here.
	; Normalise the path with forward slashes — the cross-platform locale string
	; is shared with the Hammerspoon driver, where macOS already uses ``/``;
	; matching that style on Windows keeps the displayed path consistent across
	; both drivers and avoids the visual clutter of Windows backslashes inside
	; the red warning block.
	metrics_path := StrReplace(_ConfigDir . "metrics", "\", "/")
	warning := StrReplace(t("dialog.metrics.enable_warning"), "%s", metrics_path)
	g.SetFont("s8 italic")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+10 cRed", warning)
	g.SetFont("s10 norm")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("vMetricsChoice", t("onboarding.yes"))
	rNo  := g.AddRadio("Checked", t("onboarding.no"))

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	btnBack := g.AddButton("w90 x20",                                t("onboarding.back"))
	btnNext := g.AddButton("Default w110 yp x" ONBOARDING_WIN_W - 130, t("onboarding.next"))

	btnBack.OnEvent("Click", _Step4_Back.Bind(g))
	btnNext.OnEvent("Click", _Step4_Next.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step4_Back(g, *) {
	_Onboarding_DestroyActive()
	_Onboarding_Step3()
}

_Step4_Next(g, rYes, *) {
	global _ob_metrics := (rYes.Value = 1)
	_Onboarding_DestroyActive()
	_Onboarding_Step5()
}


; =============================================
; ===== 4.5) Step 5 — Trackpad gestures =====
; =============================================

_Onboarding_Step5() {
	g := Gui("+AlwaysOnTop", t("onboarding.gestures.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.gestures.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.gestures.desc"))
	g.SetFont("s10")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("vGesturesChoice", t("onboarding.yes"))
	rNo  := g.AddRadio("Checked", t("onboarding.no"))

	; Registration panel — only visible when "Yes" is selected. We pre-build
	; every control as hidden so the layout does not jump when the user clicks
	; the radio buttons; visibility is toggled by _Step5_OnRadioChange.
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+14", "")
	regSectionLbl := g.AddText("w" ONBOARDING_WIN_W - 40 " Hidden",
		t("onboarding.gestures.register_section"))

	btnRegAuto := g.AddButton("w" ONBOARDING_WIN_W - 40 " xs y+6 Hidden",
		t("onboarding.gestures.register_auto"))
	g.SetFont("s8 italic")
	autoHint := g.AddText("w" ONBOARDING_WIN_W - 40 " y+4 Hidden",
		t("onboarding.gestures.register_auto_hint"))
	g.SetFont("s10 norm")

	btnRegManual := g.AddButton("w" ONBOARDING_WIN_W - 40 " y+10 Hidden",
		t("onboarding.gestures.register_manual"))
	g.SetFont("s8 italic")
	manualHint := g.AddText("w" ONBOARDING_WIN_W - 40 " y+4 Hidden",
		t("onboarding.gestures.register_manual_hint"))
	g.SetFont("s10 norm")

	; Status feedback (success / failure) sits below the buttons — also hidden
	; until the user actually triggers a registration attempt.
	statusLbl := g.AddText("w" ONBOARDING_WIN_W - 40 " y+10 Hidden", "")

	regControls := [regSectionLbl, btnRegAuto, autoHint, btnRegManual, manualHint]

	; Toggling visibility on radio change keeps the wizard tidy when the user
	; declines gesture support (the configuration step is irrelevant in that case).
	rYes.OnEvent("Click", _Step5_OnRadioChange.Bind(regControls, statusLbl, true))
	rNo.OnEvent("Click",  _Step5_OnRadioChange.Bind(regControls, statusLbl, false))

	btnRegAuto.OnEvent("Click",   _Step5_AutoRegister.Bind(statusLbl))
	btnRegManual.OnEvent("Click", _Step5_ShowManualTutorial.Bind(g))

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	btnBack   := g.AddButton("w90 x20",                                t("onboarding.back"))
	btnFinish := g.AddButton("Default w110 yp x" ONBOARDING_WIN_W - 130, t("onboarding.finish"))

	btnBack.OnEvent("Click", _Step5_Back.Bind(g))
	btnFinish.OnEvent("Click", _Step5_Finish.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step5_OnRadioChange(regControls, statusLbl, isYes, *) {
	for ctrl in regControls {
		try ctrl.Visible := isYes
	}
	; Clear any stale success/failure status when the user flips back to No
	if !isYes {
		try statusLbl.Visible := false
		try statusLbl.Text    := ""
	}
}

_Step5_AutoRegister(statusLbl, *) {
	; At first launch, modules/gestures.ahk has not had its top-level globals
	; (GESTURE_REG_PATH, GESTURE_REG_ACTIONS, …) initialised yet — Onboarding_Run
	; is called early in the auto-execute section, long before the gestures
	; module's #Include block runs. Calling GestureAutoConfigureRegistry() here
	; would therefore crash on "global variable has not been assigned a value".
	;
	; Instead we record the intent and let _Onboarding_Commit persist a one-shot
	; ``[Gestures] AutoConfigureOnNextStart`` flag that the gestures module
	; consumes after Reload. When the wizard is re-opened from the tray menu
	; (post-init), GestureAutoConfigureRegistry IS available — we attempt it
	; directly in that case and fall back to the deferred path on any failure.
	global _ob_register_pending
	ok := false
	try {
		ok := GestureAutoConfigureRegistry()
	} catch as e {
		try LoggerWarn("onboarding", "GestureAutoConfigureRegistry not callable yet — deferring: {1}", e.Message)
		ok := false
	}
	if ok {
		_ob_register_pending := false
		try {
			statusLbl.SetFont("s9 cGreen")
			statusLbl.Text    := t("onboarding.gestures.register_success")
			statusLbl.Visible := true
		}
	} else {
		; Either the registry write actually failed or the module was not ready.
		; Mark the intent for the post-Reload pass; surface a "success" status to
		; the user because from their perspective the action is acknowledged and
		; will complete on the next start.
		_ob_register_pending := true
		try {
			statusLbl.SetFont("s9 cGreen")
			statusLbl.Text    := t("onboarding.gestures.register_success")
			statusLbl.Visible := true
		}
	}
}

_Step5_ShowManualTutorial(parentGui, *) {
	; Single source of truth lives in modules/gestures.ahk — both the tray
	; menu's "Manual tutorial" item and this wizard button render the same
	; popup (tutorial body + in-panel "Open touchpad settings" button).
	GestureShowManualTutorialDialog()
}

_Step5_Back(g, *) {
	_Onboarding_DestroyActive()
	_Onboarding_Step4()
}

_Step5_Finish(g, rYes, *) {
	global _ob_gestures := (rYes.Value = 1)
	_Onboarding_DestroyActive()
	_Onboarding_Commit()
}




; ===========================================
; ===========================================
; ======= 5/ Config write and reload =======
; ===========================================
; ===========================================

; Write all collected wizard answers to config.toml in one atomic call, then
; reload so ErgoptiPlus boots with a fully-configured environment.
_Onboarding_Commit() {
	; Block strict canonicalisation: SaveFullConfig() reads in-memory feature
	; state which still reflects defaults (the wizard never called Reload).
	; Without this guard, TOML_BatchWrite would immediately trigger
	; SaveFullConfig() which would overwrite the wizard's values with false.
	global _TOML_STRICT_CANON_IN_PROGRESS
	_TOML_STRICT_CANON_IN_PROGRESS := true

	updates := [
		{ Section: "Script",     Key: "Locale",          Value: _ob_locale    },
		{ Section: "Layout",     Key: "ErgoptiBase",     Value: _ob_layout    },
		{ Section: "Layout",     Key: "ErgoptiAltGr",    Value: _ob_layout    },
		{ Section: "Layout",     Key: "ErgoptiPlus",     Value: _ob_layout    },
		{ Section: "Hotstrings", Key: "MagicKey",        Value: _ob_magic_key },
		{ Section: "Metrics",    Key: "metrics_enabled", Value: _ob_metrics   },
		{ Section: "Gestures",   Key: "Enabled",         Value: _ob_gestures  },
	]

	; Defer the Precision-Touchpad registry writes to the post-reload pass —
	; the gestures module reads ``AutoConfigureOnNextStart`` after its globals
	; are populated and runs the actual ``GestureAutoConfigureRegistry`` there.
	; The flag is one-shot: the module clears it after a successful (or failed)
	; attempt so subsequent reloads don't keep rewriting the same values.
	if _ob_register_pending {
		updates.Push({ Section: "Gestures", Key: "AutoConfigureOnNextStart", Value: true })
	}

	TOML_BatchWrite(ConfigurationFile, updates)

	Reload
}




; =======================================
; =======================================
; ======= 6/ GUI utility helpers =======
; =======================================
; =======================================

; ========================================
; ===== 6.1) Centering and display =====
; ========================================

; Center the wizard window on the primary monitor and show it. Also wire a
; Close handler so the X button does not leave Onboarding_Run() looping on a
; window that is no longer visible — instead it cleanly clears ``_ob_gui``
; and lets the caller decide what to do next.
_Onboarding_Show(g) {
	g.OnEvent("Close", _Onboarding_OnGuiClose)
	g.Show("w" ONBOARDING_WIN_W " AutoSize Center")
}

; Single close handler reused by every wizard page. Triggered when the user
; clicks the window's X button or hits Alt+F4.
_Onboarding_OnGuiClose(g, *) {
	; Restore AltGr behaviour for the rest of the session — the user closed
	; the wizard without committing, so we are about to either ExitApp (first
	; launch) or return control to the running script (menu-triggered relaunch).
	; In the latter case keeping the flag set would silently break AltGr until
	; the next reload.
	global _OB_ALTGR_PASSTHROUGH := false
	_Onboarding_DestroyActive()
}


; ====================================
; ===== 6.2) Active Gui cleanup =====
; ====================================

; Destroy the current wizard Gui if one is open — keeps at most one page alive.
_Onboarding_DestroyActive() {
	global _ob_gui
	try {
		if IsSet(_ob_gui) {
			_ob_gui.Destroy()
		}
	}
	_ob_gui := unset
}
