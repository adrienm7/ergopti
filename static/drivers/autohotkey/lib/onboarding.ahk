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
; to neutralise every SC138-prefixed hotkey in the driver while the wizard is
; on screen. AHK promotes a key to a "prefix key" the moment any ``SC138 & X::``
; combo is parsed, which costs SC138 (= AltGr) its native function. By making
; all #HotIf variants evaluate to false we restore native behaviour for the
; duration of the wizard so the host Windows layout still produces its AltGr
; characters in the wizard's edit boxes (and anywhere else the user types
; while the wizard is up). The wizard always exits via Reload or ExitApp so
; this flag never needs to be cleared by hand.
global _OB_ALTGR_PASSTHROUGH := false




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

	; Title and heading initially rendered in the pre-selected locale (English)
	; so the very first frame of the wizard is already in a sensible language.
	DefaultCode := I18N_LOCALES[ONBOARDING_DEFAULT_LOCALE_INDEX].Code
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
	IL := IL_Create(I18N_LOCALES.Length, 1, false)
	FlagIndexMap := Map()  ; Code -> 1-based IL index
	loop I18N_LOCALES.Length {
		loc      := I18N_LOCALES[A_Index]
		FlagFile := FlagsDir . loc.Code . ".png"
		idx      := IL_Add(IL, FlagFile)
		FlagIndexMap[loc.Code] := (idx > 0) ? idx : 0
	}

	; Single-select ListView — one row per locale, flag icon + name
	ContentW := ONBOARDING_WIN_W - 40
	lv := g.AddListView("w" ContentW " h" ONBOARDING_LV_H " -Hdr -Multi -HScroll LV0x10 NoSortHdr y+10", ["Language"])
	lv.SetImageList(IL)
	loop I18N_LOCALES.Length {
		loc   := I18N_LOCALES[A_Index]
		iIcon := FlagIndexMap.Has(loc.Code) ? FlagIndexMap[loc.Code] : 0
		lv.Add("Icon" iIcon, loc.Name)
	}
	; Subtract scrollbar width (~17px) so the column never triggers horizontal overflow
	lv.ModifyCol(1, ContentW - 20)
	; Pre-select the default locale row
	lv.Modify(ONBOARDING_DEFAULT_LOCALE_INDEX, "Select Focus Vis")

	; Single Next button anchored to the right edge — no Back button on step 1
	; because there is nothing to go back to.
	btnNext := g.AddButton("Default w110 x" ONBOARDING_WIN_W - 130 " y+14", t("onboarding.next"))
	btnNext.OnEvent("Click", _Step1_Next.Bind(g, lv))

	; Re-render the title, heading and button label in the previewed locale
	; whenever the selection changes
	lv.OnEvent("ItemSelect", _Step1_UpdateUi.Bind(g, headingText, btnNext))

	; Immediately render in the pre-selected locale — Modify(Select) does not
	; fire ItemSelect, so we invoke the handler manually with the default row.
	_Step1_UpdateUi(g, headingText, btnNext, lv, ONBOARDING_DEFAULT_LOCALE_INDEX, true)

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step1_UpdateUi(g, headingText, btn, lv, row, selected, *) {
	if !selected or row <= 0
		return
	Code := I18N_LOCALES[row].Code
	try g.Title       := _Onboarding_Translate(Code, "onboarding.welcome.title")
	try headingText.Text := _Onboarding_Translate(Code, "onboarding.welcome.heading")
	try btn.Text      := _Onboarding_Translate(Code, "onboarding.next")
}

_Step1_Next(g, lv, *) {
	; Get the selected row index (1-based); fall back to default if none selected
	selectedIndex := ONBOARDING_DEFAULT_LOCALE_INDEX
	row := lv.GetNext(0, "Focused")
	if row > 0
		selectedIndex := row

	locale := I18N_LOCALES[selectedIndex]
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
	g := Gui("+AlwaysOnTop", t("onboarding.layout.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.layout.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.layout.desc"))
	g.SetFont("s10")

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

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.magic_key.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.magic_key.desc"))
	g.SetFont("s10")

	; Bullet-list of recommended characters (Ergopti+ / AZERTY / QWERTY) lives in
	; a single translation key so locales control the wording in one place; the
	; field stays a free-form Edit so the user can pick anything they like.
	g.SetFont("s9 italic")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+10", t("onboarding.magic_key.suggestions"))
	g.SetFont("s10 norm")

	edKey := g.AddEdit("w80 y+10 vMagicKeyEdit", _ob_magic_key)

	; Closing reminder — kept after the input so it acts as the answer to the
	; implicit "but what should I actually pick?" question the user has once
	; the field is in focus.
	g.SetFont("s9 italic")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+10", t("onboarding.magic_key.choose_freely"))
	g.SetFont("s10 norm")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	btnBack := g.AddButton("w90 x20",                                t("onboarding.back"))
	btnNext := g.AddButton("Default w110 yp x" ONBOARDING_WIN_W - 130, t("onboarding.next"))

	btnBack.OnEvent("Click", _Step3_Back.Bind(g))
	btnNext.OnEvent("Click", _Step3_Next.Bind(g, edKey))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step3_Back(g, *) {
	_Onboarding_DestroyActive()
	_Onboarding_Step2()
}

_Step3_Next(g, edKey, *) {
	val := Trim(edKey.Value)
	; Fall back to the asterisk default so the config always has a non-empty value
	global _ob_magic_key := (val != "") ? val : ONBOARDING_DEFAULT_MAGIC_KEY
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
	; Manual method is NOT "open the registry" — it is the same tutorial shown
	; by the tray menu's gestures item, plus a one-click shortcut into the
	; Windows touchpad settings page where the user can actually wire up the
	; gestures. We assemble the body string the same way GestureShowSetupInstructions
	; does (header + open-path + for-each + slot-by-slot lines + auto note) so
	; the wording stays in lockstep with the rest of the driver — but we render
	; it as our own Gui rather than calling the existing helper, because that
	; helper depends on globals (GESTURE_SLOTS, GESTURE_SHORTCUT_LABELS) that
	; may not be set yet at first-launch onboarding time.
	tutorialBody := ""
	tutorialBody .= t("gesture.setup.header") . "`n`n"
	tutorialBody .= t("gesture.setup.open_path") . "`n`n"
	tutorialBody .= t("gesture.setup.for_each") . "`n`n"
	if IsSet(GESTURE_SLOTS) and IsSet(GESTURE_SHORTCUT_LABELS) {
		for Slot in GESTURE_SLOTS {
			tutorialBody .= "  " . t("gesture.slots." . Slot) . " :  "
				. GESTURE_SHORTCUT_LABELS[Slot] . "`n"
		}
		tutorialBody .= "`n"
	}
	tutorialBody .= t("gesture.setup.auto_configure")

	tg := Gui("+AlwaysOnTop +Owner" . parentGui.Hwnd, t("onboarding.gestures.register_manual"))
	tg.SetFont("s9", "Segoe UI")
	tg.MarginX := 18
	tg.MarginY := 14
	tg.AddEdit("ReadOnly w" ONBOARDING_WIN_W - 40 " h220 -Wrap +HScroll", tutorialBody)
	tg.AddText("w" ONBOARDING_WIN_W - 40 " y+10",
		_Onboarding_TryTranslate("onboarding.gestures.open_settings_hint"))
	btnOpenSettings := tg.AddButton("w" ONBOARDING_WIN_W - 40 " y+8",
		_Onboarding_TryTranslate("onboarding.gestures.open_settings"))
	btnClose        := tg.AddButton("Default w110 x" ONBOARDING_WIN_W - 130 " y+12",
		t("onboarding.btn.ok"))
	btnOpenSettings.OnEvent("Click", (*) => _Onboarding_OpenTouchpadSettings())
	btnClose.OnEvent("Click", ((*) => tg.Destroy()))
	tg.Show("AutoSize Center")
}

_Onboarding_OpenTouchpadSettings() {
	; ms-settings:devices-touchpad opens Settings → Bluetooth & devices → Touchpad
	; on Windows 10/11. From there the user expands "Advanced gestures" and
	; assigns Ctrl + Win + Shift + F1..F10 to each gesture slot.
	try Run("ms-settings:devices-touchpad")
}

; t() falls back to the raw key if a translation is missing — fine for body
; text but a button labelled e.g. ``onboarding.gestures.open_settings`` looks
; broken. This helper substitutes a friendly default when nothing translates.
_Onboarding_TryTranslate(key) {
	val := t(key)
	if (val == key) {
		switch key {
			case "onboarding.gestures.open_settings":      return "Open touchpad settings"
			case "onboarding.gestures.open_settings_hint": return "Opens Settings → Bluetooth & devices → Touchpad → Advanced gestures."
		}
	}
	return val
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
